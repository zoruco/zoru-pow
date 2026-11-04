#!/usr/bin/env python3
"""Exact, journaled mainnet signing through the existing protected wallet CLI.

No private key or wallet password is read by this program. Broadcasts are never
retried with a different nonce or fee. Retained transactions must be reconciled
before additional signing is allowed.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from proof_inventory import Rpc, require, selector

NATIVE_CHAIN = 'f9f432b1851b5c179d2091a96f593aaed50ec7466b74f89301f957a83e56ce1f'
IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'


def load_mainnet_manifest(path):
    manifest=json.loads(Path(path).read_text())
    require(manifest.get('schema')=='zoru-mainnet-suite-1' and manifest['chainId']==6736 and manifest['mode']=='mainnet',
            'Authenticated mainnet manifest required')
    canonical={key:value for key,value in manifest.items() if key!='manifestSha256'}
    require(hashlib.sha256(json.dumps(canonical,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            ==manifest['manifestSha256'],'Mainnet manifest fingerprint mismatch')
    return manifest


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix+'.tmp')
    with open(temporary, 'w', opener=lambda p, flags: os.open(p, flags, 0o600)) as stream:
        stream.write(json.dumps(value, indent=2)+'\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    descriptor=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)


class MainnetTransactions:
    def __init__(self, manifest, journal, wallet, rpc, native, cast='cast', signer='wallet-evm',
                 signing_account=None, signing_callback=None, fee_budget_wei=None):
        self.manifest = load_mainnet_manifest(manifest)
        self.rpc = Rpc(rpc)
        self.native = Rpc(native)
        self.wallet, self.cast, self.signer = wallet, cast, signer
        self.journal = Path(journal)
        self.journal.mkdir(mode=0o700, parents=True, exist_ok=True)
        require(self.journal.stat().st_mode & 0o077 == 0, 'Transaction journal must be private')
        self.owner = self.manifest['owner'].lower()
        self.account = (signing_account or self.owner).lower()
        self.signing_callback = signing_callback
        self.fee_budget_wei = fee_budget_wei
        require(self.account == self.owner or signing_callback is not None,'A protected operational signer is required')
        self.allowed_implementations = {role: {self.manifest['implementations'][role].lower():
            self.manifest['approvedImplementationCodeHashes'][role][0]} for role in ['ledger','engine','beacon']}
        self.proxy_admins = {role:'0x'+subprocess.check_output([self.cast,'keccak'],
            input='0xd694'+self.manifest[role][2:].lower()+'01',text=True).strip()[-40:]
            for role in ['ledger','engine','beacon']}

    def authorize_implementation(self, role, address, reviewed_runtime):
        require(role in self.allowed_implementations, 'Unknown implementation role')
        actual = self.rpc.call('eth_getCode',[address,'latest'])
        require(actual == reviewed_runtime, 'Implementation runtime does not match reviewed artifact')
        self.allowed_implementations[role][address.lower()] = subprocess.check_output(
            [self.cast,'keccak'],input=actual,text=True).strip()

    def call(self, address, data, block='latest'):
        return self.rpc.call('eth_call', [{'to':address, 'data':data}, block])

    def verify(self):
        require(int(self.rpc.call('eth_chainId', []),16) == 6736, 'Mainnet chain identity changed')
        require('anvil' not in str(self.rpc.call('web3_clientVersion',[])).lower(), 'Production signing refuses local fork execution')
        self.native_info()
        actual_owner = self.call(self.manifest['token'], selector('owner()'))
        require('0x'+actual_owner[-40:].lower() == self.owner, 'Protocol owner changed')
        require('0x'+self.call(self.manifest['ledger'],selector('protocolAdmin()'))[-40:].lower()
                == self.manifest['admin'].lower(), 'Protocol coordinator changed')
        require('0x'+self.call(self.manifest['token'],selector('issuer()'))[-40:].lower()
                == self.manifest['ledger'].lower(),'Token issuer changed')
        for role in ['ledger','engine','beacon']:
            actual = '0x'+self.call(self.manifest['admin'],selector(role+'Proxy()'))[-40:].lower()
            require(actual == self.manifest[role].lower(), 'Permanent proxy address changed')
            code = self.rpc.call('eth_getCode',[actual,'latest'])
            digest = subprocess.check_output([self.cast,'keccak'], input=code, text=True).strip()
            require(digest == self.manifest['runtimeCodeHashes'][role], 'Permanent proxy runtime changed')
            proxy_admin = self.proxy_admins[role]
            registered = self.call(self.manifest['admin'],selector('adminOf(address)')+actual[2:].zfill(64))
            require('0x'+registered[-40:].lower()==proxy_admin and
                    '0x'+self.call(proxy_admin,selector('owner()'))[-40:].lower()==self.manifest['admin'].lower(),
                    'ProxyAdmin authority changed')
            implementation = '0x'+self.rpc.call('eth_getStorageAt',[actual,IMPLEMENTATION_SLOT,'latest'])[-40:].lower()
            require(implementation in self.allowed_implementations[role], 'Unexpected active implementation')
            implementation_code = self.rpc.call('eth_getCode',[implementation,'latest'])
            actual_hash = subprocess.check_output([self.cast,'keccak'],input=implementation_code,text=True).strip()
            require(actual_hash == self.allowed_implementations[role][implementation], 'Active implementation bytecode changed')

    def native_info(self):
        native = self.native.url
        import http.client
        connection = (http.client.HTTPSConnection if native.scheme == 'https' else http.client.HTTPConnection)(
            native.hostname, native.port, timeout=15)
        try:
            connection.request('POST', (native.path.rstrip('/')+'/v1/chain/get_info'), '{}', {'Content-Type':'application/json'})
            response = connection.getresponse()
            require(response.status == 200, 'Native identity endpoint failed')
            info=json.loads(response.read(1048576))
            require(info['chain_id'] == NATIVE_CHAIN, 'Native mainnet identity changed')
            return info
        finally:
            connection.close()

    def confirmed(self, record):
        receipt = self.rpc.call('eth_getTransactionReceipt',[record['transactionHash']])
        if receipt is None:
            return None
        header = self.rpc.call('eth_getBlockByNumber',[receipt['blockNumber'],False])
        if header is None:
            return None
        require(header['hash'] == receipt['blockHash'] and record['transactionHash'] in header['transactions'],
                'Transaction receipt is not canonical')
        require(receipt['from'].lower() == self.account and int(receipt['status'],16) == 1,
                'Release transaction failed; stop the affected operation')
        return receipt

    def wait_irreversible(self,record):
        deadline=time.monotonic()+120
        binding=None
        barrier=None
        while time.monotonic()<deadline:
            receipt=self.confirmed(record)
            if receipt is not None:
                info=self.native_info()
                if receipt['blockHash']!=binding:
                    binding=receipt['blockHash']
                    barrier=info['head_block_num']
                if info['last_irreversible_block_num']>=barrier:
                    return receipt,barrier,info['last_irreversible_block_num']
            time.sleep(0.5)
        raise RuntimeError('Retain and reconcile transaction '+record['transactionHash'])

    def send(self, label, to, data, gas_limit=None, creation_runtime=None):
        require(label and all(c.isalnum() or c in '-_' for c in label), 'Invalid operation label')
        path = self.journal/(label+'.json')
        self.verify()
        if path.exists():
            previous = json.loads(path.read_text())
            require(previous['transaction']['to'] == to and previous['transaction']['data'] == data,
                    'Operation label is already bound to a different transaction')
            receipt = self.confirmed(previous)
            require(receipt is not None, 'Previously prepared transaction requires reconciliation')
            if to is None:
                require(self.rpc.call('eth_getCode',[receipt['contractAddress'],'latest'])==creation_runtime,
                        'Resumed deployment runtime differs from the reviewed artifact')
            previous.update(state='confirmed',receipt=receipt)
            atomic_json(path,previous)
            return receipt
        for existing in self.journal.glob('*.json'):
            record = json.loads(existing.read_text())
            if record.get('state') != 'confirmed':
                require(self.confirmed(record) is not None, 'Retained transaction must be reconciled before signing')
        nonce = int(self.rpc.call('eth_getTransactionCount',[self.account,'latest']),16)
        require(nonce == int(self.rpc.call('eth_getTransactionCount',[self.account,'pending']),16), 'Signer has a pending transaction')
        require(to is None or to.lower() in [self.manifest[x].lower() for x in ['ledger','beacon','admin']],
                'Recipient is outside the authorized protocol release')
        require(to is not None or creation_runtime, 'Deployment requires exact reviewed runtime')
        if self.account != self.owner:
            permitted = [selector(signature) for signature in ['copyLegacyProofs(bytes32[])','clearLegacyProofs(bytes32[])',
                         'copyLegacyEpochs(uint48[])','clearLegacyEpochs(uint48[])']]
            require(to is not None and to.lower() == self.manifest['ledger'].lower() and data[:10] in permitted,
                    'Operational signing is restricted to permissionless proof migration batches')
        price = int(self.rpc.call('eth_gasPrice',[]),16)
        require(0 < price <= 300_000_000_000, 'Mainnet fee quote exceeds release bound')
        transaction = {'from':self.account,'to':to,'chainId':6736,'nonce':nonce,'value':'0','data':data,'type':0,
                       'gasPrice':str(price)}
        estimate_request = {'from':self.account,'data':data,'gasPrice':hex(price),'value':'0x0'}
        if to is not None:
            estimate_request['to'] = to
        estimate = int(self.rpc.call('eth_estimateGas',[estimate_request]),16)
        limit = gas_limit if gas_limit is not None else (estimate*130+99)//100+10000
        require(estimate <= limit <= 8_000_000, 'Deployment or call exceeds bounded release gas')
        require(int(self.rpc.call('eth_getBalance',[self.account,'latest']),16) >= limit*price,
                'Existing signer gas balance is insufficient')
        if self.fee_budget_wei is not None:
            spent = sum(int(record['receipt']['gasUsed'],16)*int(record['receipt']['effectiveGasPrice'],16)
                for path in self.journal.glob('*.json') for record in [json.loads(path.read_text())] if record.get('receipt'))
            require(spent+limit*price <= self.fee_budget_wei,'Operational migration fee budget would be exceeded')
        transaction['gasLimit'] = limit
        unsigned_path = self.journal/(label+'.unsigned')
        atomic_json(unsigned_path, transaction)
        if self.signing_callback is None:
            signed_run = subprocess.run([self.signer,'sign',self.wallet,str(unsigned_path)],capture_output=True,text=True,timeout=90)
            require(signed_run.returncode == 0, 'Protected wallet declined signing: '+signed_run.stderr[-300:])
            signed = json.loads(signed_run.stdout)
        else:
            signed = self.signing_callback(transaction)
        require(signed['from'].lower() == self.account and int(signed['chainId']) == 6736 and signed['broadcast'] is False,
                'Protected signing identity does not match the reviewed transaction')
        raw = signed['serializedTransaction']
        tx_hash = subprocess.check_output([self.cast,'keccak'],input=raw,text=True).strip()
        require(tx_hash == signed['hash'], 'Signed transaction fingerprint mismatch')
        signed_path = self.journal/(label+'.raw')
        with open(signed_path,'w',opener=lambda p,flags:os.open(p,flags,0o600)) as stream:
            stream.write(raw+'\n')
            stream.flush()
            os.fsync(stream.fileno())
        record = {'label':label,'transaction':transaction,'transactionHash':tx_hash,'state':'prepared',
                  'estimatedGas':estimate,'preparedAt':int(time.time()),'signedTransactionFile':str(signed_path)}
        atomic_json(path,record)
        self.verify()
        result = self.rpc.call('eth_sendRawTransaction',[raw])
        require(result.lower() == tx_hash.lower(), 'Broadcast hash mismatch; retain the prepared transaction')
        record['state'] = 'broadcast'
        atomic_json(path,record)
        receipt,barrier,irreversible=self.wait_irreversible(record)
        if to is None:
            code = self.rpc.call('eth_getCode',[receipt['contractAddress'],'latest'])
            require(code == creation_runtime, 'Deployed runtime differs from reviewed artifact')
        record.update(state='confirmed',receipt=receipt,confirmedAt=int(time.time()),
                      nativeReceiptBarrier=barrier,nativeIrreversibleAt=irreversible)
        atomic_json(path,record)
        print(json.dumps({'operation':label,'hash':tx_hash,'gasUsed':int(receipt['gasUsed'],16)}),flush=True)
        return receipt

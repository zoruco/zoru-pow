#!/usr/bin/env python3
"""Rehearse the complete release against block-pinned mainnet state on local Anvil.

The source RPC is read only. Every write is restricted to the locally spawned
Anvil process. No wallet, key, password or production signer is used.
"""
import argparse
import hashlib
import http.client
import http.server
import json
from pathlib import Path
import socket
import subprocess
import threading
import time

from proof_inventory import Rpc, require, selector, words
from proof_migration import ProofMigration
from release_transaction import atomic_json


class RehearsalTransactions:
    def __init__(self, manifest, rpc, cast, output):
        self.manifest, self.rpc, self.cast, self.output = manifest, rpc, cast, output
        self.records = {}
        self.interrupt = False
        self.interruption_label='proof-clear-000016'

    def send(self, label, to, data, gas_limit=None, creation_runtime=None):
        version = self.rpc.call('web3_clientVersion',[])
        require('anvil' in version.lower(), 'Rehearsal writes require the spawned Anvil process')
        require(int(self.rpc.call('eth_chainId',[]),16) == 6736, 'Fork chain changed')
        if label in self.records:
            require(self.records[label]['to'] == to and self.records[label]['data'] == data, 'Rehearsal operation changed')
            return self.records[label]['receipt']
        transaction = {'from':self.manifest['owner'],'data':data,'gas':hex(gas_limit or 8_000_000)}
        if to:
            transaction['to'] = to
        tx = self.rpc.call('eth_sendTransaction',[transaction])
        deadline = time.monotonic()+90
        while time.monotonic() < deadline:
            receipt = self.rpc.call('eth_getTransactionReceipt',[tx])
            if receipt is not None:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Unresolved local rehearsal transaction')
        require(int(receipt['status'],16) == 1, 'Fork rehearsal transaction reverted: '+label)
        if creation_runtime:
            require(self.rpc.call('eth_getCode',[receipt['contractAddress'],'latest']) == creation_runtime, 'Fork deployment runtime mismatch')
        self.records[label] = {'to':to,'data':data,'receipt':receipt}
        atomic_json(self.output,self.records)
        if self.interrupt and label == self.interruption_label:
            self.interrupt = False
            raise InterruptedError('Planned interruption after a confirmed cleanup transaction')
        return receipt


def run(args):
    require(not args.output.exists(), 'Retain an existing fork report; use a new output directory')
    args.output.mkdir(mode=0o700,parents=True)
    manifest = json.loads(args.manifest.read_text())
    inventory = json.loads(args.inventory.read_text())
    require(manifest['chainId'] == inventory['chainId'] == 6736, 'Only the declared mainnet snapshot may be rehearsed')
    source = Rpc(args.rpc)
    header = source.call('eth_getBlockByNumber',[hex(inventory['blockNumber']),False])
    require(header['hash'] == inventory['blockHash'], 'Source snapshot block changed')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',0))
        port = listener.getsockname()[1]
    log = open(args.output/'anvil.log','w')
    # VEX requires conventional HTTP header casing. Anvil's upstream transport
    # uses lowercase headers, so adapt the transport through a read-only local
    # gateway. Its allowlist also makes production broadcasts impossible.
    semaphore = threading.BoundedSemaphore(4)

    class SourceGateway(http.server.BaseHTTPRequestHandler):
        def log_message(self,*_):
            pass

        def do_POST(self):
            size = int(self.headers.get('Content-Length','0'))
            require(0 < size <= 65536,'Oversized source request')
            body = self.rfile.read(size)
            payload = json.loads(body)
            requests = payload if isinstance(payload,list) else [payload]
            allowed = {'eth_chainId','eth_blockNumber','eth_getBlockByNumber','eth_getBlockByHash',
                       'eth_getTransactionByHash','eth_getTransactionReceipt','eth_getCode','eth_getBalance',
                       'eth_getTransactionCount','eth_getStorageAt','eth_getLogs','eth_getProof','eth_call',
                       'web3_clientVersion','net_version','eth_gasPrice'}
            if not (0 < len(requests) <= 32 and all(r.get('method') in allowed for r in requests)):
                errors=[{'jsonrpc':'2.0','id':request.get('id'),
                    'error':{'code':-32601,'message':'Source gateway permits bounded read-only requests exclusively'}}
                    for request in (requests[:32] or [{}])]
                raw=json.dumps(errors if isinstance(payload,list) else errors[0]).encode()
                self.send_response(200)
                self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return
            with semaphore:
                url = source.url
                connection = (http.client.HTTPSConnection if url.scheme == 'https' else http.client.HTTPConnection)(
                    url.hostname,url.port,timeout=30)
                try:
                    connection.request('POST',url.path or '/',body,{'Content-Type':'application/json'})
                    response = connection.getresponse()
                    raw = response.read(32*1024*1024+1)
                    require(len(raw) <= 32*1024*1024,'Source response exceeds limit')
                    self.send_response(response.status)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length',str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                finally:
                    connection.close()

    gateway = http.server.ThreadingHTTPServer(('127.0.0.1',0),SourceGateway)
    gateway.daemon_threads = True
    threading.Thread(target=gateway.serve_forever,daemon=True).start()
    process = subprocess.Popen([args.anvil,'--silent','--host','127.0.0.1','--port',str(port),'--chain-id','6736',
        '--fork-url',f'http://127.0.0.1:{gateway.server_port}','--fork-block-number',str(inventory['blockNumber']),
        '--gas-limit','6000000000'],stdout=log,stderr=log)
    rpc = Rpc(f'http://127.0.0.1:{port}')
    try:
        for _ in range(100):
            try:
                if rpc.call('eth_chainId',[]) == hex(6736):
                    break
            except Exception:
                require(process.poll() is None,'Anvil failed to start')
                time.sleep(0.1)
        else:
            raise RuntimeError('Anvil startup timed out')
        require(rpc.call('eth_getBlockByNumber',[hex(inventory['blockNumber']),False])['hash'] == inventory['blockHash'],
                'Fork does not reproduce the declared source block')
        rpc.call('anvil_impersonateAccount',[manifest['owner']])
        rpc.call('anvil_setBalance',[manifest['owner'],hex(10**25)])
        t = RehearsalTransactions(manifest,rpc,args.cast,args.output/'transactions.json')

        def encode(signature,*values):
            return subprocess.check_output([args.cast,'calldata',signature,*map(str,values)],text=True).strip()

        def call(role,signature,*values):
            return rpc.call('eth_call',[{'to':manifest[role],'data':encode(signature,*values)},'latest'])

        def number(role,signature,*values):
            return words(call(role,signature,*values),1)[0]

        def send(label,role,signature,*values):
            return t.send(label,manifest[role],encode(signature,*values))

        def deploy(name):
            artifact = json.loads((args.artifacts/(name+'.artifact.json')).read_text())
            return t.send('deploy-'+name,None,artifact['bytecode']['object'],
                creation_runtime=artifact['deployedBytecode']['object'])['contractAddress']

        def upgrade(label,ledger,beacon):
            zero = '0x'+'0'*40
            payload = '('+','.join([ledger or zero,'0x',zero,'0x',beacon or zero,'0x'])+')'
            send('schedule-'+label,'admin','scheduleUpgrade((address,bytes,address,bytes,address,bytes))',payload)
            activation = number('admin','activationTime()')
            rpc.call('evm_setNextBlockTimestamp',[activation+1])
            rpc.call('evm_mine',[])
            send('activate-'+label,'admin','executeScheduledUpgrade()')
            require(number('admin','recoveryRequired()') == 0,'Fork upgrade checkpoint failed')
            require(number('ledger','moduleGeneration()') == number('admin','suiteRevision()'),'Fork generation mismatch')
            for role in ['ledger','engine','beacon']:
                require('0x'+call('admin',role+'Proxy()')[-40:].lower() == manifest[role].lower(),'Fork proxy address changed')

        for role in ['ledger','engine','beacon']:
            code = rpc.call('eth_getCode',[manifest['implementations'][role],'latest'])
            fingerprint = subprocess.check_output([args.cast,'keccak'],input=code,text=True).strip()
            require(fingerprint in manifest['approvedImplementationCodeHashes'][role], 'Source implementation differs from deployment')
        send('pause-admission','ledger','setAdmissionPaused(bool)','true')
        send('pause-claims','ledger','setClaimsPaused(bool)','true')
        if args.cache_recovery_only:
            selected = []
            for epoch,cache in sorted(inventory['beaconCaches'].items(),key=lambda item:int(item[0])):
                state = inventory['epochs'].get(epoch)
                if state and state['sealed'] and int(cache['seed'],16) and int(cache['config'],16):
                    require(words(state['raw'],10)[1] == int(cache['seed'],16),'Historical beacon has no ledger replacement')
                    selected.append((int(epoch),cache,state))
                    if len(selected) == 64:
                        break
            require(len(selected) == 64,'A complete settled cache batch is required')
            launch = number('ledger','launchTime()')
            now = int(rpc.call('eth_getBlockByNumber',['latest',False])['timestamp'],16)
            rpc.call('evm_setNextBlockTimestamp',[launch+((now-launch)//60+1)*60+1])
            rpc.call('evm_mine',[])
            cache_data = encode('invalidateEpochs(uint48[])','['+','.join(str(epoch) for epoch,_,_ in selected)+']')
            zero = '0x'+'0'*40
            payload = '('+','.join([zero,'0x',zero,'0x',manifest['implementations']['beacon'],cache_data])+')'
            send('reclaim-closed-beacon-cache','admin','emergencyUpgrade((address,bytes,address,bytes,address,bytes))',payload)
            require(number('admin','recoveryRequired()') == 0,'Existing-code recovery checkpoint failed')
            require(number('ledger','moduleGeneration()') == number('admin','suiteRevision()'),'Existing-code recovery generation mismatch')
            reader = ProofMigration(t,args.inventory,args.output/'migration.json',cast=args.cast)
            values = reader.storage(manifest['beacon'],[slot for _,cache,_ in selected for slot in cache['storageSlots']])
            require(all(int(value,16) == 0 for value in values),'Closed beacon cache was not cleared')
            for epoch,_,state in selected:
                require(call('ledger','epochInfo(uint48)',epoch) == state['raw'],'Historical epoch changed during capacity recovery')
            reader.accounting()
            for account,balance in inventory['tokenBalances'].items():
                require(number('token','balanceOf(address)',account) == balance,'Token balance changed during capacity recovery')
            for role in ['ledger','engine','beacon']:
                require('0x'+call('admin','implementationOf(address)',manifest[role])[-40:].lower()
                        == manifest['implementations'][role].lower(),'Capacity recovery changed implementation addresses')
            result = {'status':'PASS_EXISTING_CODE_CACHE_RECOVERY_FORK_ONLY','mainnetTransactionsSent':0,
                'inventorySha256':inventory['inventorySha256'],'epochs':[epoch for epoch,_,_ in selected],
                'historicalCacheRowsCleared':128,'proxyAddressesUnchanged':True,'implementationsUnchanged':True,
                'rewardsAndBalancesUnchanged':True,'recoveryRequired':False,'transactionHash':
                    t.records['reclaim-closed-beacon-cache']['receipt']['transactionHash']}
            atomic_json(args.output/'result.json',result)
            print(json.dumps(result,indent=2))
            return
        ledger_migration = deploy('ZoruLedgerMigration')
        beacon_migration = deploy('ZoruDrandBeaconMigration')
        upgrade('migration',ledger_migration,beacon_migration)
        migration = ProofMigration(t,args.inventory,args.output/'migration.json',cast=args.cast,batch_size=args.batch_size)
        t.interruption_label=f'proof-clear-{args.batch_size:06d}'
        t.interrupt = True
        try:
            migration.run()
            raise RuntimeError('Expected interrupted-migration fixture did not interrupt')
        except InterruptedError:
            migration.accounting()
        migration = ProofMigration(t,args.inventory,args.output/'migration.json',cast=args.cast,batch_size=args.batch_size)
        migration.run()
        # Only closed, inventoried old cache rows are eligible for cleanup.
        caches = sorted((int(epoch),record) for epoch,record in inventory['beaconCaches'].items()
                        if any(int(record[key],16) for key in ['seed','config']))
        for low in range(0,len(caches),32):
            part = caches[low:low+32]
            before = migration.storage(manifest['beacon'],[slot for _,record in part for slot in record['storageSlots']])
            require(before == [record[key] for _,record in part for key in ['seed','config']], 'Fork beacon source changed')
            send(f'beacon-clear-{low:06d}','beacon','clearHistoricalCache(uint48[])','['+','.join(str(e) for e,_ in part)+']')
            after = migration.storage(manifest['beacon'],[slot for _,record in part for slot in record['storageSlots']])
            require(all(int(value,16) == 0 for value in after), 'Fork beacon cleanup left old rows')
        ledger_final, beacon_final = deploy('ZoruLedger'), deploy('ZoruDrandBeacon')
        upgrade('final',ledger_final,beacon_final)
        migration.accounting()
        for low in range(0,len(migration.proofs),32):
            migration.verify_proofs(migration.proofs[low:low+32],cleared=True)
        ids = sorted((int(epoch),record) for epoch,record in migration.epochs.items())
        for low in range(0,len(ids),16):
            migration.verify_epochs(ids[low:low+16],'cleared')
        for account,balance in inventory['tokenBalances'].items():
            require(number('token','balanceOf(address)',account) == balance,'Historical token balance changed')
        require(number('token','lifetimeMinted()') == inventory['lifetimeMinted'],'Historical funded supply changed')
        for signature in ['proofMigrationStatus()','epochMigrationStatus()']:
            try:
                call('ledger',signature)
            except ValueError:
                pass
            else:
                raise RuntimeError('Temporary migration method remains in final implementation')
        send('resume-claims','ledger','setClaimsPaused(bool)','false')
        unclaimed = [record for record in inventory['proofs'] if not record['claimed']]
        sealed = set()
        entitlements = {}
        for record in unclaimed:
            epoch = record['epoch']
            if not inventory['epochs'][str(epoch)]['sealed'] and epoch not in sealed:
                send('seal-historical-'+str(epoch),'ledger','seal(uint48)',epoch)
                sealed.add(epoch)
            send('claim-historical-'+record['digest'][2:],'ledger','claim(bytes32)',record['digest'])
            entitlements[record['beneficiary']] = entitlements.get(record['beneficiary'],0)+record['entitlement']
        for account,amount in entitlements.items():
            require(number('token','balanceOf(address)',account) == inventory['tokenBalances'].get(account,0)+amount,
                    'Historical unclaimed entitlement was not paid to its original owner')
        try:
            call('ledger','claim(bytes32)',inventory['proofs'][0]['digest'])
        except ValueError:
            pass
        else:
            raise RuntimeError('A previously paid proof can be claimed twice')
        result = {'status':'PASS_MAINNET_STATE_FORK_ONLY','mainnetTransactionsSent':0,'blockNumber':inventory['blockNumber'],
            'blockHash':inventory['blockHash'],'inventorySha256':inventory['inventorySha256'],
            'proofsVerified':len(migration.proofs),'epochsVerified':len(ids),'beaconCachesCleared':len(caches),
            'historicalUnclaimedProofsPaid':len(unclaimed),'historicalUnclaimedBaseUnitsPaid':sum(entitlements.values()),
            'interruptedMigrationResumed':True,'proxyAddresses':{k:manifest[k] for k in ['ledger','engine','beacon']},
            'transactions':len(t.records),'finalLedgerImplementation':ledger_final,'finalBeaconImplementation':beacon_final}
        atomic_json(args.output/'result.json',result)
        print(json.dumps(result,indent=2))
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()
        gateway.shutdown()
        gateway.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rpc',required=True)
    for name in ['manifest','inventory','artifacts','output']:
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--cast',default='cast')
    parser.add_argument('--anvil',default='anvil')
    parser.add_argument('--cache-recovery-only',action='store_true')
    parser.add_argument('--batch-size',type=int,choices=[16,32,64],default=16)
    run(parser.parse_args())


if __name__ == '__main__':
    main()

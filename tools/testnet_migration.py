#!/usr/bin/env python3
"""Exercise unchanged proxies through a real isolated VEX migration and settlement."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
from native_ram_probe import Experiment, require

IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
ALICE = '0x00000000000000000000000000000000000a11ce'
BOB = '0x0000000000000000000000000000000000000b0b'


class MigrationExperiment(Experiment):
    def __init__(self, args):
        super().__init__(args)
        self.result['schema'] = 'zoru-testnet-migration-1'
        self.result['scope'] = 'Real private VEX transactions; deterministic test beacon and accounting engine'
        self.contracts = {}

    def abi(self, signature, *args):
        return subprocess.check_output([self.a.cast, 'calldata', signature, *map(str, args)], text=True).strip()

    def view(self, role, signature, *args):
        return self.rpc('eth_call', [{'to': self.contracts[role], 'data': self.abi(signature, *args)}, 'latest'])

    def number(self, role, signature, *args):
        return int(self.view(role, signature, *args), 16)

    def deploy(self, name, *args):
        artifact = json.loads((self.a.artifacts/(name+'.artifact.json')).read_text())
        creation = artifact['bytecode']['object']
        if args:
            creation += subprocess.check_output([self.a.cast, 'abi-encode', args[0], *map(str,args[1:])], text=True).strip()[2:]
        receipt = self.send('deploy-'+name, ['--create', creation], gas_limit=6_000_000)
        self.contracts[name] = receipt['contractAddress']
        actual = bytearray.fromhex(self.rpc('eth_getCode', [receipt['contractAddress'], 'latest'])[2:])
        expected = bytearray.fromhex(artifact['deployedBytecode']['object'][2:])
        # Immutable constructor arguments are compiler-listed address/uint words.
        for refs in artifact['deployedBytecode'].get('immutableReferences', {}).values():
            require(len(args) == 2, 'Unknown immutable deployment shape')
            word = int(str(args[1]), 16) if str(args[1]).startswith('0x') else int(args[1])
            for ref in refs:
                require(ref['length'] == 32, 'Unexpected immutable size')
                expected[ref['start']:ref['start']+32] = word.to_bytes(32,'big')
        require(actual == expected, 'Deployed runtime differs from reviewed artifact '+name)
        self.result.setdefault('runtimeSha256', {})[name] = hashlib.sha256(actual).hexdigest()
        self.result['contracts'] = self.contracts
        self.save()
        return receipt['contractAddress']

    def tx(self, label, role, signature, *args, gas_limit=2_000_000):
        return self.send(label, [self.contracts[role], signature, *map(str,args)], gas_limit=gas_limit)

    def wait_until(self, timestamp):
        deadline = time.monotonic()+240
        while int(self.rpc('eth_getBlockByNumber', ['latest',False])['timestamp'],16) < timestamp:
            require(time.monotonic()<deadline, 'Isolated chain did not reach the required epoch')
            time.sleep(0.5)

    def upgrade(self, role):
        implementation = self.contracts[role]
        suite = '('+implementation+',0x,'+'0x'+'0'*40+',0x,'+'0x'+'0'*40+',0x)'
        self.tx('schedule-'+role,'ZoruAdminAdapter','scheduleUpgrade((address,bytes,address,bytes,address,bytes))',suite)
        activation = self.number('ZoruAdminAdapter','activationTime()')
        self.wait_until(activation+1)
        self.tx('activate-'+role,'ZoruAdminAdapter','executeScheduledUpgrade()')
        active = self.rpc('eth_getStorageAt',[self.contracts['ledger'],IMPL_SLOT,'latest'])
        require(('0x'+active[-40:]).lower()==implementation.lower(), 'Implementation activation mismatch')
        require(self.number('ZoruAdminAdapter','recoveryRequired()')==0,'Recovery checkpoint failed')
        require(self.number('ledger','moduleGeneration()')==self.number('ZoruAdminAdapter','suiteRevision()'),'Generation mismatch')

    def proof(self, label, epoch, owner, nonce):
        receipt = self.tx(label,'ledger','submit(uint48,address,uint256)',epoch,owner,nonce)
        logs = [l for l in receipt['logs'] if l['address'].lower()==self.contracts['ledger'].lower() and len(l['topics'])==4]
        require(len(logs)==1,'Expected one accepted proof event')
        return logs[0]['topics'][2]

    def snapshot(self):
        return {k:self.number('ledger',k+'()') for k in ['allocatedSupply','fundedSupply','paidSupply','totalProofs']} | {
            'ledgerBalance':self.number('ZoruToken','balanceOf(address)',self.contracts['ledger']),
            'aliceBalance':self.number('ZoruToken','balanceOf(address)',ALICE),
            'bobBalance':self.number('ZoruToken','balanceOf(address)',BOB),
            'lifetimeMinted':self.number('ZoruToken','lifetimeMinted()')}

    def run(self):
        require(not self.a.output.exists(),'Existing run must be reconciled before rerunning')
        self.verify()
        public = subprocess.check_output([self.a.cast,'wallet','address','--keystore',str(self.a.keystore),'--password-file',str(self.a.password_file)],text=True).strip()
        require(public.lower()==self.a.account.lower(),'Signer mismatch')
        self.result['nativeCodeHash']=self.native('get_code_hash',{'account_name':'vex.evm'})['code_hash']
        delay=getattr(self.a,'launch_delay',240)
        require(60<=delay<=600,'Test launch delay must allow bounded deployment preparation')
        launch=int(self.rpc('eth_getBlockByNumber',['latest',False])['timestamp'],16)+delay
        self.result['launchTime']=launch
        self.deploy('ZoruToken','constructor(address)',self.a.account)
        self.deploy('ZoruAdminAdapter','constructor(address)',self.contracts['ZoruToken'])
        self.deploy('ZoruLedgerV1')
        self.deploy('ZoruLedgerMigration')
        self.deploy('ZoruLedger')
        self.deploy('AlwaysAcceptEngine')
        self.deploy('MockBeacon','constructor(uint256)',launch)
        d='('+','.join([self.contracts['ZoruLedgerV1'],self.contracts['AlwaysAcceptEngine'],self.abi('valid(bytes32,uint256)','0x'+'0'*64,1),
                       self.contracts['MockBeacon'],self.abi('releaseTime(uint48)',0),str(launch),str((2**256-1)>>16)])+')'
        self.tx('deploy-existing-suite','ZoruAdminAdapter','deploySuite((address,address,bytes,address,bytes,uint256,uint256))',d,gas_limit=8_000_000)
        for role in ['ledger','engine','beacon']:
            self.contracts[role]='0x'+self.view('ZoruAdminAdapter',role+'Proxy()')[-40:]
        self.tx('bind-test-token-issuer','ZoruToken','setIssuer(address)',self.contracts['ledger'])
        self.result['contracts']=self.contracts
        self.save()
        self.wait_until(launch+1)
        first=self.proof('existing-first-proof',0,ALICE,1)
        second=self.proof('existing-second-proof',0,BOB,2)
        self.wait_until(launch+61)
        self.tx('existing-seal','ledger','seal(uint48)',0)
        self.tx('existing-claim','ledger','claim(bytes32)',first)
        epoch=self.number('ledger','epochNow()')
        third=self.proof('existing-unsealed-proof',epoch,ALICE,3)
        self.tx('pause-admission','ledger','setAdmissionPaused(bool)','true')
        self.tx('pause-claims','ledger','setClaimsPaused(bool)','true')
        baseline=self.snapshot()
        self.result['beforeMigration']=baseline
        source={digest:self.view('ledger','proofs(bytes32)',digest) for digest in [first,second,third]}
        source_epochs={e:self.view('ledger','epochInfo(uint48)',e) for e in [0,epoch]}
        self.upgrade('ZoruLedgerMigration')
        inventory='0x'+hashlib.sha256(json.dumps(source,sort_keys=True).encode()).hexdigest()
        self.tx('start-migration','ledger','startProofMigration(bytes32,uint256)',inventory,3)
        for i,digest in enumerate(source):
            batch='['+digest+']'
            self.tx('copy-proof-'+str(i),'ledger','copyLegacyProofs(bytes32[])',batch)
            require(self.view('ledger','proofs(bytes32)',digest)==source[digest],'Destination proof mismatch')
            require(self.snapshot()==baseline,'Reward or token state changed during migration')
            self.tx('cleanup-proof-'+str(i),'ledger','clearLegacyProofs(bytes32[])',batch)
            base=int(subprocess.check_output([self.a.cast,'index','bytes32',digest,'13'],text=True).strip(),16)
            for offset in range(3):
                require(int(self.rpc('eth_getStorageAt',[self.contracts['ledger'],hex(base+offset),'latest']),16)==0,'Historical source slot retained')
        status=self.view('ledger','proofMigrationStatus()')
        require(int(status[-64:],16)==1,'Migration completeness not proven')
        self.result['migrationStatus']=status
        epoch_inventory='0x'+hashlib.sha256(json.dumps(source_epochs,sort_keys=True).encode()).hexdigest()
        self.tx('start-epoch-migration','ledger','startEpochMigration(bytes32,uint256)',epoch_inventory,len(source_epochs))
        epoch_batch='['+','.join(map(str,source_epochs))+']'
        self.tx('copy-historical-epochs','ledger','copyLegacyEpochs(uint48[])',epoch_batch)
        for e,record in source_epochs.items():
            require(self.view('ledger','epochInfo(uint48)',e)==record,'Destination epoch mismatch')
        require(self.snapshot()==baseline,'Epoch copy changed reward accounting')
        self.tx('clear-historical-epochs','ledger','clearLegacyEpochs(uint48[])',epoch_batch)
        for e in source_epochs:
            base=int(subprocess.check_output([self.a.cast,'index','uint48',str(e),'12'],text=True).strip(),16)
            for offset in range(9):
                require(int(self.rpc('eth_getStorageAt',[self.contracts['ledger'],hex(base+offset),'latest']),16)==0,'Historical epoch slot retained')
        status=self.view('ledger','epochMigrationStatus()')
        require(int(status[-64:],16)==1,'Epoch migration completeness not proven')
        self.result['epochMigrationStatus']=status
        self.tx('retire-migration-receipts','ledger','clearMigrationReceipts()')
        for slot in [17,18,19,20,22,23,24,25]:
            require(int(self.rpc('eth_getStorageAt',[self.contracts['ledger'],hex(slot),'latest']),16)==0,
                    'Temporary migration receipt remains')
        self.result['temporaryMigrationSlotsCleared']=True
        self.upgrade('ZoruLedger')
        require(self.snapshot()==baseline,'Final upgrade changed entitlements')
        for digest,record in source.items():require(self.view('ledger','proofs(bytes32)',digest)==record,'Final historical lookup changed')
        self.tx('resume-claims','ledger','setClaimsPaused(bool)','false')
        self.tx('historical-unclaimed-reward','ledger','claim(bytes32)',second)
        self.tx('historical-unsealed-epoch-seal','ledger','seal(uint48)',epoch)
        self.tx('historical-unsealed-reward','ledger','claim(bytes32)',third)
        self.tx('resume-admission','ledger','setAdmissionPaused(bool)','false')
        epoch=self.number('ledger','epochNow()')
        fresh=self.proof('compact-first-proof',epoch,ALICE,4)
        another=self.proof('compact-second-proof',epoch,BOB,5)
        self.wait_until(launch+(epoch+1)*60+1)
        self.tx('compact-seal','ledger','seal(uint48)',epoch)
        self.tx('compact-first-claim','ledger','claim(bytes32)',fresh)
        self.tx('compact-second-claim','ledger','claim(bytes32)',another)
        self.result['afterSettlement']=self.snapshot()
        require(self.number('ledger','fundedLiability()')==0 and self.number('ledger','unfundedLiability()')==0,'Outstanding test liabilities')
        self.result['status']='PASS_REAL_ISOLATED_PROXY_MIGRATION_AND_SETTLEMENT'
        self.save()
        print(json.dumps({'status':self.result['status'],'ledger':self.contracts['ledger'],'transactions':len(self.result['operations'])}),flush=True)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cast',required=True)
    p.add_argument('--rpc-port',type=int,default=18547)
    p.add_argument('--native-port',type=int,default=19888)
    p.add_argument('--account',required=True)
    p.add_argument('--keystore',type=Path,required=True)
    p.add_argument('--password-file',type=Path,required=True)
    p.add_argument('--bytecode',type=Path,required=True)
    p.add_argument('--artifacts',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--launch-delay',type=int,default=240)
    MigrationExperiment(p.parse_args()).run()


if __name__=='__main__':main()

#!/usr/bin/env python3
"""Journaled release of the existing ZORU mainnet proxies.

Preparation, migration, final activation and admission are distinct resumable
stages. Every stage checks the chain and reviewed implementation bytes. Signing
uses existing protected workflows; this program never handles a private key.
"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import subprocess
import time

from proof_inventory import require, words
from proof_migration import ProofMigration
from release_transaction import MainnetTransactions, NATIVE_CHAIN, atomic_json

ZERO = '0x'+'0'*40
NAMES = ['ZoruLedgerMigration','ZoruDrandBeaconMigration','ZoruLedger','ZoruDrandBeacon']


class Release:
    def __init__(self, args):
        self.a=args
        args.output.mkdir(mode=0o700,parents=True,exist_ok=True)
        require(args.output.stat().st_mode & 0o077==0,'Release evidence must remain private')
        self.path=args.output/'release.json'
        self.state=json.loads(self.path.read_text()) if self.path.exists() else {
            'schema':'zoru-mainnet-release-1','chainId':6736,'implementations':{},'stages':{}}
        self.artifacts={name:json.loads((args.artifacts/(name+'.artifact.json')).read_text()) for name in NAMES}
        self.owner=MainnetTransactions(args.manifest,args.output/'owner-transactions',args.wallet,
            args.rpc,args.native,args.cast,fee_budget_wei=100*10**18)
        self.manifest=self.owner.manifest
        self.rpc=self.owner.rpc
        self.proof_signer=None
        if args.operational_command:
            command=json.loads(args.operational_command.read_text())
            require(isinstance(command,list) and command and all(isinstance(v,str) for v in command),
                    'Protected signing command must be an explicit argument array')
            def sign(transaction):
                signed=subprocess.run(command,input=json.dumps(transaction),text=True,capture_output=True,timeout=90)
                require(signed.returncode==0,'Protected operational signing failed; retain the exact nonce and journal')
                return json.loads(signed.stdout)
            self.proof_signer=MainnetTransactions(args.manifest,args.output/'proof-transactions',args.wallet,
                args.rpc,args.native,args.cast,signing_account=args.operational_account,
                signing_callback=sign,fee_budget_wei=65*10**18)
        for name,address in self.state['implementations'].items():
            role='ledger' if name.startswith('ZoruLedger') else 'beacon'
            for signer in [self.owner,self.proof_signer]:
                if signer:signer.authorize_implementation(role,address,self.artifacts[name]['deployedBytecode']['object'])
        self.owner.verify()
        for signature in ['admissionPaused()','claimsPaused()']:
            if args.stage!='resume':require(self.number('ledger',signature)==1,'Both maintenance pauses are required')

    def save(self):atomic_json(self.path,self.state)

    def data(self,signature,*values):
        return subprocess.check_output([self.a.cast,'calldata',signature,*map(str,values)],text=True).strip()

    def call(self,role,signature,*values):
        return self.owner.call(self.manifest[role],self.data(signature,*values))

    def number(self,role,signature,*values):return words(self.call(role,signature,*values),1)[0]

    def send(self,label,role,signature,*values):
        return self.owner.send(label,self.manifest[role],self.data(signature,*values))

    def native(self,method,payload=None):
        url=self.owner.native.url
        connection=(http.client.HTTPSConnection if url.scheme=='https' else http.client.HTTPConnection)(url.hostname,url.port,timeout=20)
        try:
            connection.request('POST',url.path.rstrip('/')+'/v1/chain/'+method,json.dumps(payload or {}),{'Content-Type':'application/json'})
            response=connection.getresponse()
            require(response.status==200,'Native release check failed')
            result=json.loads(response.read(8*1024*1024))
        finally:connection.close()
        if method=='get_info':require(result['chain_id']==NATIVE_CHAIN,'Native chain changed')
        return result

    def gate(self):
        readiness=json.loads(self.a.readiness.read_text())
        require(readiness['status']=='PASS_PRODUCTION_READINESS','Production readiness has not passed')
        root=Path(__file__).resolve().parents[1]
        head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
        remote=subprocess.check_output(['git','ls-remote','origin','refs/heads/main'],cwd=root,text=True).split()[0]
        require(head==remote==readiness['sourceCommit'],'The exact reviewed source must be published on main')
        require(not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),
                'Release source has uncommitted changes')
        for name in NAMES:
            artifact=self.artifacts[name]
            compiled=json.loads((root/'contracts/out-runtime'/(name+'.sol')/(name+'.json')).read_text())
            require(all(artifact[k]['object']==compiled[k]['object'] for k in ['bytecode','deployedBytecode']),
                    'Review artifacts differ from the published source build')
            digest=hashlib.sha256(bytes.fromhex(artifact['deployedBytecode']['object'][2:])).hexdigest()
            require(readiness['runtimeSha256'][name]==digest,'Readiness artifact fingerprint differs')
        self.state['sourceCommit']=head
        self.state['readinessSha256']=hashlib.sha256(self.a.readiness.read_bytes()).hexdigest()
        self.save()

    def upgrade(self,label,ledger,beacon):
        arguments='('+','.join([ledger,'0x',ZERO,'0x',beacon,'0x'])+')'
        self.send('schedule-'+label,'admin','scheduleUpgrade((address,bytes,address,bytes,address,bytes))',arguments)
        # A recorded activation is resumable without scheduling it again.
        if self.number('admin','hasPendingUpgrade()'):
            activation=self.number('admin','activationTime()')
            deadline=time.monotonic()+180
            while int(self.rpc.call('eth_getBlockByNumber',['latest',False])['timestamp'],16)<activation+1:
                require(time.monotonic()<deadline,'Scheduled epoch did not advance')
                time.sleep(0.5)
        self.send('activate-'+label,'admin','executeScheduledUpgrade()')
        require(self.number('admin','recoveryRequired()')==0,'Upgrade recovery checkpoint failed')
        require(self.number('ledger','moduleGeneration()')==self.number('admin','suiteRevision()'),
                'Suite revision differs from the Ledger generation')
        for role,expected in [('ledger',ledger),('beacon',beacon),('engine',self.manifest['implementations']['engine'])]:
            actual=self.call('admin','implementationOf(address)',self.manifest[role])
            require('0x'+actual[-40:].lower()==expected.lower(),'Unexpected implementation after activation')
        self.owner.verify()

    def prepare(self):
        self.gate()
        for name in NAMES:
            if name in self.state['implementations']:continue
            ram=self.native('get_account',{'account_name':'vex.evm'})
            require(ram['ram_quota']-ram['ram_usage']>32768,'Insufficient measured RAM headroom for preparation')
            artifact=self.artifacts[name]
            receipt=self.owner.send('deploy-'+name,None,artifact['bytecode']['object'],
                creation_runtime=artifact['deployedBytecode']['object'])
            address=receipt['contractAddress']
            self.state['implementations'][name]=address
            self.state.setdefault('deploymentReceipts',{})[name]=receipt
            self.save()
            role='ledger' if name.startswith('ZoruLedger') else 'beacon'
            for signer in [self.owner,self.proof_signer]:
                if signer:signer.authorize_implementation(role,address,artifact['deployedBytecode']['object'])
        self.upgrade('migration',self.state['implementations']['ZoruLedgerMigration'],
                     self.state['implementations']['ZoruDrandBeaconMigration'])
        self.state['stages']['prepare']='MIGRATION_IMPLEMENTATIONS_ACTIVE_PAUSED'
        self.state['ramAfterPreparation']=self.native('get_account',{'account_name':'vex.evm'})
        self.save()

    def active(self,ledger,beacon):
        for role,name in [('ledger',ledger),('beacon',beacon)]:
            actual='0x'+self.call('admin','implementationOf(address)',self.manifest[role])[-40:].lower()
            require(actual==self.state['implementations'][name].lower(),'Expected release stage is not active')

    def inventory(self):
        path=self.a.output/'frozen-inventory.json'
        if not path.exists():
            with open(self.a.output/'inventory.log','w') as log:
                subprocess.run(['python3',str(Path(__file__).with_name('proof_inventory.py')),
                    '--rpc',self.a.rpc,'--manifest',str(self.a.manifest),'--require-paused','--output',str(path)],
                    check=True,stdout=log,stderr=log)
        return path

    def native_inventory(self,path,mode,contract='ledger'):
        output=self.a.output/(mode+'-native-'+contract+'.json')
        subprocess.run(['python3',str(Path(__file__).with_name('native_storage_inventory.py')),
            '--manifest',str(self.a.manifest),'--inventory',str(path),'--rpc',self.a.rpc,'--native',self.a.native,
            '--mode',mode,'--contract',contract,'--output',str(output)],check=True,stdout=subprocess.DEVNULL)
        return json.loads(output.read_text())

    def migration(self):
        return ProofMigration(self.owner,self.inventory(),self.a.output/'migration.json',cast=self.a.cast,
                              batch_size=32,proof_transactions=self.proof_signer)

    def migrate(self):
        self.active('ZoruLedgerMigration','ZoruDrandBeaconMigration')
        path=self.inventory()
        if not self.state.get('nativeSourceVerified'):
            for contract in ['ledger','beacon']:self.native_inventory(path,'legacy',contract)
            self.state['nativeSourceVerified']=True
            self.save()
        migration=self.migration()
        migration.run()
        caches=sorted((int(epoch),record) for epoch,record in migration.inventory['beaconCaches'].items()
                      if any(int(record[key],16) for key in ['seed','config']))
        for low in range(0,len(caches),32):
            part=caches[low:low+32]
            slots=[slot for _,record in part for slot in record['storageSlots']]
            old=migration.storage(self.manifest['beacon'],slots)
            expected=[record[key] for _,record in part for key in ['seed','config']]
            require(old==expected or all(int(value,16)==0 for value in old),'Historical beacon source changed')
            self.send(f'beacon-clear-{low:06d}','beacon','clearHistoricalCache(uint48[])',
                      '['+','.join(str(epoch) for epoch,_ in part)+']')
            require(all(int(value,16)==0 for value in migration.storage(self.manifest['beacon'],slots)),
                    'Obsolete beacon storage remains')
        self.verify_records(migration)
        for contract in ['ledger','beacon']:self.native_inventory(path,'canonical',contract)
        barrier=self.native('get_info')['head_block_num']
        self.state['irreversibilityBarrier']=barrier
        self.state['stages']['migrate']='ALL_RECORDS_VERIFIED_AND_OBSOLETE_ROWS_CLEARED'
        self.save()
        self.irreversible(barrier)

    def verify_records(self,migration):
        migration.accounting()
        for low in range(0,len(migration.proofs),32):migration.verify_proofs(migration.proofs[low:low+32],cleared=True)
        epochs=sorted((int(epoch),record) for epoch,record in migration.epochs.items())
        for low in range(0,len(epochs),32):migration.verify_epochs(epochs[low:low+32],'cleared')
        for account,balance in migration.inventory['tokenBalances'].items():
            require(self.number('token','balanceOf(address)',account)==balance,'Historical token balance changed')
        require(self.number('token','lifetimeMinted()')==migration.inventory['lifetimeMinted'],
                'Historical minted supply changed')

    def irreversible(self,barrier):
        deadline=time.monotonic()+1800
        while True:
            info=self.native('get_info')
            if info['last_irreversible_block_num']>=barrier:
                self.state['irreversibleAt']=info['last_irreversible_block_num']
                self.save()
                return
            require(time.monotonic()<deadline,'Native finality did not reach the migration barrier')
            time.sleep(2)

    def finalize(self):
        require(self.state['stages'].get('migrate')=='ALL_RECORDS_VERIFIED_AND_OBSOLETE_ROWS_CLEARED',
                'Verified migration and cleanup are incomplete')
        self.irreversible(self.state['irreversibilityBarrier'])
        migration=self.migration()
        self.verify_records(migration)
        current='0x'+self.call('admin','implementationOf(address)',self.manifest['ledger'])[-40:].lower()
        if current!=self.state['implementations']['ZoruLedger'].lower():
            for signature,expected in [('proofMigrationStatus()',len(migration.proofs)),('epochMigrationStatus()',len(migration.epochs))]:
                status=words(self.call('ledger',signature),5)
                require(status==[int(migration.inventory_hash,16),expected,expected,expected,1],
                        'Migration completion counters differ')
            self.upgrade('final',self.state['implementations']['ZoruLedger'],self.state['implementations']['ZoruDrandBeacon'])
        self.active('ZoruLedger','ZoruDrandBeacon')
        self.verify_records(migration)
        for contract in ['ledger','beacon']:self.native_inventory(self.inventory(),'canonical',contract)
        self.state['stages']['finalize']='REVIEWED_FINAL_IMPLEMENTATIONS_ACTIVE_PAUSED'
        self.state['ramAfterCleanup']=self.native('get_account',{'account_name':'vex.evm'})
        self.save()

    def resume(self):
        require(self.state['stages'].get('finalize')=='REVIEWED_FINAL_IMPLEMENTATIONS_ACTIVE_PAUSED',
                'Final release has not been verified')
        self.active('ZoruLedger','ZoruDrandBeacon')
        self.send('resume-claims','ledger','setClaimsPaused(bool)','false')
        self.send('resume-admission','ledger','setAdmissionPaused(bool)','false')
        require(self.number('ledger','admissionPaused()')==self.number('ledger','claimsPaused()')==0,
                'Mining admission or claiming remains paused')
        self.state['stages']['resume']='MINING_AND_CLAIMS_ENABLED'
        self.save()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage',choices=['prepare','migrate','finalize','resume'])
    for name in ['manifest','artifacts','output','readiness']:parser.add_argument('--'+name,type=Path,required=True)
    for name in ['rpc','native','wallet']:parser.add_argument('--'+name,required=True)
    parser.add_argument('--cast',default='cast')
    parser.add_argument('--operational-command',type=Path)
    parser.add_argument('--operational-account')
    args=parser.parse_args()
    os.umask(0o077)
    release=Release(args)
    getattr(release,args.stage)()
    print(json.dumps({'stage':args.stage,'status':release.state['stages'][args.stage]}),flush=True)


if __name__=='__main__':main()

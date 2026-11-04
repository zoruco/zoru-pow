#!/usr/bin/env python3
"""Bounded real native storage/accounting load; explicitly separate from PoW throughput."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import time
from native_ram_probe import require
from testnet_migration import MigrationExperiment


class LoadExperiment(MigrationExperiment):
    def send(self, label, call, expected=1, gas_limit=2_000_000):
        # Every transaction remains bounded by the previously authorized test gas allocation.
        price = int(self.rpc('eth_gasPrice', []), 16)
        spent = sum(int(op['receipt']['gasUsed'],16)*int(op['receipt']['effectiveGasPrice'],16)
                    for op in self.result['operations'] if 'receipt' in op)
        require(spent+gas_limit*price <= 650*10**18, 'Authorized test fee budget reached')
        return super().send(label, call, expected, gas_limit)

    def run(self):
        require(not self.a.output.exists(), 'Existing load record must be reconciled before restart')
        self.verify()
        public = subprocess.check_output([self.a.cast,'wallet','address','--keystore',str(self.a.keystore),
                                          '--password-file',str(self.a.password_file)],text=True).strip()
        require(public.lower()==self.a.account.lower(),'Test signer mismatch')
        self.contracts = json.loads(self.a.previous.read_text())['contracts']
        self.result['schema']='zoru-native-accounting-load-1'
        self.result['scope']='Real VEX transactions with four beneficiaries and a deterministic accounting engine. Not PoW throughput.'
        self.result['startedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
        baseline=self.snapshot()
        self.result['baseline']=baseline
        self.result['milestones']=[]
        self.deploy('ZoruLoadProbe','constructor(address)',self.contracts['ledger'])
        beneficiaries=['0x00000000000000000000000000000000000b1001','0x00000000000000000000000000000000000b1002',
                       '0x00000000000000000000000000000000000b1003','0x00000000000000000000000000000000000b1004']
        beneficiary_argument='['+','.join(beneficiaries)+']'
        digests=[]
        epochs=set()
        started=time.monotonic()
        for milestone in [100,1000,10000,20000]:
            while len(digests)<milestone:
                # Native CPU limits apply in addition to EVM gas limits.
                count=min(20,milestone-len(digests))
                epoch=self.number('ledger','epochNow()')
                launch=self.number('ledger','launchTime()')
                now=int(self.rpc('eth_getBlockByNumber',['latest',False])['timestamp'],16)
                closes=launch+(epoch+1)*60
                if closes-now <= 8:
                    self.wait_until(closes+1)
                    continue
                receipt=self.tx('proofs-'+str(len(digests)+count),'ZoruLoadProbe',
                    'submitBatch(uint48,uint256,uint256,address[])',epoch,1_000_000+len(digests),count,beneficiary_argument,
                    gas_limit=4_000_000)
                accepted=[log for log in receipt['logs'] if log['address'].lower()==self.contracts['ledger'].lower()
                          and len(log['topics'])==4]
                require(len(accepted)==count,'Accepted event count differs from requested batch')
                for log in accepted:
                    digests.append(log['topics'][2]);epochs.add(int(log['topics'][1],16))
                require(self.number('ledger','totalProofs()')==baseline['totalProofs']+len(digests),'Canonical proof count mismatch')
                self.result['accepted']=len(digests)
                self.result['proofDigests']=digests
                self.save()
            self.result['milestones'].append({'acceptedProofs':milestone,'elapsedSeconds':time.monotonic()-started,
                                             'nativeRam':self.ram(),'epochCount':len(epochs)})
            self.save()
            print(json.dumps(self.result['milestones'][-1]),flush=True)
        require(len(set(digests))==20000,'Repeated proof identifier')
        launch=self.number('ledger','launchTime()')
        self.wait_until(launch+(max(epochs)+1)*60+1)
        ids=sorted(epochs)
        for low in range(0,len(ids),64):
            part='['+','.join(map(str,ids[low:low+64]))+']'
            self.tx('seal-load-epochs-'+str(low),'ZoruLoadProbe','sealBatch(uint48[])',part,gas_limit=8_000_000)
        before_claim=self.snapshot()
        self.result['beforeClaims']=before_claim
        for low in range(0,len(digests),50):
            part='['+','.join(digests[low:low+50])+']'
            self.tx('claims-'+str(min(low+50,20000)),'ZoruLoadProbe','claimBatch(bytes32[])',part,gas_limit=5_000_000)
            self.result['claimed']=min(low+50,20000)
            self.save()
        after=self.snapshot()
        distributed=sum(self.number('ZoruToken','balanceOf(address)',who) for who in beneficiaries)
        require(after['allocatedSupply']==after['fundedSupply']==after['paidSupply'],'Load reward liabilities remain')
        require(after['lifetimeMinted']==after['allocatedSupply'] and after['ledgerBalance']==0,'Load supply mismatch')
        require(distributed==after['paidSupply']-baseline['paidSupply'],'Beneficiary rewards do not reconcile')
        response=self.http(self.a.rpc_port,'/',{'jsonrpc':'2.0','id':1,'method':'eth_call','params':[
            {'to':self.contracts['ledger'],'data':self.abi('claim(bytes32)',digests[-1])},'latest']})
        require('error' in response,'Double claim accepted')
        self.result.update(status='PASS_REAL_NATIVE_20000_PROOFS_AND_20000_CLAIMS',afterSettlement=after,
                           completedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                           elapsedSeconds=time.monotonic()-started,beneficiaries=beneficiaries,
                           totalTestFeesWei=str(sum(int(op['receipt']['gasUsed'],16)*int(op['receipt']['effectiveGasPrice'],16)
                               for op in self.result['operations'] if 'receipt' in op)))
        self.save()
        print(json.dumps({k:v for k,v in self.result.items() if k in ['status','accepted','claimed','elapsedSeconds','totalTestFeesWei']}),flush=True)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for arg in ['cast','account']:p.add_argument('--'+arg,required=True)
    for arg in ['keystore','password-file','bytecode','artifacts','output','previous']:p.add_argument('--'+arg,type=Path,required=True)
    p.add_argument('--rpc-port',type=int,default=18547)
    p.add_argument('--native-port',type=int,default=19888)
    LoadExperiment(p.parse_args()).run()


if __name__=='__main__':main()

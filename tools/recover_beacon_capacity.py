#!/usr/bin/env python3
"""Recover bounded closed-cache capacity through the already-deployed verifier.

Implementation and proxy addresses remain unchanged. Only fully settled epochs
whose authenticated seed is preserved in the Ledger may be selected.
"""
import argparse
import http.client
import json
from pathlib import Path
import time

from proof_inventory import require, selector, words
from proof_migration import ProofMigration
from release_transaction import MainnetTransactions, atomic_json

ORIGINAL_BEACON_HASH = '0x944660ba222a17302f9f33a079512894223013c79238cf96ee1984bd71c00ca4'
ORIGINAL_LEDGER_HASH = '0x2385f6698b98415d81142dab10099ef8be3d3ed03617987c3b20decfb3942078'


def native_ram(transactions):
    url = transactions.native.url
    connection = (http.client.HTTPSConnection if url.scheme == 'https' else http.client.HTTPConnection)(url.hostname,url.port,timeout=15)
    try:
        connection.request('POST',url.path.rstrip('/')+'/v1/chain/get_account',json.dumps({'account_name':'vex.evm'}),
                           {'Content-Type':'application/json'})
        response = connection.getresponse()
        require(response.status == 200,'Native RAM measurement failed')
        account = json.loads(response.read(1048576))
        return {'ramUsage':account['ram_usage'],'ramQuota':account['ram_quota'],'observedAt':int(time.time())}
    finally:
        connection.close()


def run(args):
    t = MainnetTransactions(args.manifest,args.journal,args.wallet,args.rpc,args.native,cast=args.cast)
    require(t.manifest['approvedImplementationCodeHashes']['beacon'] == [ORIGINAL_BEACON_HASH]
            and t.manifest['approvedImplementationCodeHashes']['ledger'] == [ORIGINAL_LEDGER_HASH],
            'Capacity recovery is restricted to the authenticated original deployment')
    reader = ProofMigration(t,args.inventory,args.output.with_suffix('.progress.json'),cast=args.cast)
    require(reader.inventory.get('maintenancePaused') is True,'A verified paused inventory is required')
    require(args.batches in [1,2],'Capacity recovery is bounded to at most two batches')
    t.verify()
    for function in ['admissionPaused()','claimsPaused()']:
        require(words(t.call(t.manifest['ledger'],selector(function)),1)[0] == 1,'Both maintenance pauses are required')
    reader.accounting()
    by_epoch = {}
    for proof in reader.proofs:
        by_epoch.setdefault(proof['epoch'],[]).append(proof)
    selected = []
    for epoch,cache in sorted(reader.inventory['beaconCaches'].items(),key=lambda item:int(item[0])):
        state = reader.epochs.get(epoch)
        proofs = by_epoch.get(int(epoch),[])
        if not state or not state['sealed'] or not proofs or not all(proof['claimed'] for proof in proofs):
            continue
        if int(cache['seed'],16) and int(cache['config'],16):
            require(words(state['raw'],10)[1] == int(cache['seed'],16),'Ledger does not preserve the selected authenticated seed')
            selected.append((int(epoch),cache,state,proofs))
            if len(selected) == args.batches*64:
                break
    require(len(selected) == args.batches*64,'Insufficient fully verified settled cache records')
    record = {'schema':'zoru-capacity-recovery-1','status':'PREPARED','chainId':6736,
        'inventorySha256':reader.inventory_hash[2:],'newImplementationsDeployed':False,'proxyAddressesChanged':False,
        'epochs':[epoch for epoch,_,_,_ in selected],'operations':[],'before':native_ram(t)}
    if args.output.exists():
        previous = json.loads(args.output.read_text())
        require(previous['inventorySha256'] == record['inventorySha256'] and previous['epochs'] == record['epochs'],
                'Retained capacity recovery refers to different historical records')
        record = previous
    atomic_json(args.output,record)
    for low in range(0,len(selected),64):
        part = selected[low:low+64]
        epoch = words(t.call(t.manifest['ledger'],selector('epochNow()')),1)[0]
        active = words(t.call(t.manifest['ledger'],reader.data('epochInfo(uint48)',epoch)),10)
        if active[0] != 0:
            launch = words(t.call(t.manifest['ledger'],selector('launchTime()')),1)[0]
            closes = launch+(epoch+1)*60
            while int(t.rpc.call('eth_getBlockByNumber',['latest',False])['timestamp'],16) <= closes:
                time.sleep(0.5)
            epoch = words(t.call(t.manifest['ledger'],selector('epochNow()')),1)[0]
            require(words(t.call(t.manifest['ledger'],reader.data('epochInfo(uint48)',epoch)),10)[0] == 0,
                    'A safe empty epoch boundary is unavailable')
        slots = [slot for _,cache,_,_ in part for slot in cache['storageSlots']]
        values = reader.storage(t.manifest['beacon'],slots)
        original_values = [cache[key] for _,cache,_,_ in part for key in ['seed','config']]
        already_cleared = all(int(value,16) == 0 for value in values)
        require(values == original_values or (already_cleared and (t.journal/('recover-cache-capacity-'+str(low)+'.json')).exists()),
                'Selected cache source differs from the frozen inventory without a retained recovery transaction')
        for epoch,_,state,proofs in part:
            require(t.call(t.manifest['ledger'],reader.data('epochInfo(uint48)',epoch)) == state['raw'],
                    'Selected historical epoch changed')
            lookups = reader.reads([('eth_call',[{'to':t.manifest['ledger'],
                'data':reader.data('proofs(bytes32)',proof['digest'])},'latest']) for proof in proofs])
            require(lookups == [proof['raw'] for proof in proofs],'Selected settled proof changed')
        cleanup = reader.data('invalidateEpochs(uint48[])','['+','.join(str(epoch) for epoch,_,_,_ in part)+']')
        zero = '0x'+'0'*40
        payload = '('+','.join([zero,'0x',zero,'0x',t.manifest['implementations']['beacon'],cleanup])+')'
        receipt = t.send('recover-cache-capacity-'+str(low),t.manifest['admin'],
                         reader.data('emergencyUpgrade((address,bytes,address,bytes,address,bytes))',payload))
        require(all(int(value,16) == 0 for value in reader.storage(t.manifest['beacon'],slots)), 'Historical cache cleanup did not complete')
        reader.accounting()
        for epoch,_,state,_ in part:
            require(t.call(t.manifest['ledger'],reader.data('epochInfo(uint48)',epoch)) == state['raw'],
                    'Historical mining snapshot changed during capacity recovery')
        require(words(t.call(t.manifest['admin'],selector('recoveryRequired()')),1)[0] == 0,'Capacity recovery checkpoint failed')
        require(t.call(t.manifest['ledger'],selector('moduleGeneration()')) == t.call(t.manifest['admin'],selector('suiteRevision()')),
                'Capacity recovery generation mismatch')
        t.verify()
        if not any(operation['transactionHash'] == receipt['transactionHash'] for operation in record['operations']):
            record['operations'].append({'transactionHash':receipt['transactionHash'],'receipt':receipt,'epochs':len(part),
                                          'nativeRamAfter':native_ram(t)})
        atomic_json(args.output,record)
    for account,balance in reader.inventory['tokenBalances'].items():
        require(words(t.call(t.manifest['token'],reader.data('balanceOf(address)',account)),1)[0] == balance,
                'Historical token balance changed')
    record.update(status='VERIFIED_EXISTING_CODE_CAPACITY_RECOVERY',after=native_ram(t),rewardsAndBalancesUnchanged=True,
                  historicalCacheRowsCleared=len(selected)*2)
    record['ramReclaimedBytes'] = record['before']['ramUsage']-record['after']['ramUsage']
    atomic_json(args.output,record)
    print(json.dumps({key:value for key,value in record.items() if key not in ['operations','epochs']},indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['manifest','inventory','journal','output']:
        parser.add_argument('--'+name,type=Path,required=True)
    for name in ['wallet','rpc','native']:
        parser.add_argument('--'+name,required=True)
    parser.add_argument('--cast',default='cast')
    parser.add_argument('--batches',type=int,default=1)
    run(parser.parse_args())


if __name__ == '__main__':main()

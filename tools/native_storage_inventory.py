#!/usr/bin/env python3
"""Reconcile every native Ledger storage row against the historical inventory.

This closes the enumeration gap left by Solidity mappings. The native account
scope is scanned completely; unknown or missing rows fail closed.
"""
import argparse
import http.client
import json
from pathlib import Path
import time

from proof_inventory import Rpc, inventory_fingerprint, keccak, require
from proof_migration import offset

INITIALIZABLE_SLOT='0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00'
IMPL_SLOT='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
NATIVE='f9f432b1851b5c179d2091a96f593aaed50ec7466b74f89301f957a83e56ce1f'


def run(args):
    manifest=json.loads(args.manifest.read_text())
    inventory=json.loads(args.inventory.read_text())
    require(manifest['chainId']==inventory['chainId']==6736 and inventory['maintenancePaused'],
            'A verified paused mainnet inventory is required')
    require(inventory_fingerprint(inventory)==inventory['inventorySha256'],'Historical inventory fingerprint differs')
    require(inventory['ledger']==manifest['ledger'].lower(),'Ledger address differs')
    rpc=Rpc(args.rpc)
    require(int(rpc.call('eth_chainId',[]),16)==6736,'Wrong EVM network')
    native=Rpc(args.native).url

    def native_call(method,payload):
        connection=(http.client.HTTPSConnection if native.scheme=='https' else http.client.HTTPConnection)(native.hostname,native.port,timeout=30)
        try:
            connection.request('POST',native.path.rstrip('/')+'/v1/chain/'+method,json.dumps(payload),{'Content-Type':'application/json'})
            response=connection.getresponse()
            require(response.status==200,'Native enumeration failed')
            raw=response.read(8*1024*1024+1)
            require(len(raw)<=8*1024*1024,'Native response exceeded limit')
            return json.loads(raw)
        finally:connection.close()

    require(native_call('get_info',{})['chain_id']==NATIVE,'Wrong native network')
    address=manifest[args.contract].lower()
    account=None
    lower='0'
    for _ in range(100):
        result=native_call('get_table_rows',{'code':'vex.evm','scope':'vex.evm','table':'account',
            'json':True,'limit':1000,'lower_bound':lower})
        matches=[row for row in result['rows'] if row['eth_address'].lower()==address[2:]]
        if matches:
            require(len(matches)==1,'Native Ledger account is ambiguous')
            account=matches[0]
            break
        if not result['more']:break
        require(result['next_key']!=lower,'Native account pagination stalled')
        lower=result['next_key']
    require(account is not None,'Native Ledger account was not found within the bounded scan')
    expected={}
    def put(slot,value):
        if value==0:return
        key=f'0x{int(slot,16):064x}'
        require(key not in expected,'Storage inventory contains overlapping slot identities')
        expected[key]=f'0x{value:064x}'
    for record in inventory['proofs'] if args.contract=='ledger' else []:
        values=[int(record['beneficiary'],16) | record['epoch']<<160,record['indexPlusOne'],int(record['claimed'])]
        base=record['legacyStorageSlot'] if args.mode=='legacy' else record['canonicalStorageSlot']
        if args.mode=='canonical':values=[int(record['canonicalStorageValue'],16)]
        for i,value in enumerate(values):put(offset(base,i),value)
    for record in inventory['epochs'].values() if args.contract=='ledger' else []:
        values=[int(record['raw'][i:i+64],16) for i in range(2,len(record['raw']),64)]
        legacy=[*values[:5],values[5] | values[6]<<160,values[7],values[8],values[9]]
        packed=[int(value,16) for value in record['canonicalStorageValues']]
        base=record['legacyStorageSlot'] if args.mode=='legacy' else record['canonicalStorageSlot']
        for i,value in enumerate(legacy if args.mode=='legacy' else packed):put(offset(base,i),value)
    if args.contract=='beacon' and args.mode=='legacy':
        for cache in inventory['beaconCaches'].values():
            for slot,key in zip(cache['storageSlots'],['seed','config']):put(slot,int(cache[key],16))
    admin_slot=f'0x{int(keccak("eip1967.proxy.admin"),16)-1:064x}'
    fixed=[f'0x{i:064x}' for i in range(26 if args.contract=='ledger' else 7)]+[INITIALIZABLE_SLOT,IMPL_SLOT,admin_slot]
    values=rpc.batch([('eth_getStorageAt',[address,slot,'latest']) for slot in fixed])
    for slot,value in zip(fixed,values):put(slot,int(value,16))
    actual={}
    lower='0'
    pages=0
    while True:
        result=native_call('get_table_rows',{'code':'vex.evm','scope':str(account['id']),'table':'storage',
            'json':True,'limit':1000,'lower_bound':lower})
        for row in result['rows']:
            key='0x'+row['key'].lower().removeprefix('0x')
            value='0x'+row['value'].lower().removeprefix('0x')
            require(len(key)==len(value)==66 and key not in actual,'Noncanonical or repeated native storage row')
            actual[key]=value
        pages+=1
        require(pages<=1000,'Native enumeration exceeds its declared bound')
        if not result['more']:break
        require(result['next_key']!=lower,'Native storage pagination stalled')
        lower=result['next_key']
        time.sleep(0.01)
    unknown=sorted(actual.keys()-expected.keys())
    missing=sorted(expected.keys()-actual.keys())
    mismatched=sorted(key for key in actual.keys() & expected.keys() if actual[key]!=expected[key])
    report={'schema':'zoru-native-storage-inventory-1','status':'PASS_COMPLETE_NATIVE_LEDGER_STORAGE' if not unknown+missing+mismatched else 'FAIL_STORAGE_DIVERGENCE',
        'mode':args.mode,'chainId':6736,'contract':args.contract,'address':address,'nativeAccountId':account['id'],
        'inventorySha256':inventory['inventorySha256'],'nativeRows':len(actual),'expectedRows':len(expected),
        'unknownSlots':unknown,'missingSlots':missing,'mismatchedSlots':mismatched,
        'nativeCodeHash':native_call('get_code_hash',{'account_name':'vex.evm'})['code_hash'],'pages':pages}
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    args.output.with_suffix('.rows.json').write_text(json.dumps(actual,sort_keys=True,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    require(report['status'].startswith('PASS'),'Native Ledger storage is not fully accounted for; cleanup is forbidden')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['manifest','inventory','output']:parser.add_argument('--'+name,type=Path,required=True)
    for name in ['rpc','native']:parser.add_argument('--'+name,required=True)
    parser.add_argument('--mode',choices=['legacy','canonical'],required=True)
    parser.add_argument('--contract',choices=['ledger','beacon'],default='ledger')
    run(parser.parse_args())


if __name__=='__main__':main()

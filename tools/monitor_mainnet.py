#!/usr/bin/env python3
"""Read-only chain, accounting and native capacity checks with bounded history."""
import argparse
import datetime
import http.client
import json
from pathlib import Path
import time

from proof_inventory import Rpc, require, selector, words
from release_transaction import IMPLEMENTATION_SLOT, NATIVE_CHAIN, atomic_json, load_mainnet_manifest


def sample(args):
    manifest=load_mainnet_manifest(args.manifest)
    rpc=Rpc(args.rpc)
    require(int(rpc.call('eth_chainId',[]),16)==6736,'Wrong EVM monitoring network')
    native=Rpc(args.native).url
    def native_call(method,payload):
        connection=(http.client.HTTPSConnection if native.scheme=='https' else http.client.HTTPConnection)(native.hostname,native.port,timeout=15)
        try:
            connection.request('POST',native.path.rstrip('/')+'/v1/chain/'+method,json.dumps(payload),{'Content-Type':'application/json'})
            response=connection.getresponse()
            require(response.status==200,'Native monitoring endpoint unavailable')
            body=response.read(1048576+1)
            require(len(body)<=1048576,'Oversized native monitoring response')
            return json.loads(body)
        finally:connection.close()
    info=native_call('get_info',{})
    require(info['chain_id']==NATIVE_CHAIN,'Wrong native monitoring network')
    head=datetime.datetime.fromisoformat(info['head_block_time'].rstrip('Z')).replace(tzinfo=datetime.timezone.utc)
    require(abs(time.time()-head.timestamp())<120,'Native chain head is stale')
    account=native_call('get_account',{'account_name':'vex.evm'})
    block=rpc.call('eth_blockNumber',[])
    functions=['totalProofs','emissionIndex','allocatedSupply','fundedSupply','paidSupply','admissionPaused','claimsPaused']
    calls=[('eth_call',[{'to':manifest['ledger'],'data':selector(name+'()')},block]) for name in functions]
    values=rpc.batch(calls)
    accounting={name:words(value,1)[0] for name,value in zip(functions,values)}
    require(accounting['allocatedSupply']>=accounting['fundedSupply']>=accounting['paidSupply'],
            'Reward accounting ordering failed')
    balance=words(rpc.call('eth_call',[{'to':manifest['token'],
        'data':selector('balanceOf(address)')+manifest['ledger'][2:].lower().zfill(64)},block]),1)[0]
    require(balance>=accounting['fundedSupply']-accounting['paidSupply'],'Funded reward backing is insufficient')
    for role in ['ledger','engine','beacon']:
        implementation='0x'+rpc.call('eth_getStorageAt',[manifest[role],IMPLEMENTATION_SLOT,block])[-40:]
        require(implementation.lower()==manifest['implementations'][role].lower(),'Unexpected '+role+' implementation')
    for signature,expected in [('owner()',manifest['owner']),('issuer()',manifest['ledger'])]:
        result=rpc.call('eth_call',[{'to':manifest['token'],'data':selector(signature)},block])
        require('0x'+result[-40:].lower()==expected.lower(),'Token authority changed')
    history_path=args.state/'capacity-history.json'
    history=json.loads(history_path.read_text()) if history_path.exists() else []
    now=int(time.time())
    record={'timestamp':now,'ramUsage':account['ram_usage'],'ramQuota':account['ram_quota'],
            'totalProofs':accounting['totalProofs'],'emissionIndex':accounting['emissionIndex']}
    history=[value for value in history if now-86400<=value['timestamp']<now-30][-1439:]+[record]
    free=record['ramQuota']-record['ramUsage']
    require(free>=0,'Native RAM usage exceeds quota')
    elapsed=now-history[0]['timestamp']
    growth=max(0,record['ramUsage']-history[0]['ramUsage'])/max(elapsed,1)
    remaining=free/growth if growth and elapsed>=600 else None
    alerts=[]
    if free<65536:alerts.append('Native RAM has less than 64 KiB of transaction headroom')
    if remaining is not None and remaining<7*86400:alerts.append('Native RAM has less than seven days at the measured growth rate')
    critical=free<16384 or (remaining is not None and remaining<86400)
    if critical:alerts.append('Native capacity requires immediate attention')
    if info['head_block_num']-info['last_irreversible_block_num']>600:alerts.append('Native finality is lagging')
    paused=bool(accounting['admissionPaused'] or accounting['claimsPaused'])
    output={'schema':'zoru-mainnet-health-1','status':'CRITICAL' if critical else ('WARNING' if alerts else ('MAINTENANCE' if paused else 'HEALTHY')),
        'timestamp':now,'chainId':6736,'evmBlock':int(block,16),'nativeHead':info['head_block_num'],
        'nativeIrreversible':info['last_irreversible_block_num'],'ramUsage':record['ramUsage'],
        'ramQuota':record['ramQuota'],'ramFree':free,'measuredRamBytesPerSecond':growth,
        'estimatedRamDaysRemaining':remaining/86400 if remaining is not None else None,
        'accounting':accounting,'ledgerBalance':balance,'protocolPaused':paused,'alerts':alerts,'transactionsSent':0}
    atomic_json(history_path,history)
    atomic_json(args.state/'health.json',output)
    return output


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['manifest','state']:parser.add_argument('--'+name,type=Path,required=True)
    for name in ['rpc','native']:parser.add_argument('--'+name,required=True)
    args=parser.parse_args()
    args.state.mkdir(mode=0o700,parents=True,exist_ok=True)
    try:
        output=sample(args)
    except (ValueError,OSError,KeyError) as error:
        output={'schema':'zoru-mainnet-health-1','status':'ERROR','timestamp':int(time.time()),
                'error':str(error)[:240],'transactionsSent':0}
        atomic_json(args.state/'health.json',output)
        print(json.dumps(output),flush=True)
        raise SystemExit(1) from None
    print(json.dumps(output),flush=True)


if __name__=='__main__':main()

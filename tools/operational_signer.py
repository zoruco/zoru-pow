#!/usr/bin/env python3
"""Sign only permissionless proof-migration calls with an existing protected wallet.

The encrypted wallet and its password remain on the signing host. This program
does not broadcast, transfer value, change ownership or authorize upgrades.
"""
import argparse
import contextlib
import fcntl
import hashlib
import http.client
import json
import os
import re
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

from proof_inventory import Rpc, require, selector, words
from release_transaction import IMPLEMENTATION_SLOT, NATIVE_CHAIN, atomic_json, load_mainnet_manifest


def unsigned(value):
    require(type(value) is int or (type(value) is str and re.fullmatch(r'(?:0x[0-9a-fA-F]+|[0-9]+)',value)),
            'Exact unsigned transaction quantities are required')
    result=int(value,16) if isinstance(value,str) and value.startswith('0x') else int(value)
    require(0<=result<2**256,'Transaction quantity exceeds uint256')
    return result


def private_file(path):
    metadata=path.lstat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid==os.getuid() and metadata.st_mode & 0o077==0,
            'Existing signing credentials must remain private regular files owned by the signing user')
    require(metadata.st_size<=1048576,'Signing credential exceeds size bound')


@contextlib.contextmanager
def compatible_wallet(path):
    """Keep existing encrypted bytes private while accepting standard V3 casing.

    Foundry expects a lowercase crypto member. The existing wallet is never
    changed; only its still-encrypted JSON is normalized inside PrivateTmp.
    No private key is decoded or written by this program.
    """
    encrypted=json.loads(path.read_text())
    require(not ('Crypto' in encrypted and 'crypto' in encrypted),'Ambiguous encrypted wallet fields')
    if 'Crypto' not in encrypted:
        yield path
        return
    encrypted['crypto']=encrypted.pop('Crypto')
    with tempfile.TemporaryDirectory(prefix='zoru-encrypted-') as directory:
        temporary=Path(directory)/'wallet.json'
        atomic_json(temporary,encrypted)
        yield temporary


def run(args):
    transaction=json.load(sys.stdin)
    require(set(transaction)=={'from','to','chainId','nonce','value','data','type','gasPrice','gasLimit'},'Unexpected transaction fields')
    manifest=load_mainnet_manifest(args.manifest)
    account=args.account.lower()
    require(manifest['chainId']==6736 and manifest['mode']=='mainnet' and unsigned(transaction['chainId'])==6736,
            'Operational signing requires the declared mainnet chain')
    require(transaction['from'].lower()==account and transaction['to'].lower()==manifest['ledger'].lower(),
            'Operational signing is restricted to the existing Ledger proxy')
    require(unsigned(transaction['value'])==0 and unsigned(transaction['type'])==0,'Only zero-value legacy migration calls may be signed')
    gas,price=unsigned(transaction['gasLimit']),unsigned(transaction['gasPrice'])
    require(21000<=gas<=3_000_000 and 0<price<=300_000_000_000 and gas*price<=500_000_000_000_000_000,
            'Operational transaction exceeds bounded migration fees')
    functions={selector(signature):signature for signature in ['copyLegacyProofs(bytes32[])','clearLegacyProofs(bytes32[])']}
    data=bytes.fromhex(transaction['data'].removeprefix('0x'))
    prefix='0x'+data[:4].hex()
    require(prefix in functions and len(data)>=100,'Unexpected operational function')
    require(int.from_bytes(data[4:36],'big')==32,'Noncanonical proof batch offset')
    count=int.from_bytes(data[36:68],'big')
    require(1<=count<=64 and len(data)==68+count*32,'Proof migration batch is not bounded and canonical')
    digests=['0x'+data[68+i*32:100+i*32].hex() for i in range(count)]
    batch='['+','.join(digests)+']'
    encoded=subprocess.check_output([args.cast,'calldata',functions[prefix],batch],text=True).strip()
    require(encoded.lower()==transaction['data'].lower(),'Reviewed migration calldata changed')
    rpc=Rpc(args.rpc)
    require(int(rpc.call('eth_chainId',[]),16)==6736,'Wrong EVM signing network')
    require('anvil' not in str(rpc.call('web3_clientVersion',[])).lower(),'Production signing refuses a fork')
    native=Rpc(args.native).url
    connection=(http.client.HTTPSConnection if native.scheme=='https' else http.client.HTTPConnection)(native.hostname,native.port,timeout=15)
    try:
        connection.request('POST',native.path.rstrip('/')+'/v1/chain/get_info','{}',{'Content-Type':'application/json'})
        response=connection.getresponse()
        require(response.status==200 and json.loads(response.read(1048576))['chain_id']==NATIVE_CHAIN,'Wrong native signing network')
    finally:connection.close()
    for signature in ['admissionPaused()','claimsPaused()']:
        require(words(rpc.call('eth_call',[{'to':manifest['ledger'],'data':selector(signature)},'latest']),1)[0]==1,
                'Both protocol maintenance pauses are required')
    implementation='0x'+rpc.call('eth_getStorageAt',[manifest['ledger'],IMPLEMENTATION_SLOT,'latest'])[-40:]
    actual=rpc.call('eth_getCode',[implementation,'latest'])
    expected=json.loads(args.implementation_artifact.read_text())['deployedBytecode']['object']
    require(actual==expected,'The reviewed migration implementation is not active')
    root=args.journal_root
    lock_file=root/'signers'/(account+'.lock')
    lock_file.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    descriptor=os.open(lock_file,os.O_CREAT|os.O_RDWR,0o600)
    try:
        fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
        nonce=int(rpc.call('eth_getTransactionCount',[account,'latest']),16)
        require(nonce==unsigned(transaction['nonce']) and nonce==int(rpc.call('eth_getTransactionCount',[account,'pending']),16),
                'Operational nonce is pending or changed')
        retained=root/'signers'/'mainnet'/account/'private-journal'
        require(not list(retained.glob('*.json')),
                'Retained miner transaction must be reconciled before operational signing')
        private_file(args.keystore)
        private_file(args.password_file)
        identity_hash=hashlib.sha256(args.keystore.read_bytes()).hexdigest()
        if args.identity_cache.exists():private_file(args.identity_cache)
        identity=json.loads(args.identity_cache.read_text()) if args.identity_cache.exists() else {}
        with compatible_wallet(args.keystore) as signing_wallet:
            if identity.get('encryptedWalletSha256')!=identity_hash:
                address=subprocess.check_output([args.cast,'wallet','address','--keystore',str(signing_wallet),
                    '--password-file',str(args.password_file)],text=True).strip().lower()
                require(address==account,'Existing operational wallet identity differs')
                identity={'encryptedWalletSha256':identity_hash,'account':address}
                atomic_json(args.identity_cache,identity)
            require(identity.get('account',account)==account,'Operational identity cache differs')
            command=[args.cast,'mktx','--legacy','--chain','6736','--rpc-url',args.rpc,'--from',account,
                '--nonce',str(nonce),'--value','0','--gas-limit',str(gas),'--gas-price',str(price),
                '--keystore',str(signing_wallet),'--password-file',str(args.password_file),
                manifest['ledger'],functions[prefix],batch]
            signed=subprocess.run(command,capture_output=True,text=True,timeout=60)
        require(signed.returncode==0,'Protected operational signer declined the exact migration transaction')
        raw=signed.stdout.strip()
        require(raw.startswith('0x') and len(raw)>66,'Unexpected signed transaction format')
        fingerprint=subprocess.check_output([args.cast,'keccak'],input=raw,text=True).strip()
        print(json.dumps({'from':account,'chainId':'6736','hash':fingerprint,'serializedTransaction':raw,'broadcast':False}))
    finally:os.close(descriptor)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['manifest','keystore','password-file','journal-root','identity-cache','implementation-artifact']:
        parser.add_argument('--'+name,type=Path,required=True)
    for name in ['account','rpc','native']:
        parser.add_argument('--'+name,required=True)
    parser.add_argument('--cast',default='cast')
    run(parser.parse_args())


if __name__=='__main__':main()

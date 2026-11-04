#!/usr/bin/env python3
"""Bounded storage experiment on an explicit isolated VEX testnet (never mainnet)."""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import time

NATIVE_TESTNET = 'c6b5914584c79ad99944f4f77fe813fa2e41373058dadc7c19211e03c886a2fa'


def require(value, message):
    if not value:
        raise ValueError(message)


class Experiment:
    def __init__(self, args):
        self.a = args
        self.result = {'schema': 'zoru-native-ram-probe-1', 'chainId': 46736, 'mainnetTouched': False,
                       'creationBytecodeSha256': hashlib.sha256(bytes.fromhex(args.bytecode.read_text().strip().removeprefix('0x'))).hexdigest(),
                       'operations': []}

    def http(self, port, path, data):
        c = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
        try:
            c.request('POST', path, json.dumps(data), {'Content-Type': 'application/json'})
            r = c.getresponse()
            require(r.status == 200, 'Local RPC failed')
            return json.loads(r.read())
        finally:
            c.close()

    def rpc(self, method, params):
        d = self.http(self.a.rpc_port, '/', {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
        require('error' not in d, 'Test RPC rejected '+method)
        return d['result']

    def native(self, method, data):
        return self.http(self.a.native_port, '/v1/chain/'+method, data)

    def verify(self):
        require(int(self.rpc('eth_chainId', []), 16) == 46736, 'Wrong EVM chain; refusing experiment')
        require(self.native('get_info', {})['chain_id'] == NATIVE_TESTNET, 'Wrong native chain; refusing experiment')

    def ram(self):
        d = self.native('get_account', {'account_name': 'vex.evm'})
        return {'ramUsage': d['ram_usage'], 'ramQuota': d['ram_quota'],
                'headBlock': self.native('get_info', {})['head_block_num']}

    def save(self):
        self.a.output.write_text(json.dumps(self.result, indent=2)+'\n')

    def send(self, label, call, expected=1, gas_limit=2_000_000):
        self.verify()
        nonce = self.rpc('eth_getTransactionCount', [self.a.account, 'latest'])
        require(nonce == self.rpc('eth_getTransactionCount', [self.a.account, 'pending']), 'Unreconciled pending transaction')
        price = int(self.rpc('eth_gasPrice', []), 16)
        require(price <= 300_000_000_000, 'Test gas quote exceeds experiment bound')
        before = self.ram()
        require(before['ramQuota']-before['ramUsage'] > 2_000_000, 'Insufficient isolated RAM headroom')
        require(0 < gas_limit <= 22_000_000, 'Unbounded test gas limit')
        require(int(self.rpc('eth_getBalance', [self.a.account, 'latest']), 16) >= gas_limit*price, 'Insufficient existing test gas reserve')
        args = [self.a.cast, 'mktx', '--legacy', '--rpc-url', f'http://127.0.0.1:{self.a.rpc_port}',
                '--chain', '46736', '--from', self.a.account, '--value', '0',
                '--keystore', str(self.a.keystore), '--password-file', str(self.a.password_file), '--nonce', str(int(nonce,16)),
                '--gas-limit', str(gas_limit), '--gas-price', str(price)] + call
        run = subprocess.run(args, capture_output=True, text=True, timeout=40)
        require(run.returncode == 0, 'Test signing failed: '+run.stderr[-400:])
        raw = run.stdout.strip()
        require(raw.startswith('0x') and len(raw) > 66, 'Unexpected signed transaction')
        tx = subprocess.check_output([self.a.cast, 'keccak'], input=raw, text=True).strip()
        journal = self.a.output.parent/(self.a.output.stem+'-transactions')
        journal.mkdir(mode=0o700, exist_ok=True)
        signed_path = journal/(tx+'.raw')
        signed_path.write_text(raw+'\n')
        signed_path.chmod(0o600)
        record = {'label': label, 'transactionHash': tx, 'nonce': int(nonce,16), 'before': before,
                  'expectedReceiptStatus': expected, 'signedTransactionFile': str(signed_path), 'state': 'prepared'}
        self.result['operations'].append(record)
        self.save()
        response = self.http(self.a.rpc_port, '/', {'jsonrpc':'2.0','id':1,'method':'eth_sendRawTransaction','params':[raw]})
        if 'error' in response:
            record.update(state='broadcast-rejected-or-unknown', broadcastError=response['error'])
            self.save()
            raise RuntimeError('Broadcast requires reconciliation for '+tx+': '+str(response['error'])[:400])
        require(response.get('result','').lower() == tx.lower(), 'Broadcast hash mismatch; retain signed journal')
        record['state'] = 'broadcast'
        self.save()
        deadline = time.monotonic()+90
        while time.monotonic() < deadline:
            receipt = self.rpc('eth_getTransactionReceipt', [tx])
            if receipt is not None:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError('Receipt unavailable; retain evidence and reconcile transaction '+tx)
        block = self.rpc('eth_getBlockByNumber', [receipt['blockNumber'], False])
        require(block['hash'] == receipt['blockHash'] and tx in block['transactions'], 'Noncanonical receipt')
        require(int(receipt['status'], 16) == expected, 'Unexpected receipt status')
        after = self.ram()
        record.update(state='confirmed', receipt=receipt, after=after, ramDelta=after['ramUsage']-before['ramUsage'])
        self.save()
        print(json.dumps({'operation': label, 'hash': tx, 'gasUsed': int(receipt['gasUsed'],16), 'ramDelta': record['ramDelta']}), flush=True)
        return receipt

    def run(self):
        require(not self.a.output.exists(), 'Output exists; reconcile the recorded run instead of deploying again')
        self.verify()
        public = subprocess.check_output([self.a.cast, 'wallet', 'address', '--keystore', str(self.a.keystore),
                                           '--password-file', str(self.a.password_file)], text=True).strip()
        require(public.lower() == self.a.account.lower(), 'Signer address mismatch')
        self.result['nativeCodeHash'] = self.native('get_code_hash', {'account_name': 'vex.evm'})['code_hash']
        receipt = self.send('deployment', ['--create', self.a.bytecode.read_text().strip()])
        address = receipt['contractAddress']
        self.result['contract'] = address
        for label, call in [('log-only', ['ping(uint256)', '1']), ('write-one', ['write(uint256,uint256)', '100', '1']),
                            ('overwrite-one', ['write(uint256,uint256)', '100', '1']), ('write-three', ['write(uint256,uint256)', '200', '3']),
                            ('clear-one', ['clear(uint256,uint256)', '100', '1']), ('reuse-one', ['write(uint256,uint256)', '100', '1']),
                            ('clear-three', ['clear(uint256,uint256)', '200', '3']), ('clear-reused', ['clear(uint256,uint256)', '100', '1'])]:
            self.send(label, [address]+call)
        self.send('failed-evm-call', [address, 'fail()'], expected=0)
        self.result['status'] = 'COMPLETED_ISOLATED_STORAGE_EXPERIMENT'
        self.result['scope'] = 'Synthetic storage probe; protocol proof/epoch/beacon measurements are separate acceptance requirements'
        self.save()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cast', required=True)
    p.add_argument('--rpc-port', type=int, default=18547)
    p.add_argument('--native-port', type=int, default=19888)
    p.add_argument('--account', required=True)
    p.add_argument('--keystore', type=Path, required=True)
    p.add_argument('--password-file', type=Path, required=True)
    p.add_argument('--bytecode', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    Experiment(p.parse_args()).run()


if __name__ == '__main__':
    main()

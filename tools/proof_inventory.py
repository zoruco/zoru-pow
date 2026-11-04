#!/usr/bin/env python3
"""Read-only, block-pinned historical proof and entitlement reconciliation.

This program never signs, sends transactions, edits a manifest or deletes storage.
A fresh inventory must be made after admission and claims are paused for migration.
"""
import argparse
from collections import defaultdict
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import time
from functools import cache
from urllib.parse import urlsplit


def require(condition, message):
    if not condition:
        raise ValueError(message)


@cache
def keccak(value):
    return subprocess.check_output(['cast', 'keccak', value], text=True).strip()


def selector(signature):
    return keccak(signature)[:10]


def inventory_fingerprint(value):
    # JSON object keys are strings. Normalize before sorting so integer epoch
    # keys have the same fingerprint after the inventory is written and read.
    normalized = json.loads(json.dumps({k:v for k,v in value.items() if k != 'inventorySha256'}))
    return hashlib.sha256(json.dumps(normalized,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def mapping_slots(values):
    result = json.loads(subprocess.check_output(['node', str(Path(__file__).with_name('storage_slots.mjs'))],
                        input=json.dumps(values), text=True))
    require(len(result) == len(values), 'Mapping slot derivation is incomplete')
    if values:
        for index in {0, len(values)-1}:
            value = values[index]
            expected = keccak(value['key']+f"{value['slot']:064x}")
            require(result[index] == expected, 'Mapping slot derivation disagrees with cast')
    return result


def words(value, count):
    require(isinstance(value, str) and value.startswith('0x') and len(value) == 2 + 64 * count,
            'Unexpected ABI response length')
    return [int(value[2+i*64:2+(i+1)*64], 16) for i in range(count)]


class Rpc:
    def __init__(self, url):
        self.url = urlsplit(url)
        require(self.url.scheme == 'https' or (self.url.scheme == 'http' and self.url.hostname in ['127.0.0.1', 'localhost', '::1']),
                'Use HTTPS or a loopback RPC')
        require(not self.url.username and not self.url.password and not self.url.query and not self.url.fragment,
                'Credential-bearing RPC URLs are unsupported')
        self.requests = 0
        self.last_request = 0.0

    def batch(self, calls):
        require(0 < len(calls) <= 32, 'Batch size must be between 1 and 32')
        time.sleep(max(0.0, len(calls)/200 - (time.monotonic()-self.last_request)))
        self.last_request = time.monotonic()
        conn = (http.client.HTTPSConnection if self.url.scheme == 'https' else http.client.HTTPConnection)(
            self.url.hostname, self.url.port, timeout=30)
        payload = [{'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params} for i, (method, params) in enumerate(calls)]
        self.requests += len(calls)
        try:
            # VEX requires conventional Content-Type header casing.
            conn.request('POST', self.url.path or '/', json.dumps(payload), {'Content-Type': 'application/json'})
            response = conn.getresponse()
            raw = response.read(32 * 1024 * 1024 + 1)
            require(response.status == 200 and len(raw) <= 32 * 1024 * 1024, 'RPC HTTP failure or oversized response')
            data = json.loads(raw)
        finally:
            conn.close()
        require(isinstance(data, list) and len(data) == len(calls), 'Incomplete RPC batch')
        indexed = {}
        for item in data:
            require(item.get('jsonrpc') == '2.0' and type(item.get('id')) is int and item['id'] not in indexed,
                    'Invalid or duplicate RPC response ID')
            require('error' not in item and 'result' in item, 'RPC method failed; inventory is incomplete')
            indexed[item['id']] = item['result']
        require(set(indexed) == set(range(len(calls))), 'Mismatched RPC batch IDs')
        return [indexed[i] for i in range(len(calls))]

    def call(self, method, params):
        return self.batch([(method, params)])[0]


def validate_records(records, epochs, accounting):
    require(len(records) == accounting['totalProofs'], 'ProofAccepted inventory does not match totalProofs')
    require(sum(state['proofCount'] for state in epochs.values()) == len(records),
            'Epoch proof counts do not reconcile with the complete inventory')
    by_epoch = defaultdict(list)
    paid = 0
    for record in records:
        require(record['beneficiary'] != '0x' + '0' * 40, 'Zero proof beneficiary')
        require(record['claimed'] == (record['claimAmount'] is not None), 'Claim state and RewardClaimed history disagree')
        by_epoch[record['epoch']].append(record['indexPlusOne'])
        state = epochs[record['epoch']]
        i, n, budget = record['indexPlusOne'] - 1, state['proofCount'], state['budget']
        require(n > 0 and 0 <= i < n and record['indexPlusOne'] <= 2**32-1, 'Proof index is not losslessly compactable')
        amount = budget * (i+1) // n - budget * i // n
        record['entitlement'] = amount
        if record['claimed']:
            require(state['sealed'] and record['claimAmount'] == amount, 'Incorrect historical reward')
            paid += amount
    for epoch, indices in by_epoch.items():
        require(sorted(indices) == list(range(1, epochs[epoch]['proofCount']+1)), 'Missing or repeated epoch proof index')
    require(sum(s['budget'] for s in epochs.values()) == accounting['allocatedSupply'], 'Allocated supply does not reconcile')
    require(sum(s['budget'] for s in epochs.values() if s['sealed']) == accounting['fundedSupply'], 'Funded supply does not reconcile')
    require(paid == accounting['paidSupply'], 'Paid supply does not reconcile')
    require(accounting['paidSupply'] <= accounting['fundedSupply'] <= accounting['allocatedSupply'], 'Invalid reward liabilities')
    require(accounting['ledgerBalance'] >= accounting['fundedSupply']-accounting['paidSupply'], 'Insolvent funded liability')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rpc', required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--block', type=lambda x: int(x, 0))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--chunk', type=int, default=2048)
    parser.add_argument('--require-paused', action='store_true')
    args = parser.parse_args()
    require(1 <= args.chunk <= 4096, 'Unbounded log range')
    manifest = json.loads(args.manifest.read_text())
    rpc = Rpc(args.rpc)
    require(int(rpc.call('eth_chainId', []), 16) == manifest['chainId'], 'Wrong EVM chain')
    head = int(rpc.call('eth_blockNumber', []), 16)
    height = args.block if args.block is not None else head-3
    require(height >= int(str(manifest['deploymentBlockNumber']), 0) and height <= head-2, 'Use a confirmed post-deployment block')
    block = hex(height)
    header = rpc.call('eth_getBlockByNumber', [block, False])
    ledger = manifest['ledger'].lower()
    paused = [words(rpc.call('eth_call',[{'to':ledger,'data':selector(signature)},block]),1)[0]
              for signature in ['admissionPaused()','claimsPaused()']]
    if args.require_paused:
        require(paused == [1,1], 'The requested snapshot is not under both contract maintenance pauses')
    topic = keccak('ProofAccepted(uint48,bytes32,address,uint256,uint256)')
    claim_topic = keccak('RewardClaimed(uint48,bytes32,address,uint256)')
    opened_topic = keccak('EpochOpened(uint48,uint256,address,address,uint256)')
    beacon_topic = keccak('BeaconPublished(uint48,uint64,bytes32)')
    transfer_topic = keccak('Transfer(address,address,uint256)')
    start = int(str(manifest['deploymentBlockNumber']), 0)
    logs = []
    for low in range(start, height+1, args.chunk):
        logs.extend(rpc.call('eth_getLogs', [{'address': [ledger, manifest['beacon'], manifest['token']],
                                               'fromBlock': hex(low), 'toBlock': hex(min(low+args.chunk-1, height)),
                                               'topics': [[topic, claim_topic, opened_topic, beacon_topic, transfer_topic]]}]))
        time.sleep(0.02)
    logs.sort(key=lambda l: (int(l['blockNumber'], 16), int(l['transactionIndex'], 16), int(l['logIndex'], 16)))
    records, claims, positions, opened_epochs = {}, {}, set(), set()
    beacon_publications, token_accounts = defaultdict(list), {ledger}
    for log in logs:
        require(not log.get('removed'), 'Invalid historical log')
        require(start <= int(log['blockNumber'], 16) <= height, 'Log outside requested snapshot')
        position = (log['blockHash'], log['logIndex'])
        require(position not in positions, 'Repeated log in RPC response')
        positions.add(position)
        if log['topics'][0] == beacon_topic:
            require(log['address'].lower() == manifest['beacon'].lower() and len(log['topics']) == 3,
                    'Malformed beacon publication')
            epoch = int(log['topics'][1],16)
            randomness = words(log['data'],1)[0]
            require(randomness != 0, 'Zero authenticated randomness')
            beacon_publications[epoch].append({'round':int(log['topics'][2],16),'randomness':f'0x{randomness:064x}',
                                               'transactionHash':log['transactionHash']})
            continue
        if log['topics'][0] == transfer_topic:
            require(log['address'].lower() == manifest['token'].lower() and len(log['topics']) == 3,
                    'Malformed token transfer')
            words(log['data'],1)
            for account_topic in log['topics'][1:]:
                require(int(account_topic,16) < 2**160, 'Noncanonical transfer address')
                account = '0x'+account_topic[-40:].lower()
                if int(account,16) != 0: token_accounts.add(account)
            continue
        require(log['address'].lower() == ledger, 'Unexpected contract emitted a ledger event')
        if log['topics'][0] == opened_topic:
            require(len(log['topics']) == 2, 'Malformed EpochOpened event')
            epoch = int(log['topics'][1], 16)
            require(epoch not in opened_epochs, 'Repeated epoch initialization event')
            opened_epochs.add(epoch)
            words(log['data'], 4)
            continue
        require(len(log['topics']) == 4, 'Malformed proof or claim event')
        epoch, digest, owner = int(log['topics'][1], 16), log['topics'][2].lower(), '0x'+log['topics'][3][-40:].lower()
        if log['topics'][0] == topic:
            require(digest not in records, 'Duplicate proof identifier in event inventory')
            index, generation = words(log['data'], 2)
            records[digest] = {'digest': digest, 'epoch': epoch, 'beneficiary': owner, 'indexPlusOne': index+1,
                               'generation': generation, 'acceptanceTx': log['transactionHash'], 'claimAmount': None}
        else:
            require(digest not in claims, 'Repeated RewardClaimed event')
            claims[digest] = (epoch, owner, words(log['data'], 1)[0], log['transactionHash'])
    require(set(claims) <= set(records), 'Claim event without accepted proof')
    record_list = list(records.values())
    lookup = selector('proofs(bytes32)')
    for low in range(0, len(record_list), 32):
        part = record_list[low:low+32]
        responses = rpc.batch([('eth_call', [{'to': ledger, 'data': lookup+r['digest'][2:]}, block]) for r in part])
        for record, response in zip(part, responses):
            owner, epoch, index, claimed = words(response, 4)
            require(owner < 2**160 and claimed in [0, 1], 'Noncanonical proof lookup')
            require((f'0x{owner:040x}', epoch, index) == (record['beneficiary'], record['epoch'], record['indexPlusOne']),
                    'Historical ownership, epoch or index does not match event')
            record['claimed'] = bool(claimed)
            record['raw'] = response
            if record['digest'] in claims:
                ce, co, amount, tx = claims[record['digest']]
                require((ce, co) == (epoch, record['beneficiary']), 'Claim ownership mismatch')
                record.update(claimAmount=amount, claimTx=tx)
        if low % 1024 == 0:
            print(f'verified {min(low+32,len(record_list))}/{len(record_list)} proofs at {block}', flush=True)
    epochs = {}
    require({r['epoch'] for r in record_list} <= opened_epochs, 'Proof without an epoch initialization event')
    epoch_ids = sorted(opened_epochs)
    for low in range(0, len(epoch_ids), 32):
        part = epoch_ids[low:low+32]
        responses = rpc.batch([('eth_call', [{'to': ledger, 'data': selector('epochInfo(uint48)')+f'{e:064x}'}, block]) for e in part])
        for epoch, response in zip(part, responses):
            data = words(response, 10)
            require(data[6] in [0, 1] and data[0] != 0, 'Invalid epoch state')
            require(data[2] <= 2**64-1 and data[3] <= 2**32-1 and data[8] <= 2**64-1 and data[9] <= 2**64-1,
                    'Epoch metadata is not losslessly compactable')
            require(f'0x{data[5]:040x}' == manifest['engine'].lower()
                    and f'0x{data[7]:040x}' == manifest['beacon'].lower(), 'Historical epoch module addresses changed')
            require(data[4] == min(2**256-1, data[3]*((2**256-1)//data[0])),
                    'Historical epoch work estimate cannot be derived losslessly')
            require(data[9] == int(manifest['launchTime'])+(epoch+1)*60,
                    'Historical epoch close time differs from protocol schedule')
            epochs[epoch] = {'budget': data[2], 'proofCount': data[3], 'sealed': bool(data[6]), 'raw': response}
    accounting = {}
    for field in ['totalProofs', 'allocatedSupply', 'fundedSupply', 'paidSupply', 'emissionIndex']:
        accounting[field] = words(rpc.call('eth_call', [{'to': ledger, 'data': selector(field+'()')}, block]), 1)[0]
    accounting['ledgerBalance'] = words(rpc.call('eth_call', [{'to': manifest['token'], 'data': selector('balanceOf(address)')+ledger[2:].zfill(64)}, block]), 1)[0]
    validate_records(record_list, epochs, accounting)
    proof_slots = mapping_slots([{'key':r['digest'],'slot':slot} for r in record_list for slot in [13,16]])
    for i, record in enumerate(record_list):
        record['legacyStorageSlot'], record['canonicalStorageSlot'] = proof_slots[2*i:2*i+2]
        packed = int(record['beneficiary'],16) | record['epoch'] << 160 | record['indexPlusOne'] << 208 | int(record['claimed']) << 240
        record['canonicalStorageValue'] = f'0x{packed:064x}'
    epoch_slots = mapping_slots([{'key':f'0x{epoch:064x}','slot':slot} for epoch in epoch_ids for slot in [12,21]])
    for i, epoch in enumerate(epoch_ids):
        epochs[epoch]['legacyStorageSlot'], epochs[epoch]['canonicalStorageSlot'] = epoch_slots[2*i:2*i+2]
        state = words(epochs[epoch]['raw'],10)
        packed = state[2] | state[3] << 64 | state[8] << 96 | state[9] << 160 | state[6] << 224
        epochs[epoch]['canonicalStorageValues'] = [f'0x{v:064x}' for v in [state[0],state[1],packed]]
    beacon_ids = sorted(beacon_publications)
    cache_slots = mapping_slots([{'key':f'0x{epoch:064x}','slot':slot} for epoch in beacon_ids for slot in [0,3]])
    caches = {}
    for low in range(0,len(beacon_ids),16):
        part = beacon_ids[low:low+16]
        responses = rpc.batch([('eth_getStorageAt',[manifest['beacon'],cache_slots[2*(low+i)+j],block])
                               for i in range(len(part)) for j in [0,1]])
        for i, epoch in enumerate(part):
            seed, config = responses[2*i:2*i+2]
            if int(seed,16):
                require(seed in [p['randomness'] for p in beacon_publications[epoch]], 'Beacon cache lacks a publication record')
            caches[epoch] = {'seed':seed,'config':config,'storageSlots':cache_slots[2*(low+i):2*(low+i)+2],
                             'publications':beacon_publications[epoch]}
    balances = {}
    accounts = sorted(token_accounts)
    for low in range(0,len(accounts),32):
        part = accounts[low:low+32]
        responses = rpc.batch([('eth_call',[{'to':manifest['token'],'data':selector('balanceOf(address)')+a[2:].zfill(64)},block]) for a in part])
        balances.update({account:words(response,1)[0] for account,response in zip(part,responses)})
    total_supply = words(rpc.call('eth_call',[{'to':manifest['token'],'data':selector('totalSupply()')},block]),1)[0]
    lifetime_minted = words(rpc.call('eth_call',[{'to':manifest['token'],'data':selector('lifetimeMinted()')},block]),1)[0]
    require(sum(balances.values()) == total_supply == lifetime_minted, 'Complete token balance inventory does not reconcile')
    require(rpc.call('eth_getBlockByNumber', [block, False])['hash'] == header['hash'], 'Snapshot block reorganized')
    require(int(rpc.call('eth_chainId', []), 16) == manifest['chainId'], 'Chain identity changed during inventory')
    if args.require_paused:
        require(all(words(rpc.call('eth_call',[{'to':ledger,'data':selector(signature)},'latest']),1)[0] == 1
                    for signature in ['admissionPaused()','claimsPaused()']), 'Maintenance pause changed during inventory')
    result = {'schema': 'zoru-proof-inventory-1', 'status': 'VERIFIED_SNAPSHOT_ONLY', 'chainId': manifest['chainId'],
              'ledger': ledger, 'blockNumber': height, 'blockHash': header['hash'], 'accounting': accounting,
              'proofs': record_list, 'epochs': epochs, 'beaconCaches':caches,
              'tokenBalances':balances,'totalSupply':total_supply,'lifetimeMinted':lifetime_minted,'rpcCalls': rpc.requests,
              'maintenancePaused':paused == [1,1],
              'requiresFreshPausedInventoryBeforeMigration': not (args.require_paused and paused == [1,1])}
    result['inventorySha256'] = inventory_fingerprint(result)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ['proofs','epochs','beaconCaches','tokenBalances']}, indent=2))


if __name__ == '__main__':
    main()

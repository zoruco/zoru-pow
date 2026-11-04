#!/usr/bin/env python3
"""Verified, bounded migration shared by fork rehearsal and production execution."""
import json
from pathlib import Path
import subprocess

from proof_inventory import inventory_fingerprint, require, selector, words
from release_transaction import atomic_json


def offset(slot, index):
    return f'0x{(int(slot,16)+index) % 2**256:064x}'


class ProofMigration:
    def __init__(self, transactions, inventory, progress, cast='cast', batch_size=16, proof_transactions=None):
        self.t = transactions
        self.rpc = transactions.rpc
        self.inventory = json.loads(Path(inventory).read_text())
        self.progress = Path(progress)
        self.cast = cast
        require(1<=batch_size<=64,'Migration batch exceeds the contract bound')
        self.batch_size=batch_size
        self.proof_transactions=proof_transactions or transactions
        self.ledger = transactions.manifest['ledger']
        require(self.inventory['chainId'] == 6736 and self.inventory['ledger'] == self.ledger.lower(),
                'Historical inventory is for a different protocol')
        self.proofs = self.inventory['proofs']
        self.epochs = self.inventory['epochs']
        claimed_hash = self.inventory['inventorySha256']
        require(inventory_fingerprint(self.inventory) == claimed_hash,
                'Historical inventory fingerprint mismatch')
        self.inventory_hash = '0x'+claimed_hash
        self.result = {'schema':'zoru-migration-progress-1','inventorySha256':claimed_hash,'completedProofs':0,
                       'completedEpochs':0,'batchSize':batch_size,'batches':[],'status':'IN_PROGRESS'}
        if self.progress.exists():
            previous = json.loads(self.progress.read_text())
            require(previous['inventorySha256'] == claimed_hash, 'Retained migration inventory differs')
            require(previous.get('batchSize',16)==batch_size,'Retained migration batch boundaries differ')

    def data(self, signature, *values):
        return subprocess.check_output([self.cast,'calldata',signature,*map(str,values)],text=True).strip()

    def send(self, label, signature, *values):
        signer = self.proof_transactions if signature in ['copyLegacyProofs(bytes32[])','clearLegacyProofs(bytes32[])'] else self.t
        if signature=='copyLegacyEpochs(uint48[])':
            # Native execution charges differ from the read node's estimator.
            # Bound the 32-epoch write using measured native storage costs.
            return signer.send(label,self.ledger,self.data(signature,*values),gas_limit=7_000_000)
        return signer.send(label,self.ledger,self.data(signature,*values))

    def reads(self, calls):
        result = []
        for low in range(0,len(calls),32):
            result.extend(self.rpc.batch(calls[low:low+32]))
        return result

    def storage(self, address, slots):
        return self.reads([('eth_getStorageAt',[address,slot,'latest']) for slot in slots])

    def accounting(self):
        source = self.inventory['accounting']
        calls = [('eth_call',[{'to':self.ledger,'data':selector(field+'()')},'latest'])
                 for field in ['totalProofs','allocatedSupply','fundedSupply','paidSupply','emissionIndex']]
        values = self.reads(calls)
        for field, raw in zip(['totalProofs','allocatedSupply','fundedSupply','paidSupply','emissionIndex'],values):
            require(words(raw,1)[0] == source[field], 'Reward accounting changed during migration: '+field)
        balance = self.rpc.call('eth_call',[{'to':self.t.manifest['token'],
            'data':selector('balanceOf(address)')+self.ledger[2:].lower().zfill(64)},'latest'])
        require(words(balance,1)[0] == source['ledgerBalance'], 'Ledger backing changed during migration')

    def proof_sources(self, batch):
        source = self.storage(self.ledger,[offset(r['legacyStorageSlot'],i) for r in batch for i in range(3)])
        destination = self.storage(self.ledger,[r['canonicalStorageSlot'] for r in batch])
        for i, record in enumerate(batch):
            actual = [int(v,16) for v in source[3*i:3*i+3]]
            expected = [int(record['beneficiary'],16) | record['epoch'] << 160,
                        record['indexPlusOne'],int(record['claimed'])]
            packed = int(record['beneficiary'],16) | record['epoch'] << 160 | record['indexPlusOne'] << 208 | int(record['claimed']) << 240
            require(int(record['canonicalStorageValue'],16) == packed, 'Invalid canonical proof encoding')
            require(actual == expected or (actual == [0,0,0] and int(destination[i],16) == packed),
                    'Historical proof source differs from verified inventory')
            require(int(destination[i],16) in [0,packed], 'Conflicting canonical proof record')

    def verify_proofs(self, batch, cleared=False):
        values = self.storage(self.ledger,[r['canonicalStorageSlot'] for r in batch])
        lookups = self.reads([('eth_call',[{'to':self.ledger,'data':selector('proofs(bytes32)')+r['digest'][2:]},'latest']) for r in batch])
        for record, value, lookup in zip(batch,values,lookups):
            require(value.lower() == record['canonicalStorageValue'].lower() and lookup.lower() == record['raw'].lower(),
                    'Canonical proof ownership or entitlement mismatch')
        if cleared:
            old = self.storage(self.ledger,[offset(r['legacyStorageSlot'],i) for r in batch for i in range(3)])
            require(all(int(v,16) == 0 for v in old), 'Historical proof source remains after verified cleanup')

    def epoch_encoding(self, record):
        data = words(record['raw'],10)
        source = [data[0],data[1],data[2],data[3],data[4],data[5] | data[6] << 160,data[7],data[8],data[9]]
        packed = data[2] | data[3] << 64 | data[8] << 96 | data[9] << 160 | data[6] << 224
        expected = [data[0],data[1],packed]
        require([int(v,16) for v in record['canonicalStorageValues']] == expected, 'Invalid canonical epoch encoding')
        return source, expected

    def verify_epochs(self, batch, phase):
        source = self.storage(self.ledger,[offset(record['legacyStorageSlot'],i) for _,record in batch for i in range(9)])
        destination = self.storage(self.ledger,[offset(record['canonicalStorageSlot'],i) for _,record in batch for i in range(3)])
        for i, (_,record) in enumerate(batch):
            old, packed = self.epoch_encoding(record)
            actual_old = [int(v,16) for v in source[9*i:9*i+9]]
            actual_new = [int(v,16) for v in destination[3*i:3*i+3]]
            if phase == 'source':
                require(actual_old == old or (actual_old == [0]*9 and actual_new == packed), 'Historical epoch source mismatch')
                require(actual_new in [[0]*3,packed], 'Conflicting canonical epoch')
            else:
                require(actual_new == packed, 'Canonical epoch metadata mismatch')
                require(actual_old == ([0]*9 if phase == 'cleared' else old) or actual_old == [0]*9,
                        'Historical epoch source changed during verification')
        if phase != 'source':
            lookups = self.reads([('eth_call',[{'to':self.ledger,'data':selector('epochInfo(uint48)')+f'{epoch:064x}'},'latest']) for epoch,_ in batch])
            require(all(value.lower() == record['raw'].lower() for (_,record),value in zip(batch,lookups)),
                    'Historical epoch ABI or derived work estimate mismatch')

    def run(self):
        for function in ['admissionPaused()','claimsPaused()']:
            require(words(self.rpc.call('eth_call',[{'to':self.ledger,'data':selector(function)},'latest']),1)[0] == 1,
                    'Contract maintenance pause is required')
        self.accounting()
        self.send('start-proof-migration','startProofMigration(bytes32,uint256)',self.inventory_hash,len(self.proofs))
        for low in range(0,len(self.proofs),self.batch_size):
            part = self.proofs[low:low+self.batch_size]
            self.proof_sources(part)
            digests = '['+','.join(r['digest'] for r in part)+']'
            copy_receipt = self.send(f'proof-copy-{low:06d}','copyLegacyProofs(bytes32[])',digests)
            self.verify_proofs(part)
            self.accounting()
            clear_receipt = self.send(f'proof-clear-{low:06d}','clearLegacyProofs(bytes32[])',digests)
            self.verify_proofs(part,cleared=True)
            self.accounting()
            self.result['completedProofs'] = low+len(part)
            self.result['batches'].append({'kind':'proofs','offset':low,'count':len(part),
                'copyHash':copy_receipt['transactionHash'],'clearHash':clear_receipt['transactionHash']})
            atomic_json(self.progress,self.result)
        status = self.rpc.call('eth_call',[{'to':self.ledger,'data':selector('proofMigrationStatus()')},'latest'])
        state = words(status,5)
        require(state == [int(self.inventory_hash,16),len(self.proofs),len(self.proofs),len(self.proofs),1], 'Proof migration counters disagree')
        ids = sorted((int(epoch),record) for epoch,record in self.epochs.items())
        self.send('start-epoch-migration','startEpochMigration(bytes32,uint256)',self.inventory_hash,len(ids))
        for low in range(0,len(ids),self.batch_size):
            part = ids[low:low+self.batch_size]
            self.verify_epochs(part,'source')
            argument = '['+','.join(str(epoch) for epoch,_ in part)+']'
            copy_receipt = self.send(f'epoch-copy-{low:06d}','copyLegacyEpochs(uint48[])',argument)
            self.verify_epochs(part,'copied')
            self.accounting()
            clear_receipt = self.send(f'epoch-clear-{low:06d}','clearLegacyEpochs(uint48[])',argument)
            self.verify_epochs(part,'cleared')
            self.accounting()
            self.result['completedEpochs'] = low+len(part)
            self.result['batches'].append({'kind':'epochs','offset':low,'count':len(part),
                'copyHash':copy_receipt['transactionHash'],'clearHash':clear_receipt['transactionHash']})
            atomic_json(self.progress,self.result)
        state = words(self.rpc.call('eth_call',[{'to':self.ledger,'data':selector('epochMigrationStatus()')},'latest']),5)
        require(state == [int(self.inventory_hash,16),len(ids),len(ids),len(ids),1], 'Epoch migration counters disagree')
        self.result['status'] = 'VERIFIED_CANONICAL_RECORDS_AND_CLEARED_HISTORICAL_SLOTS'
        atomic_json(self.progress,self.result)
        return self.result

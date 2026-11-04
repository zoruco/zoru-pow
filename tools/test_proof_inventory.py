#!/usr/bin/env python3
import copy
import json
import unittest
from proof_inventory import inventory_fingerprint, validate_records, words


class ProofInventoryTests(unittest.TestCase):
    def setUp(self):
        self.records = [
            {'epoch': 0, 'beneficiary': '0x'+'1'*40, 'indexPlusOne': 1, 'claimed': True, 'claimAmount': 250},
            {'epoch': 0, 'beneficiary': '0x'+'2'*40, 'indexPlusOne': 2, 'claimed': False, 'claimAmount': None},
        ]
        self.epochs = {0: {'budget': 500, 'proofCount': 2, 'sealed': True}}
        self.accounting = {'totalProofs': 2, 'allocatedSupply': 500, 'fundedSupply': 500,
                           'paidSupply': 250, 'ledgerBalance': 250}

    def validate(self):
        validate_records(self.records, self.epochs, self.accounting)

    def test_complete_claimed_and_unclaimed_entitlements(self):
        self.validate()
        self.assertEqual([r['entitlement'] for r in self.records], [250, 250])

    def test_missing_record_duplicate_index_or_changed_claim_stops_reconciliation(self):
        original = copy.deepcopy(self.records)
        for mutation in ['missing', 'duplicate-index', 'claim-status', 'reward', 'owner']:
            with self.subTest(mutation=mutation):
                self.records = copy.deepcopy(original)
                if mutation == 'missing': self.records.pop()
                if mutation == 'duplicate-index': self.records[1]['indexPlusOne'] = 1
                if mutation == 'claim-status': self.records[1]['claimed'] = True
                if mutation == 'reward': self.records[0]['claimAmount'] += 1
                if mutation == 'owner': self.records[0]['beneficiary'] = '0x'+'0'*40
                with self.assertRaises(ValueError): self.validate()

    def test_supply_and_backing_mismatches_stop_reconciliation(self):
        for field in ['totalProofs', 'allocatedSupply', 'fundedSupply', 'paidSupply', 'ledgerBalance']:
            with self.subTest(field=field):
                old = self.accounting[field]
                self.accounting[field] = old + (1 if field != 'ledgerBalance' else -1)
                with self.assertRaises(ValueError): self.validate()
                self.accounting[field] = old

    def test_noncompactable_index_and_unsealed_paid_reward_are_rejected(self):
        self.records[0]['indexPlusOne'] = 2**32
        with self.assertRaises(ValueError): self.validate()
        self.records[0]['indexPlusOne'] = 1
        self.epochs[0]['sealed'] = False
        with self.assertRaises(ValueError): self.validate()

    def test_zero_value_claim_remains_a_claim(self):
        records = [{'epoch': 0, 'beneficiary': '0x'+'1'*40, 'indexPlusOne': i+1, 'claimed': True,
                    'claimAmount': (2*(i+1)//4)-(2*i//4)} for i in range(4)]
        validate_records(records, {0: {'budget': 2, 'proofCount': 4, 'sealed': True}},
                         {'totalProofs': 4, 'allocatedSupply': 2, 'fundedSupply': 2, 'paidSupply': 2, 'ledgerBalance': 0})
        self.assertTrue(records[0]['claimed'])
        self.assertEqual(records[0]['entitlement'], 0)

    def test_truncated_and_nonhex_abi_data_are_rejected(self):
        for value in ['0x01', '00'*32, '0x'+'z'*64]:
            with self.subTest(value=value), self.assertRaises(ValueError): words(value, 1)

    def test_inventory_fingerprint_survives_json_round_trip_and_detects_changes(self):
        value = {'epochs':{1:{'budget':500},2:{'budget':100},10:{'budget':50}},'proofs':self.records}
        expected = inventory_fingerprint(value)
        value['inventorySha256'] = expected
        self.assertEqual(inventory_fingerprint(json.loads(json.dumps(value))),expected)
        value['epochs'][2]['budget'] += 1
        self.assertNotEqual(inventory_fingerprint(value),expected)


if __name__ == '__main__': unittest.main()

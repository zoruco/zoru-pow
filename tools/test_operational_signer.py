#!/usr/bin/env python3
import copy
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import operational_signer
from proof_inventory import selector


class OperationalSigningTests(unittest.TestCase):
    def setUp(self):
        self.manifest=Path(__file__).resolve().parents[1]/'release/mainnet.json'
        self.account='0x85e8d9997cd9f56f1e97154a070d540f123209cb'
        self.transaction={'from':self.account,'to':json.loads(self.manifest.read_text())['ledger'],
            'chainId':6736,'nonce':18665,'gasLimit':500000,'gasPrice':'150000000000','value':'0','type':0,
            'data':selector('copyLegacyProofs(bytes32[])')+f'{32:064x}'+f'{1:064x}'+'1'*64}
        self.args=SimpleNamespace(manifest=self.manifest,account=self.account,cast='cast')

    def test_transfer_wrong_network_recipient_function_and_fee_inputs_never_reach_signing(self):
        changes=[{'value':'1'},{'value':0.1},{'value':False},{'chainId':46736},
                 {'to':'0x'+'1'*40},{'from':'0x'+'2'*40},{'type':2},
                 {'gasLimit':3000001},{'gasPrice':'300000000001'},{'gasLimit':3000000,'gasPrice':'200000000000'},
                 {'data':selector('claim(bytes32)')+'1'*64},{'unexpected':'field'}]
        for change in changes:
            with self.subTest(change=change):
                transaction=copy.deepcopy(self.transaction)
                transaction.update(change)
                with patch('sys.stdin',io.StringIO(json.dumps(transaction))),\
                     patch.object(operational_signer,'Rpc',side_effect=AssertionError('Rejected transaction reached network/signing')):
                    with self.assertRaises(ValueError):operational_signer.run(self.args)

    def test_noncanonical_empty_and_oversized_batches_are_rejected_before_credentials(self):
        prefix=selector('copyLegacyProofs(bytes32[])')
        for data in [prefix+f'{64:064x}'+f'{1:064x}'+'1'*64,
                     prefix+f'{32:064x}'+f'{0:064x}',
                     prefix+f'{32:064x}'+f'{65:064x}'+'1'*64*65,
                     self.transaction['data']+'00']:
            transaction={**self.transaction,'data':data}
            with self.subTest(data=data[:75]),patch('sys.stdin',io.StringIO(json.dumps(transaction))),\
                 patch.object(operational_signer,'Rpc',side_effect=AssertionError('Unbounded input reached credentials')):
                with self.assertRaises(ValueError):operational_signer.run(self.args)

    def test_private_credentials_reject_symlinks_and_permissive_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            secret=Path(directory)/'credential'
            secret.write_text('test fixture')
            secret.chmod(0o600)
            operational_signer.private_file(secret)
            secret.chmod(0o644)
            with self.assertRaises(ValueError):operational_signer.private_file(secret)
            secret.chmod(0o600)
            link=Path(directory)/'link'
            link.symlink_to(secret)
            with self.assertRaises(ValueError):operational_signer.private_file(link)

    def test_exact_unsigned_quantities_reject_coercion(self):
        for value in [True,False,-1,0.1,'-0','+1','1e3',2**256]:
            with self.subTest(value=value),self.assertRaises(ValueError):operational_signer.unsigned(value)
        self.assertEqual(operational_signer.unsigned('0x1a50'),6736)

    def test_wallet_case_normalization_keeps_ciphertext_private_and_preserves_original(self):
        with tempfile.TemporaryDirectory() as directory:
            wallet=Path(directory)/'wallet.json'
            value={'version':3,'Crypto':{'ciphertext':'encrypted-fixture','kdf':'scrypt'}}
            wallet.write_text(json.dumps(value))
            original=wallet.read_bytes()
            with operational_signer.compatible_wallet(wallet) as normalized:
                self.assertEqual(json.loads(normalized.read_text())['crypto'],value['Crypto'])
                operational_signer.private_file(normalized)
                self.assertEqual(wallet.read_bytes(),original)
            self.assertFalse(normalized.exists())
            wallet.write_text(json.dumps({**value,'crypto':value['Crypto']}))
            with self.assertRaisesRegex(ValueError,'Ambiguous'):
                with operational_signer.compatible_wallet(wallet):pass


if __name__=='__main__':unittest.main()

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock,patch

from release_transaction import MainnetTransactions,atomic_json


class TransactionRecoveryTests(unittest.TestCase):
    def test_native_finality_uses_a_fixed_checkpoint(self):
        transaction=MainnetTransactions.__new__(MainnetTransactions)
        receipt={'blockHash':'0x'+'a'*64}
        transaction.confirmed=Mock(return_value=receipt)
        transaction.native_info=Mock(side_effect=[{'head_block_num':100,'last_irreversible_block_num':99},
                                                {'head_block_num':102,'last_irreversible_block_num':100}])
        with patch('release_transaction.time.sleep'):
            self.assertEqual(transaction.wait_irreversible({'transactionHash':'0x1'}),(receipt,100,100))

    def test_reincluded_receipt_requires_a_new_native_finality_checkpoint(self):
        transaction=MainnetTransactions.__new__(MainnetTransactions)
        old={'blockHash':'0x'+'a'*64};new={'blockHash':'0x'+'b'*64}
        transaction.confirmed=Mock(side_effect=[old,new,new])
        transaction.native_info=Mock(side_effect=[{'head_block_num':100,'last_irreversible_block_num':99},
            {'head_block_num':105,'last_irreversible_block_num':103},{'head_block_num':106,'last_irreversible_block_num':105}])
        with patch('release_transaction.time.sleep'):
            self.assertEqual(transaction.wait_irreversible({'transactionHash':'0x1'}),(new,105,105))
    def test_receipt_waits_for_its_canonical_block_without_another_signature(self):
        transaction=MainnetTransactions.__new__(MainnetTransactions)
        transaction.rpc=Mock()
        transaction.rpc.call.side_effect=[{'blockNumber':'0x1234'},None]
        self.assertIsNone(transaction.confirmed({'transactionHash':'0x'+'1'*64}))

    def test_confirmed_interrupted_operation_is_persisted_without_another_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            transaction=MainnetTransactions.__new__(MainnetTransactions)
            transaction.journal=Path(directory)
            transaction.verify=Mock()
            receipt={'transactionHash':'0x'+'1'*64,'gasUsed':'0x100','effectiveGasPrice':'0x20'}
            transaction.confirmed=Mock(return_value=receipt)
            transaction.wait_irreversible=Mock(return_value=(receipt,100,100))
            transaction.signing_callback=Mock(side_effect=AssertionError('Recovery attempted another signature'))
            record={'transaction':{'to':'0x'+'2'*40,'data':'0x12345678'},'state':'broadcast'}
            atomic_json(transaction.journal/'batch.json',record)
            result=transaction.send('batch',record['transaction']['to'],record['transaction']['data'])
            persisted=json.loads((transaction.journal/'batch.json').read_text())
            self.assertEqual(result,receipt)
            self.assertEqual(persisted['receipt'],receipt)
            self.assertEqual(persisted['state'],'confirmed')
            transaction.signing_callback.assert_not_called()


if __name__=='__main__':unittest.main()

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

from release_transaction import MainnetTransactions,atomic_json


class TransactionRecoveryTests(unittest.TestCase):
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

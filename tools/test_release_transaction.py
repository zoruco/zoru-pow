import json
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlsplit
import tempfile
import unittest
from unittest.mock import Mock,patch

from release_transaction import MainnetTransactions,atomic_json


class TransactionRecoveryTests(unittest.TestCase):
    def retained(self,directory):
        transaction=MainnetTransactions.__new__(MainnetTransactions)
        transaction.journal=Path(directory)
        transaction.account='0x'+'1'*40
        transaction.manifest={role:'0x'+'3'*40 for role in ['ledger','beacon','admin']}
        transaction.cast='cast'
        transaction.verify=Mock()
        transaction.rpc=Mock()
        transaction.submit_rpc=Mock()
        absent=['0x1a50',None,None,'0x7','0x7']
        transaction.rpc.batch.return_value=absent.copy()
        transaction.submit_rpc.batch.return_value=absent.copy()
        transaction.submit_rpc.call.side_effect=['0x2','0x'+'2'*64]
        transaction.native_nonce=Mock(return_value=7)
        transaction.signing_callback=Mock(side_effect=AssertionError('Recovery must not sign'))
        path=transaction.journal/'batch.raw'
        path.write_text('0x1234\n')
        record={'label':'batch','transactionHash':'0x'+'2'*64,'signedTransactionFile':str(path),
                'transaction':{'from':transaction.account,'to':transaction.manifest['ledger'],
                               'chainId':6736,'value':'0','nonce':7,'gasPrice':'2'}}
        return transaction,record

    def test_native_nonce_scan_follows_bounded_pages_and_matches_the_signer(self):
        transaction=MainnetTransactions.__new__(MainnetTransactions)
        transaction.account='0x'+'1'*40
        transaction.native=SimpleNamespace(url=urlsplit('http://127.0.0.1:8888'))
        responses=[]
        for body in [{'rows':[{'eth_address':'2'*40,'nonce':123}],'more':True,'next_key':'1000'},
                     {'rows':[{'eth_address':'1'*40,'nonce':7}],'more':False}]:
            response=Mock(status=200)
            response.read.return_value=json.dumps(body).encode()
            responses.append(response)
        connection=Mock()
        connection.getresponse.side_effect=responses
        with patch('http.client.HTTPConnection',return_value=connection):
            self.assertEqual(transaction.native_nonce(),7)
        requests=connection.request.call_args_list
        self.assertEqual(json.loads(requests[0].args[2])['limit'],1000)
        self.assertEqual(json.loads(requests[1].args[2])['lower_bound'],'1000')

    def test_absent_submission_reuses_only_the_persisted_signed_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            transaction,record=self.retained(directory)
            def submit(method,params):
                if method=='eth_gasPrice':return '0x2'
                self.assertEqual(method,'eth_sendRawTransaction')
                self.assertEqual(params,['0x1234'])
                persisted=json.loads((transaction.journal/'batch.json').read_text())
                self.assertTrue(persisted['resubmissions'][0]['sameSignedBytes'])
                return record['transactionHash']
            transaction.submit_rpc.call.side_effect=submit
            with patch('release_transaction.subprocess.check_output',return_value=record['transactionHash']):
                self.assertTrue(transaction.retry_retained(record))
            transaction.signing_callback.assert_not_called()

    def test_changed_pending_or_consumed_nonce_prevents_resubmission(self):
        for endpoint,index in [('rpc',3),('rpc',4),('submit_rpc',3),('submit_rpc',4)]:
            with self.subTest(endpoint=endpoint,index=index),tempfile.TemporaryDirectory() as directory:
                transaction,record=self.retained(directory)
                getattr(transaction,endpoint).batch.return_value[index]='0x8'
                self.assertFalse(transaction.retry_retained(record))
                transaction.submit_rpc.call.assert_not_called()
                transaction.signing_callback.assert_not_called()

    def test_native_nonce_disagreement_prevents_resubmission(self):
        with tempfile.TemporaryDirectory() as directory:
            transaction,record=self.retained(directory)
            transaction.native_nonce.return_value=8
            self.assertFalse(transaction.retry_retained(record))
            transaction.submit_rpc.call.assert_not_called()

    def test_retained_transaction_stays_within_release_authority(self):
        for field,value in [('from','0x'+'4'*40),('to','0x'+'4'*40),('chainId',46736),('value','1'),('label','../batch')]:
            with self.subTest(field=field),tempfile.TemporaryDirectory() as directory:
                transaction,record=self.retained(directory)
                if field=='label':record[field]=value
                else:record['transaction'][field]=value
                with self.assertRaises(ValueError):transaction.retry_retained(record)
                transaction.submit_rpc.call.assert_not_called()
                transaction.signing_callback.assert_not_called()

    def test_known_receipt_or_pending_transaction_is_never_rebroadcast(self):
        for endpoint,index in [('rpc',1),('rpc',2),('submit_rpc',1),('submit_rpc',2)]:
            with self.subTest(endpoint=endpoint,index=index),tempfile.TemporaryDirectory() as directory:
                transaction,record=self.retained(directory)
                getattr(transaction,endpoint).batch.return_value[index]={'hash':record['transactionHash']}
                self.assertFalse(transaction.retry_retained(record))
                transaction.submit_rpc.call.assert_not_called()

    def test_recovery_refuses_a_different_chain(self):
        with tempfile.TemporaryDirectory() as directory:
            transaction,record=self.retained(directory)
            transaction.submit_rpc.batch.return_value[0]='0xb690'
            with self.assertRaisesRegex(ValueError,'identity changed'):transaction.retry_retained(record)
            transaction.submit_rpc.call.assert_not_called()

    def test_recovery_never_raises_the_signed_fee(self):
        with tempfile.TemporaryDirectory() as directory:
            transaction,record=self.retained(directory)
            transaction.submit_rpc.call.side_effect=['0x3']
            self.assertFalse(transaction.retry_retained(record))
            self.assertEqual(transaction.submit_rpc.call.call_count,1)
            transaction.signing_callback.assert_not_called()

    def test_modified_retained_bytes_cannot_be_rebroadcast(self):
        with tempfile.TemporaryDirectory() as directory:
            transaction,record=self.retained(directory)
            with patch('release_transaction.subprocess.check_output',return_value='0x'+'3'*64):
                with self.assertRaisesRegex(ValueError,'fingerprint differs'):transaction.retry_retained(record)
            self.assertEqual(transaction.submit_rpc.call.call_count,1)

    def test_receipt_wait_bounds_rebroadcast_attempts(self):
        transaction=MainnetTransactions.__new__(MainnetTransactions)
        transaction.confirmed=Mock(return_value=None)
        transaction.retry_retained=Mock(return_value=True)
        with patch('release_transaction.time.monotonic',side_effect=iter(range(1000))),patch('release_transaction.time.sleep'):
            with self.assertRaisesRegex(RuntimeError,'Retain and reconcile'):
                transaction.wait_irreversible({'transactionHash':'0x1'})
        self.assertEqual(transaction.retry_retained.call_count,2)

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

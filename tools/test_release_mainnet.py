#!/usr/bin/env python3
from types import SimpleNamespace
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

from proof_migration import ProofMigration
from release_mainnet import Release


class ReleaseSafetyTests(unittest.TestCase):
    def test_final_activation_is_refused_without_complete_migration(self):
        release=Release.__new__(Release)
        release.state={'stages':{}}
        release.upgrade=Mock()
        with self.assertRaisesRegex(ValueError,'incomplete'):release.finalize()
        release.upgrade.assert_not_called()

    def test_uncleared_or_unrecorded_receipt_retirement_cannot_activate_final_code(self):
        for recorded in [False,True]:
            with self.subTest(recorded=recorded),tempfile.TemporaryDirectory() as directory:
                release=Release.__new__(Release)
                release.state={'stages':{'migrate':'ALL_RECORDS_VERIFIED_AND_OBSOLETE_ROWS_CLEARED'},
                    'irreversibilityBarrier':100,'implementations':{'ZoruLedger':'0x'+'2'*40}}
                release.irreversible=Mock()
                release.verify_records=Mock()
                release.migration=Mock(return_value=SimpleNamespace(proofs=[1],epochs={1:1},inventory_hash='0x1'))
                release.manifest={'ledger':'0x'+'3'*40}
                release.call=Mock(return_value='0x'+'1'*64)
                release.owner=SimpleNamespace(journal=Path(directory),confirmed=Mock(return_value={'status':'0x1'}))
                if recorded:(release.owner.journal/'retire-migration-receipts.json').write_text('{}')
                release.empty_receipts=Mock(side_effect=ValueError('Temporary migration receipt remains'))
                release.upgrade=Mock()
                with self.assertRaises(ValueError):release.finalize()
                release.upgrade.assert_not_called()

    def test_operational_account_never_receives_owner_migration_authority(self):
        migration=ProofMigration.__new__(ProofMigration)
        migration.t=SimpleNamespace(send=Mock())
        migration.proof_transactions=SimpleNamespace(send=Mock())
        migration.operational_epochs=False
        migration.data=lambda signature,*_:signature
        migration.ledger='0x'+'1'*40
        for function in ['copyLegacyProofs(bytes32[])','clearLegacyProofs(bytes32[])']:
            migration.send('proof-batch',function,'[]')
        migration.send('initialize','startProofMigration(bytes32,uint256)','0x1',1)
        migration.send('epochs','copyLegacyEpochs(uint48[])','[1]')
        self.assertEqual(migration.proof_transactions.send.call_count,2)
        self.assertEqual(migration.t.send.call_count,2)

    def test_permissionless_epoch_records_use_the_bounded_operational_signer(self):
        migration=ProofMigration.__new__(ProofMigration)
        migration.t=SimpleNamespace(send=Mock())
        migration.proof_transactions=SimpleNamespace(send=Mock())
        migration.operational_epochs=True
        migration.data=lambda signature,*_:signature
        migration.ledger='0x'+'1'*40
        migration.send('epochs','copyLegacyEpochs(uint48[])','[1]')
        self.assertEqual(migration.proof_transactions.send.call_args.kwargs,{'gas_limit':3_000_000})
        migration.send('initialize','startEpochMigration(bytes32,uint256)','0x1',1)
        self.assertEqual(migration.t.send.call_count,1)


if __name__=='__main__':unittest.main()

// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruLedgerMigration} from "../src/ZoruLedgerMigration.sol";
import {ZoruLedgerV1} from "./fixtures/ZoruLedgerV1.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {IZoruBeaconSource, IZoruWorkEngine} from "../src/IZoruMining.sol";
import {MockBeacon} from "./MockBeacon.sol";
import {AlwaysAcceptEngine} from "./ZoruProtocol.t.sol";

interface ProofStorageVm {
    function warp(uint256) external;
    function chainId(uint256) external;
    function prank(address) external;
    function store(address target, bytes32 slot, bytes32 value) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
}

/// @notice Exercises deployment-matching V1 through two real coordinated proxy upgrades.
contract ZoruProofStorageTest {
    ProofStorageVm private constant vm = ProofStorageVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant START = 1_800_000_000;
    bytes32 private constant INVENTORY = keccak256("verified-three-proof-inventory");
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    ZoruToken private token;
    ZoruAdminAdapter private admin;
    ZoruLedgerV1 private original;
    ZoruLedgerMigration private migration;
    bytes32 private claimed;
    bytes32 private unclaimed;
    bytes32 private unsealed;

    function setUp() public {
        vm.chainId(6736);
        vm.warp(START - 5);
        token = new ZoruToken(address(this));
        admin = new ZoruAdminAdapter(token);
        ZoruAdminAdapter.SuiteDeployment memory d;
        d.ledgerImplementation = address(new ZoruLedgerV1());
        d.engineImplementation = address(new AlwaysAcceptEngine());
        d.engineData = abi.encodeCall(IZoruWorkEngine.valid, (bytes32(0), 1));
        d.beaconImplementation = address(new MockBeacon(START));
        d.beaconData = abi.encodeCall(IZoruBeaconSource.releaseTime, (0));
        d.launchTime = START;
        d.initialTarget = type(uint256).max >> 16;
        (address proxy,,) = admin.deploySuite(d);
        original = ZoruLedgerV1(proxy);
        token.setIssuer(proxy);
        vm.warp(START + 1);
        claimed = original.submit(0, ALICE, 101);
        unclaimed = original.submit(0, BOB, 102);
        vm.warp(START + 61);
        original.seal(0);
        original.claim(claimed);
        unsealed = original.submit(1, ALICE, 103);
        original.setAdmissionPaused(true);
        original.setClaimsPaused(true);
        _upgrade(address(new ZoruLedgerMigration()));
        migration = ZoruLedgerMigration(proxy);
    }

    function _upgrade(address implementation) private {
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = implementation;
        admin.scheduleUpgrade(u);
        vm.warp(admin.activationTime());
        admin.executeScheduledUpgrade();
        require(!admin.recoveryRequired(), "upgrade checkpoint failed");
    }

    function _digests() private view returns (bytes32[] memory d) {
        d = new bytes32[](3);
        d[0] = claimed;
        d[1] = unclaimed;
        d[2] = unsealed;
    }

    function _one(bytes32 digest) private pure returns (bytes32[] memory d) {
        d = new bytes32[](1);
        d[0] = digest;
    }

    function _slot(bytes32 digest, uint256 mappingSlot) private pure returns (bytes32) {
        return keccak256(abi.encode(digest, mappingSlot));
    }

    function _complete() private {
        migration.startProofMigration(INVENTORY, 3);
        migration.copyLegacyProofs(_digests());
        migration.clearLegacyProofs(_digests());
        uint48[] memory ids = new uint48[](2);
        ids[1] = 1;
        migration.startEpochMigration(INVENTORY, 2);
        migration.copyLegacyEpochs(ids);
        migration.clearLegacyEpochs(ids);
    }

    function testActualUpgradesPreserveClaimsBalancesAndProxyAddresses() public {
        address proxy = address(original);
        uint256 allocated = original.allocatedSupply();
        uint256 funded = original.fundedSupply();
        uint256 paid = original.paidSupply();
        uint256 lifetime = token.lifetimeMinted();
        uint256 balance = token.balanceOf(proxy);
        uint256 aliceBalance = token.balanceOf(ALICE);
        _complete();
        require(migration.allocatedSupply() == allocated && migration.fundedSupply() == funded, "allocation changed");
        require(migration.paidSupply() == paid && token.balanceOf(proxy) == balance, "funding changed");
        require(token.lifetimeMinted() == lifetime && token.balanceOf(ALICE) == aliceBalance, "tokens changed");
        _upgrade(address(new ZoruLedger()));
        ZoruLedger ledger = ZoruLedger(proxy);
        require(admin.ledgerProxy() == proxy && ledger.totalProofs() == 3, "proxy or proof count changed");
        require(
            address(ledger.engine()) == admin.engineProxy() && address(ledger.beacon()) == admin.beaconProxy(),
            "module addresses"
        );
        require(ledger.moduleGeneration() == admin.suiteRevision(), "checkpoint");
        ledger.setAdmissionPaused(false);
        ledger.setClaimsPaused(false);
        require(ledger.claim(unclaimed) == 250_000_000, "historical sealed entitlement lost");
        ledger.seal(1);
        require(ledger.claim(unsealed) == 500_000_000, "historical unsealed entitlement lost");
        require(token.balanceOf(ALICE) == 750_000_000 && token.balanceOf(BOB) == 250_000_000, "beneficiaries");
        require(ledger.paidSupply() == ledger.fundedSupply() && ledger.fundedLiability() == 0, "liabilities");
        (bool ok,) = proxy.call(abi.encodeCall(ZoruLedger.claim, (claimed)));
        require(!ok, "previously claimed proof paid again");
        (ok,) = proxy.call(abi.encodeCall(ZoruLedger.claim, (unclaimed)));
        require(!ok, "double claim");
        bytes32 fresh = ledger.submit(ledger.epochNow(), BOB, 999);
        (, uint48 epoch, uint256 index, bool isClaimed) = ledger.proofs(fresh);
        require(epoch == ledger.epochNow() && index == 1 && !isClaimed, "mining did not resume");
        (ok,) = proxy.call(abi.encodeCall(ZoruLedger.submit, (epoch, BOB, 999)));
        require(!ok, "duplicate proof accepted");
        (ok,) = proxy.call(abi.encodeCall(ZoruLedgerMigration.copyLegacyProofs, (_digests())));
        require(!ok, "temporary migration function remains");
    }

    function testCopyIsSeparateFromCleanupAndEveryOldSlotClears() public {
        migration.startProofMigration(INVENTORY, 3);
        migration.copyLegacyProofs(_digests());
        bytes32[] memory digests = _digests();
        for (uint256 i; i < digests.length; ++i) {
            require(vm.load(address(migration), _slot(digests[i], 13)) != 0, "source deleted during copy");
            require(vm.load(address(migration), _slot(digests[i], 16)) != 0, "destination missing");
            (address owner, uint48 epoch, uint256 index, bool isClaimed) = migration.proofs(digests[i]);
            require(owner == (i == 1 ? BOB : ALICE), "owner changed");
            require(epoch == (i == 2 ? 1 : 0) && index == (i == 1 ? 2 : 1), "location changed");
            require(isClaimed == (i == 0), "claim state changed");
        }
        migration.clearLegacyProofs(digests);
        for (uint256 i; i < digests.length; ++i) {
            for (uint256 j; j < 3; ++j) {
                require(
                    vm.load(address(migration), bytes32(uint256(_slot(digests[i], 13)) + j)) == 0, "source retained"
                );
            }
        }
        (bytes32 hash, uint256 expected, uint256 copied, uint256 cleared, bool complete) =
            migration.proofMigrationStatus();
        require(hash == INVENTORY && expected == 3 && copied == 3 && cleared == 3 && complete, "completion");
    }

    function testInterruptedMigrationRestartAndDuplicateBatchesAreIdempotent() public {
        migration.startProofMigration(INVENTORY, 3);
        require(migration.copyLegacyProofs(_one(claimed)) == 1, "first batch");
        (bool ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.clearLegacyProofs, (_one(unclaimed))));
        require(!ok, "cleanup before destination exists");
        require(migration.clearLegacyProofs(_one(claimed)) == 1, "bounded batch cleanup");
        migration.startProofMigration(INVENTORY, 3);
        require(migration.copyLegacyProofs(_digests()) == 2, "restart duplicate handling");
        require(migration.copyLegacyProofs(_digests()) == 0, "copy not idempotent");
        require(migration.clearLegacyProofs(_one(claimed)) == 0, "cleanup retry");
        require(migration.copyLegacyProofs(_digests()) == 0, "copy after cleanup");
        require(migration.clearLegacyProofs(_digests()) == 2, "cleanup restart");
        require(migration.clearLegacyProofs(_digests()) == 0, "cleanup not idempotent");
    }

    function testMalformedBatchRevertsAtomicallyAndCleanupRejectsCorruptDestination() public {
        migration.startProofMigration(INVENTORY, 3);
        bytes32[] memory d = new bytes32[](2);
        d[0] = claimed;
        d[1] = keccak256("not a proof");
        (bool ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.copyLegacyProofs, (d)));
        require(!ok && vm.load(address(migration), _slot(claimed, 16)) == 0, "partial copy survived revert");
        migration.copyLegacyProofs(_digests());
        vm.store(address(migration), _slot(unclaimed, 16), bytes32(uint256(1)));
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.clearLegacyProofs, (_digests())));
        require(!ok && vm.load(address(migration), _slot(claimed, 13)) != 0, "corrupt cleanup survived revert");
    }

    function testMigrationRequiresOwnerPausesExactInventoryAndBoundedBatches() public {
        vm.prank(BOB);
        (bool ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.startProofMigration, (INVENTORY, 3)));
        require(!ok, "unauthorized start");
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.startProofMigration, (INVENTORY, 2)));
        require(!ok, "wrong inventory count");
        migration.setClaimsPaused(false);
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.startProofMigration, (INVENTORY, 3)));
        require(!ok, "start without claims pause");
        migration.setClaimsPaused(true);
        migration.startProofMigration(INVENTORY, 3);
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.copyLegacyProofs, (new bytes32[](0))));
        require(!ok, "empty batch");
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.copyLegacyProofs, (new bytes32[](65))));
        require(!ok, "unbounded batch");
        migration.setAdmissionPaused(false);
        migration.setClaimsPaused(false);
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedger.submit, (migration.epochNow(), BOB, 1)));
        require(!ok, "migration admitted a proof");
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedger.claim, (unclaimed)));
        require(!ok, "migration paid a claim");
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedger.openEpoch, (migration.epochNow())));
        require(!ok, "migration opened an epoch");
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedger.seal, (uint48(1))));
        require(!ok, "migration sealed an epoch");
    }

    function testFinalRuntimeDoesNotReadLegacyStorage() public {
        _complete();
        _upgrade(address(new ZoruLedger()));
        ZoruLedger ledger = ZoruLedger(address(original));
        bytes32 fake = keccak256("legacy-only sentinel");
        vm.store(address(ledger), _slot(fake, 13), bytes32(uint256(uint160(ALICE))));
        vm.store(address(ledger), bytes32(uint256(_slot(fake, 13)) + 1), bytes32(uint256(1)));
        (address owner,, uint256 index,) = ledger.proofs(fake);
        require(owner == address(0) && index == 0, "legacy reader still active");
        ledger.setClaimsPaused(false);
        (bool ok,) = address(ledger).call(abi.encodeCall(ZoruLedger.claim, (fake)));
        require(!ok, "legacy-only claim accepted");
    }

    function _startEpochs() private returns (uint48[] memory ids) {
        migration.startProofMigration(INVENTORY, 3);
        migration.copyLegacyProofs(_digests());
        migration.clearLegacyProofs(_digests());
        ids = new uint48[](2);
        ids[1] = 1;
        migration.startEpochMigration(INVENTORY, 2);
    }

    function testEpochCopyCleanupPreservesEveryFieldAndClearsAllHistoricalSlots() public {
        uint48[] memory ids = _startEpochs();
        bytes32[] memory beforeState = new bytes32[](2);
        for (uint48 i; i < 2; ++i) {
            beforeState[i] = keccak256(abi.encode(migration.epochInfo(i)));
        }
        require(migration.copyLegacyEpochs(ids) == 2, "epoch copy count");
        require(migration.copyLegacyEpochs(ids) == 0, "epoch retry");
        for (uint48 i; i < 2; ++i) {
            bytes32 oldBase = keccak256(abi.encode(i, uint256(12)));
            bytes32 newBase = keccak256(abi.encode(i, uint256(21)));
            require(vm.load(address(migration), oldBase) != 0, "source cleared before verification");
            require(vm.load(address(migration), newBase) != 0, "epoch destination missing");
            require(vm.load(address(migration), bytes32(uint256(newBase) + 3)) == 0, "redundant epoch row");
            require(keccak256(abi.encode(migration.epochInfo(i))) == beforeState[i], "epoch data changed");
        }
        require(migration.clearLegacyEpochs(ids) == 2, "epoch cleanup count");
        require(migration.clearLegacyEpochs(ids) == 0 && migration.copyLegacyEpochs(ids) == 0, "epoch cleanup retry");
        for (uint48 i; i < 2; ++i) {
            bytes32 oldBase = keccak256(abi.encode(i, uint256(12)));
            for (uint256 offset; offset < 9; ++offset) {
                require(vm.load(address(migration), bytes32(uint256(oldBase) + offset)) == 0, "epoch source retained");
            }
            require(keccak256(abi.encode(migration.epochInfo(i))) == beforeState[i], "derived epoch data changed");
        }
        (bytes32 hash, uint256 expected, uint256 copied, uint256 cleared, bool complete) =
            migration.epochMigrationStatus();
        require(hash == INVENTORY && expected == 2 && copied == 2 && cleared == 2 && complete, "epoch completion");
    }

    function testEpochMigrationRejectsIncorrectDerivedSourceAndCorruptDestinationAtomically() public {
        uint48[] memory ids = _startEpochs();
        bytes32 base = keccak256(abi.encode(uint48(0), uint256(12)));
        bytes32 workSlot = bytes32(uint256(base) + 4);
        bytes32 closeSlot = bytes32(uint256(base) + 8);
        bytes32 oldWork = vm.load(address(migration), workSlot);
        bytes32 oldClose = vm.load(address(migration), closeSlot);
        vm.store(address(migration), workSlot, bytes32(uint256(oldWork) + 1));
        (bool ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.copyLegacyEpochs, (ids)));
        require(!ok, "inexact work estimate accepted");
        vm.store(address(migration), workSlot, oldWork);
        vm.store(address(migration), closeSlot, bytes32(uint256(type(uint64).max) + 1));
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.copyLegacyEpochs, (ids)));
        require(!ok, "unrepresentable close time accepted");
        vm.store(address(migration), closeSlot, oldClose);
        migration.copyLegacyEpochs(ids);
        vm.store(address(migration), keccak256(abi.encode(uint48(1), uint256(21))), bytes32(uint256(1)));
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.clearLegacyEpochs, (ids)));
        require(!ok && vm.load(address(migration), base) != 0, "partial epoch cleanup survived revert");
    }

    function testEpochMigrationRequiresCompletedProofsOwnerInventoryAndBoundedBatches() public {
        migration.startProofMigration(INVENTORY, 3);
        (bool ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.startEpochMigration, (INVENTORY, 2)));
        require(!ok, "epochs before proof reconciliation");
        migration.copyLegacyProofs(_digests());
        migration.clearLegacyProofs(_digests());
        vm.prank(BOB);
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.startEpochMigration, (INVENTORY, 2)));
        require(!ok, "unauthorized epoch inventory");
        migration.startEpochMigration(INVENTORY, 2);
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.startEpochMigration, (INVENTORY, 1)));
        require(!ok, "epoch inventory changed during restart");
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.copyLegacyEpochs, (new uint48[](0))));
        require(!ok, "empty epoch batch");
        (ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.copyLegacyEpochs, (new uint48[](65))));
        require(!ok, "unbounded epoch batch");
    }

    function testProofIndexBoundaryKeepsAllThirtyTwoBitsAndRejectsOverflow() public {
        _complete();
        _upgrade(address(new ZoruLedger()));
        ZoruLedger ledger = ZoruLedger(address(original));
        ledger.setAdmissionPaused(false);
        uint48 epoch = ledger.epochNow();
        ledger.submit(epoch, BOB, 900);
        bytes32 metadata = bytes32(uint256(keccak256(abi.encode(epoch, uint256(21)))) + 2);
        uint256 word = uint256(vm.load(address(ledger), metadata));
        uint256 mask = uint256(type(uint32).max) << 64;
        vm.store(address(ledger), metadata, bytes32((word & ~mask) | (uint256(type(uint32).max - 1) << 64)));
        bytes32 last = ledger.submit(epoch, BOB, 901);
        (,, uint256 index, bool isClaimed) = ledger.proofs(last);
        require(index == type(uint32).max && !isClaimed, "proof index truncated");
        require(ledger.epochInfo(epoch).proofCount == type(uint32).max, "epoch proof count truncated");
        (bool ok, bytes memory reason) = address(ledger).call(abi.encodeCall(ZoruLedger.submit, (epoch, BOB, 902)));
        require(!ok && bytes4(reason) == ZoruLedger.ProofLimitReached.selector, "proof count overflow admitted");
    }

    function testMigrationRefusesHistoricalProofIndexThatCannotBeRepresentedExactly() public {
        migration.startProofMigration(INVENTORY, 3);
        bytes32 source = _slot(claimed, 13);
        vm.store(address(migration), bytes32(uint256(source) + 1), bytes32(uint256(type(uint32).max) + 1));
        (bool ok,) = address(migration).call(abi.encodeCall(ZoruLedgerMigration.copyLegacyProofs, (_one(claimed))));
        require(!ok && vm.load(address(migration), _slot(claimed, 16)) == 0, "historical proof index was truncated");
        require(vm.load(address(migration), source) != 0, "source deleted after failed migration");
    }
}

contract WorkEstimateHarness is ZoruLedger {
    function estimate(uint256 target, uint32 count) external pure returns (uint256) {
        return _epochWorkEstimate(target, count);
    }
}

contract ZoruDerivedWorkTest {
    WorkEstimateHarness private harness = new WorkEstimateHarness();

    function testDerivedWorkSaturatesAndHandlesEmptyEpoch() public view {
        require(harness.estimate(1, 0) == 0, "empty work");
        require(harness.estimate(1, 1) == type(uint256).max, "unit work");
        require(harness.estimate(1, type(uint32).max) == type(uint256).max, "saturated work");
    }

    function testFuzzDerivedWorkMatchesRepeatedSaturatingAddition(uint256 target, uint8 count) public view {
        if (target == 0) target = 1;
        uint256 unit = type(uint256).max / target;
        uint256 total;
        for (uint256 i; i < count; ++i) {
            total = unit > type(uint256).max - total ? type(uint256).max : total + unit;
        }
        require(harness.estimate(target, count) == total, "work estimate changed");
    }
}

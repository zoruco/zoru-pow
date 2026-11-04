// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruLedger} from "./ZoruLedger.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Temporary, bounded proof migration implementation. Never the final runtime.
/// @dev Install only after pausing admission and claims on the existing proxy.
/// Copy and cleanup are distinct transactions so the destination can be checked
/// independently before deleting source records. No reward or balance is changed.
contract ZoruLedgerMigration is ZoruLedger {
    using SafeCast for uint256;
    uint256 public constant MAX_PROOF_MIGRATION_BATCH = 64;

    error MigrationInProgress();
    error InvalidMigrationState();
    error InvalidMigrationBatch();
    error InvalidMigrationProof(bytes32 digest);

    event ProofMigrationStarted(bytes32 indexed inventoryHash, uint256 expectedProofs);
    event LegacyProofCopied(bytes32 indexed digest);
    event LegacyProofCleared(bytes32 indexed digest);
    event EpochMigrationStarted(bytes32 indexed inventoryHash, uint256 expectedEpochs);
    event LegacyEpochCopied(uint48 indexed epoch);
    event LegacyEpochCleared(uint48 indexed epoch);
    event MigrationReceiptsCleared(
        bytes32 indexed proofInventory, bytes32 indexed epochInventory, uint256 proofs, uint256 epochs
    );

    function epochInfo(uint48 epoch) public view override returns (Epoch memory) {
        if (compactEpochs[epoch].target != 0) return super.epochInfo(epoch);
        return legacyEpochs[epoch];
    }

    function submit(uint48, address, uint256) public pure override returns (bytes32) {
        revert MigrationInProgress();
    }

    function claim(bytes32) public pure override returns (uint256) {
        revert MigrationInProgress();
    }

    function openEpoch(uint48) public pure override returns (uint256) {
        revert MigrationInProgress();
    }

    function seal(uint48) public pure override {
        revert MigrationInProgress();
    }

    function proofs(bytes32 digest)
        public
        view
        override
        returns (address beneficiary, uint48 epoch, uint256 indexPlusOne, bool claimed)
    {
        if (compactProofs[digest].indexPlusOne != 0) return super.proofs(digest);
        AcceptedProof storage source = legacyProofs[digest];
        return (source.beneficiary, source.epoch, source.indexPlusOne, source.claimed);
    }

    function startProofMigration(bytes32 inventoryHash, uint256 expectedProofs) external onlyOwner {
        if (!admissionPaused || !claimsPaused || inventoryHash == bytes32(0) || expectedProofs != totalProofs) {
            revert InvalidMigrationState();
        }
        if (proofMigrationInventoryHash != bytes32(0)) {
            if (proofMigrationInventoryHash != inventoryHash || proofMigrationExpected != expectedProofs) {
                revert InvalidMigrationState();
            }
            return;
        }
        proofMigrationInventoryHash = inventoryHash;
        proofMigrationExpected = expectedProofs;
        emit ProofMigrationStarted(inventoryHash, expectedProofs);
    }

    function proofMigrationStatus()
        external
        view
        returns (bytes32 inventoryHash, uint256 expected, uint256 copied, uint256 cleared, bool complete)
    {
        return (
            proofMigrationInventoryHash,
            proofMigrationExpected,
            proofMigrationCopied,
            proofMigrationCleared,
            proofMigrationInventoryHash != bytes32(0) && proofMigrationExpected == totalProofs
                && proofMigrationCopied == proofMigrationExpected && proofMigrationCleared == proofMigrationExpected
        );
    }

    function _checkMigrationBatch(uint256 count) private view {
        if (count == 0 || count > MAX_PROOF_MIGRATION_BATCH) revert InvalidMigrationBatch();
        if (
            !admissionPaused || !claimsPaused || proofMigrationInventoryHash == bytes32(0)
                || proofMigrationExpected != totalProofs
        ) revert InvalidMigrationState();
    }

    function _matches(AcceptedProof storage source, PackedAcceptedProof storage destination)
        private
        view
        returns (bool)
    {
        return destination.indexPlusOne != 0 && destination.beneficiary == source.beneficiary
            && destination.epoch == source.epoch && uint256(destination.indexPlusOne) == source.indexPlusOne
            && destination.claimed == source.claimed;
    }

    function copyLegacyProofs(bytes32[] calldata digests) external returns (uint256 copied) {
        _checkMigrationBatch(digests.length);
        for (uint256 i; i < digests.length; ++i) {
            bytes32 digest = digests[i];
            AcceptedProof storage source = legacyProofs[digest];
            PackedAcceptedProof storage destination = compactProofs[digest];
            if (source.indexPlusOne == 0) {
                // A retry after cleanup is safe; unknown identifiers fail closed.
                if (destination.indexPlusOne == 0) revert InvalidMigrationProof(digest);
                continue;
            }
            if (destination.indexPlusOne != 0) {
                if (!_matches(source, destination)) revert InvalidMigrationProof(digest);
                continue;
            }
            if (source.beneficiary == address(0) || source.indexPlusOne > type(uint32).max) {
                revert InvalidMigrationProof(digest);
            }
            Epoch storage epoch = legacyEpochs[source.epoch];
            if (epoch.target == 0 || source.indexPlusOne > epoch.proofCount) revert InvalidMigrationProof(digest);
            // forge-lint: disable-next-line(unsafe-typecast)
            compactProofs[digest] =
                PackedAcceptedProof(source.beneficiary, source.epoch, uint32(source.indexPlusOne), source.claimed);
            ++copied;
            emit LegacyProofCopied(digest);
        }
        proofMigrationCopied += copied;
        if (proofMigrationCopied > proofMigrationExpected) revert InvalidMigrationState();
    }

    function clearLegacyProofs(bytes32[] calldata digests) external returns (uint256 cleared) {
        _checkMigrationBatch(digests.length);
        // The owner starts from a fully verified event/state inventory. Cleanup
        // verifies each destination again and may follow each copied batch so
        // migration does not require RAM for two complete proof inventories.
        for (uint256 i; i < digests.length; ++i) {
            bytes32 digest = digests[i];
            AcceptedProof storage source = legacyProofs[digest];
            PackedAcceptedProof storage destination = compactProofs[digest];
            if (source.indexPlusOne == 0) {
                if (destination.indexPlusOne == 0) revert InvalidMigrationProof(digest);
                continue;
            }
            if (!_matches(source, destination)) revert InvalidMigrationProof(digest);
            delete legacyProofs[digest];
            ++cleared;
            emit LegacyProofCleared(digest);
        }
        proofMigrationCleared += cleared;
        if (proofMigrationCleared > proofMigrationExpected) revert InvalidMigrationState();
    }

    function startEpochMigration(bytes32 inventoryHash, uint256 expectedEpochs) external onlyOwner {
        _checkMigrationBatch(1);
        if (
            proofMigrationCopied != proofMigrationExpected || proofMigrationCleared != proofMigrationExpected
                || inventoryHash == bytes32(0) || (hasOpened && expectedEpochs == 0)
        ) revert InvalidMigrationState();
        if (epochMigrationInventoryHash != bytes32(0)) {
            if (epochMigrationInventoryHash != inventoryHash || epochMigrationExpected != expectedEpochs) {
                revert InvalidMigrationState();
            }
            return;
        }
        epochMigrationInventoryHash = inventoryHash;
        epochMigrationExpected = expectedEpochs;
        emit EpochMigrationStarted(inventoryHash, expectedEpochs);
    }

    function epochMigrationStatus()
        external
        view
        returns (bytes32 inventoryHash, uint256 expected, uint256 copied, uint256 cleared, bool complete)
    {
        return (
            epochMigrationInventoryHash,
            epochMigrationExpected,
            epochMigrationCopied,
            epochMigrationCleared,
            epochMigrationInventoryHash != bytes32(0) && epochMigrationCopied == epochMigrationExpected
                && epochMigrationCleared == epochMigrationExpected
        );
    }

    function _checkEpochBatch(uint256 count) private view {
        _checkMigrationBatch(count);
        if (epochMigrationInventoryHash == bytes32(0)) revert InvalidMigrationState();
    }

    function _epochMatches(Epoch storage source, PackedEpoch storage destination) private view returns (bool) {
        return destination.target != 0 && destination.target == source.target && destination.seed == source.seed
            && _epochWorkEstimate(source.target, source.proofCount) == source.verifiedWorkEstimate
            && destination.budget == source.budget && destination.proofCount == source.proofCount
            && destination.generation == source.generation && destination.closesAt == source.closesAt
            && destination.isSealed == source.isSealed && source.engine == address(engine)
            && source.beaconSource == address(beacon);
    }

    function copyLegacyEpochs(uint48[] calldata ids) external returns (uint256 copied) {
        _checkEpochBatch(ids.length);
        for (uint256 i; i < ids.length; ++i) {
            uint48 epoch = ids[i];
            Epoch storage source = legacyEpochs[epoch];
            PackedEpoch storage destination = compactEpochs[epoch];
            if (source.target == 0) {
                if (destination.target == 0) revert InvalidMigrationState();
                continue;
            }
            if (destination.target != 0) {
                if (!_epochMatches(source, destination)) revert InvalidMigrationState();
                continue;
            }
            if (
                source.engine != address(engine) || source.beaconSource != address(beacon)
                    || source.proofCount > MAX_PROOFS_PER_EPOCH
                    || source.verifiedWorkEstimate != _epochWorkEstimate(source.target, source.proofCount)
            ) revert InvalidMigrationState();
            compactEpochs[epoch] = PackedEpoch(
                source.target,
                source.seed,
                source.budget.toUint64(),
                uint32(source.proofCount),
                source.generation.toUint64(),
                source.closesAt.toUint64(),
                source.isSealed
            );
            ++copied;
            emit LegacyEpochCopied(epoch);
        }
        epochMigrationCopied += copied;
        if (epochMigrationCopied > epochMigrationExpected) revert InvalidMigrationState();
    }

    function clearLegacyEpochs(uint48[] calldata ids) external returns (uint256 cleared) {
        _checkEpochBatch(ids.length);
        for (uint256 i; i < ids.length; ++i) {
            uint48 epoch = ids[i];
            Epoch storage source = legacyEpochs[epoch];
            PackedEpoch storage destination = compactEpochs[epoch];
            if (source.target == 0) {
                if (destination.target == 0) revert InvalidMigrationState();
                continue;
            }
            if (!_epochMatches(source, destination)) revert InvalidMigrationState();
            delete legacyEpochs[epoch];
            ++cleared;
            emit LegacyEpochCleared(epoch);
        }
        epochMigrationCleared += cleared;
        if (epochMigrationCleared > epochMigrationExpected) revert InvalidMigrationState();
    }

    /// @notice Retires temporary counters after verified record cleanup.
    /// @dev Completion remains in events; all eight receipt slots become zero.
    function clearMigrationReceipts() external onlyOwner {
        if (!admissionPaused || !claimsPaused) revert InvalidMigrationState();
        if (proofMigrationInventoryHash == bytes32(0) && epochMigrationInventoryHash == bytes32(0)) {
            if (
                proofMigrationExpected != 0 || proofMigrationCopied != 0 || proofMigrationCleared != 0
                    || epochMigrationExpected != 0 || epochMigrationCopied != 0 || epochMigrationCleared != 0
            ) revert InvalidMigrationState();
            return;
        }
        if (
            proofMigrationInventoryHash == bytes32(0) || epochMigrationInventoryHash == bytes32(0)
                || proofMigrationExpected != totalProofs || proofMigrationCopied != proofMigrationExpected
                || proofMigrationCleared != proofMigrationExpected || epochMigrationCopied != epochMigrationExpected
                || epochMigrationCleared != epochMigrationExpected
        ) revert InvalidMigrationState();
        emit MigrationReceiptsCleared(
            proofMigrationInventoryHash, epochMigrationInventoryHash, proofMigrationExpected, epochMigrationExpected
        );
        delete proofMigrationInventoryHash;
        delete proofMigrationExpected;
        delete proofMigrationCopied;
        delete proofMigrationCleared;
        delete epochMigrationInventoryHash;
        delete epochMigrationExpected;
        delete epochMigrationCopied;
        delete epochMigrationCleared;
    }
}

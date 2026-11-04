// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruDrandBeacon} from "./ZoruDrandBeacon.sol";

/// @notice Temporary cleanup of cache rows retired by the rolling cache.
contract ZoruDrandBeaconMigration is ZoruDrandBeacon {
    error InvalidHistoricalCacheBatch();
    event HistoricalCacheCleared(uint48 indexed epoch);

    function clearHistoricalCache(uint48[] calldata epochs) external {
        if (epochs.length == 0 || epochs.length > 64) revert InvalidHistoricalCacheBatch();
        for (uint256 i; i < epochs.length; ++i) {
            uint48 epoch = epochs[i];
            if (block.timestamp < releaseTime(epoch) + ZORU_EPOCH_PERIOD) revert InvalidHistoricalCacheBatch();
            delete cachedSeed[epoch];
            delete cachedConfig[epoch];
            emit HistoricalCacheCleared(epoch);
        }
    }
}

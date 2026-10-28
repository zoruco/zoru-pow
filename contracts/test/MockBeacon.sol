// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IZoruBeaconSource} from "../src/IZoruMining.sol";

/// @dev TEST-ONLY deterministic beacon. NEVER deploy on a public network.
contract MockBeacon is IZoruBeaconSource {
    uint256 public immutable launchTime;

    constructor(uint256 launchTime_) {
        launchTime = launchTime_;
    }

    function releaseTime(uint48 epoch) external view returns (uint256) {
        return launchTime + uint256(epoch) * 60;
    }

    function verifiedSeed(uint48 epoch) external pure returns (bytes32) {
        return keccak256(abi.encode("INSECURE TEST BEACON", epoch));
    }
}

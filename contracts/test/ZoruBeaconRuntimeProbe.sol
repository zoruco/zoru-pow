// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruDrandBeacon} from "../src/ZoruDrandBeacon.sol";

/// @notice Transient, read-only EVM creation probe.
/// @dev Submit creation bytecode through eth_call ONLY. Do not broadcast.
contract ZoruBeaconRuntimeProbe {
    bytes32 public immutable observed;

    constructor(uint256 start, uint48 epoch, bytes memory signature, bytes32 expected) {
        ZoruToken token = new ZoruToken(address(this));
        ZoruAdminAdapter admin = new ZoruAdminAdapter(token);
        ZoruDrandBeacon adapter = ZoruDrandBeacon(
            admin.deployProxy(address(new ZoruDrandBeacon()), abi.encodeCall(ZoruDrandBeacon.initialize, (start)))
        );
        bytes32 result = adapter.publish(epoch, signature);
        require(result == expected, "VEX_DRAND_VERIFICATION_FAILED");
        bytes32 config = adapter.verificationConfigId();
        uint48[] memory epochs = new uint48[](1);
        epochs[0] = epoch;
        (bool unauthorized,) = address(adapter).call(abi.encodeCall(ZoruDrandBeacon.invalidateEpochs, (epochs)));
        require(!unauthorized && adapter.verifiedSeed(epoch) == expected, "PUBLIC_CACHE_CLEAR_ACCEPTED");
        admin.upgrade(address(adapter), admin.implementationOf(address(adapter)),
            abi.encodeCall(ZoruDrandBeacon.invalidateEpochs, (epochs)));
        require(adapter.verifiedSeed(epoch) == bytes32(0) && adapter.verificationConfigId() == config,
            "VEX_CACHE_RECOVERY_FAILED");
        require(adapter.publish(epoch, signature) == expected, "VEX_AUTHENTIC_REPUBLICATION_FAILED");
        observed = result;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruDrandBeacon} from "../src/ZoruDrandBeacon.sol";

/// @notice Transient, read-only EVM creation probe.
/// @dev Submit creation bytecode through eth_call ONLY. Do not broadcast.
contract ZoruBeaconRuntimeProbe {
    bytes32 public immutable observed;

    constructor() {
        uint256 start = 1_727_521_075 + (1_000_000 - 1) * 3;
        ZoruToken token = new ZoruToken(address(this));
        ZoruAdminAdapter admin = new ZoruAdminAdapter(token);
        ZoruDrandBeacon adapter = ZoruDrandBeacon(
            admin.deployProxy(address(new ZoruDrandBeacon()), abi.encodeCall(ZoruDrandBeacon.initialize, (start)))
        );
        bytes memory sig =
            hex"139a803860ff6d842b822b8b37eaeccc4e278dd44440535a976530a1a503e85e11d84b824f18e608a85e627e6b1b08322060cbcf7eca1ea78489252907e8473a";
        bytes32 expected = hex"4da14d73e62d0c909d143e61a2adce866f6be3e7a9d58b1e32a95c87e780569c";
        bytes32 result = adapter.publish(0, sig);
        require(result == expected, "VEX_DRAND_VERIFICATION_FAILED");
        bytes32 config = adapter.verificationConfigId();
        uint48[] memory epochs = new uint48[](1);
        (bool unauthorized,) = address(adapter).call(abi.encodeCall(ZoruDrandBeacon.invalidateEpochs, (epochs)));
        require(!unauthorized && adapter.verifiedSeed(0) == expected, "PUBLIC_CACHE_CLEAR_ACCEPTED");
        admin.upgrade(address(adapter), admin.implementationOf(address(adapter)),
            abi.encodeCall(ZoruDrandBeacon.invalidateEpochs, (epochs)));
        require(adapter.verifiedSeed(0) == bytes32(0) && adapter.verificationConfigId() == config,
            "VEX_CACHE_RECOVERY_FAILED");
        require(adapter.publish(0, sig) == expected, "VEX_AUTHENTIC_REPUBLICATION_FAILED");
        observed = result;
    }
}

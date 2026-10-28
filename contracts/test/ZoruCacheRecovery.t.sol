// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruDrandBeacon} from "../src/ZoruDrandBeacon.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruToken} from "../src/ZoruToken.sol";
import {CryptoCacheRepairFixture} from "./ZoruCryptoVerification.t.sol";
import {CryptoOracleVectors} from "./CryptoOracleVectors.sol";

interface CacheVm { function warp(uint256) external; }

contract ZoruCacheRecoveryTest {
    CacheVm constant vm = CacheVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function make() internal returns (ZoruDrandBeacon beacon, ZoruAdminAdapter admin, address logic) {
        admin = new ZoruAdminAdapter(new ZoruToken(address(this)));
        logic = address(new ZoruDrandBeacon());
        beacon = ZoruDrandBeacon(admin.deployProxy(logic, abi.encodeCall(ZoruDrandBeacon.initialize, (uint256(1730521072)))));
        vm.warp(1730521072);
    }

    function testOptionalProxyAdminCacheCleanupAfterAutomaticRetirement() public {
        (ZoruDrandBeacon beacon, ZoruAdminAdapter admin, address logic) = make();
        CryptoCacheRepairFixture oldBroken = new CryptoCacheRepairFixture();
        bytes32 fake = keccak256("compromised old test verifier cache");
        admin.upgrade(address(beacon), address(oldBroken), abi.encodeCall(oldBroken.writeCache, (0, fake)));
        admin.upgrade(address(beacon), logic, "");
        require(beacon.verifiedSeed(0) == bytes32(0), "unsafe cache rejected without manual cleanup");
        uint48[] memory epochs = new uint48[](1); epochs[0] = 0;
        bytes32 config = beacon.verificationConfigId();
        admin.upgrade(address(beacon), logic, abi.encodeWithSignature("invalidateEpochs(uint48[])", epochs));
        require(beacon.verifiedSeed(0) == bytes32(0), "supported repair must clear cache");
        require(beacon.verificationConfigId() == config, "repair must preserve schedule/key/DST");
        (,bytes memory signature,bytes32 expected,) = CryptoOracleVectors.roundVector(0);
        require(beacon.publish(0, signature) == expected, "authenticated recovery");
    }

    function testOwnerAndPublicCallersCannotBypassExternalProxyAdmin() public {
        (ZoruDrandBeacon beacon,,) = make();
        (,bytes memory signature,bytes32 expected,) = CryptoOracleVectors.roundVector(0);
        beacon.publish(0, signature);
        uint48[] memory epochs = new uint48[](1);
        (bool ok,) = address(beacon).call(abi.encodeWithSignature("invalidateEpochs(uint48[])", epochs));
        require(!ok && beacon.verifiedSeed(0) == expected, "only actual ProxyAdmin may clear");
    }

    function testRepairLeavesUnselectedEpochsUntouched() public {
        (ZoruDrandBeacon beacon, ZoruAdminAdapter admin, address logic) = make();
        (, bytes memory firstSignature, bytes32 firstExpected,) = CryptoOracleVectors.roundVector(0);
        (, bytes memory nextSignature, bytes32 nextExpected,) = CryptoOracleVectors.roundVector(1);
        require(beacon.publish(0, firstSignature) == firstExpected, "publish first epoch");
        vm.warp(1730521132);
        require(beacon.publish(1, nextSignature) == nextExpected, "publish next epoch");

        uint48[] memory epochs = new uint48[](1);
        epochs[0] = 0;
        admin.upgrade(address(beacon), logic, abi.encodeWithSignature("invalidateEpochs(uint48[])", epochs));
        require(beacon.verifiedSeed(0) == bytes32(0), "selected epoch must be cleared");
        require(beacon.verifiedSeed(1) == nextExpected, "other epochs must be untouched");
    }

    function testEmptyRepairBatchReverts() public {
        (ZoruDrandBeacon beacon, ZoruAdminAdapter admin, address logic) = make();
        uint48[] memory epochs = new uint48[](0);
        (bool ok,) = address(admin).call(
            abi.encodeCall(admin.upgrade, (address(beacon), logic, abi.encodeWithSignature("invalidateEpochs(uint48[])", epochs)))
        );
        require(!ok, "empty repair batch must revert");
    }

    function testInvalidBatchRollsBackAndLeavesAuthenticCache() public {
        (ZoruDrandBeacon beacon, ZoruAdminAdapter admin, address logic) = make();
        (,bytes memory signature,bytes32 expected,) = CryptoOracleVectors.roundVector(0);
        beacon.publish(0, signature);
        uint48[] memory epochs = new uint48[](65);
        (bool ok,) = address(admin).call(abi.encodeCall(admin.upgrade, (address(beacon), logic, abi.encodeWithSignature("invalidateEpochs(uint48[])", epochs))));
        require(!ok && beacon.verifiedSeed(0) == expected, "oversized batch must revert atomically");
    }
}

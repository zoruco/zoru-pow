// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruDrandBeacon} from "../src/ZoruDrandBeacon.sol";
import {ZoruDrandBeaconMigration} from "../src/ZoruDrandBeaconMigration.sol";
import {ZoruDrandBeaconOriginal} from "./fixtures/ZoruDrandBeaconOriginal.sol";
import {CryptoOracleVectors} from "./CryptoOracleVectors.sol";

interface BeaconStorageVm {
    function warp(uint256) external;
    function load(address, bytes32) external view returns (bytes32);
    function store(address, bytes32, bytes32) external;
}

contract ZoruBeaconStorageTest {
    BeaconStorageVm private constant vm = BeaconStorageVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant START = 1_730_521_072;

    function _slot(uint48 epoch, uint256 mappingSlot) private pure returns (bytes32) {
        return keccak256(abi.encode(epoch, mappingSlot));
    }

    function testOriginalCacheCleanupAndBoundedFinalCachePreserveScheduleAndAuthentication() public {
        vm.warp(START);
        ZoruAdminAdapter admin = new ZoruAdminAdapter(new ZoruToken(address(this)));
        ZoruDrandBeaconOriginal old = ZoruDrandBeaconOriginal(admin.deployProxy(
            address(new ZoruDrandBeaconOriginal()), abi.encodeCall(ZoruDrandBeaconOriginal.initialize, (START))
        ));
        (, bytes memory first, bytes32 firstSeed,) = CryptoOracleVectors.roundVector(0);
        (, bytes memory second, bytes32 secondSeed,) = CryptoOracleVectors.roundVector(1);
        require(old.publish(0, first) == firstSeed, "original authentication");
        vm.warp(START + 60);
        require(old.publish(1, second) == secondSeed, "original next epoch");
        require(old.verifiedSeed(0) == firstSeed, "original historical cache");
        bytes32 config = old.verificationConfigId();

        address proxy = address(old);
        admin.upgrade(proxy, address(new ZoruDrandBeaconMigration()), "");
        ZoruDrandBeaconMigration migration = ZoruDrandBeaconMigration(proxy);
        require(migration.verificationConfigId() == config && migration.launchRound() == 1_000_000, "schedule changed");
        require(migration.verifiedSeed(0) == bytes32(0), "legacy cache still read");
        require(migration.publish(1, second) == secondSeed, "canonical authentication");
        uint48[] memory ids = new uint48[](2);
        ids[1] = 1;
        (bool ok,) = proxy.call(abi.encodeCall(ZoruDrandBeaconMigration.clearHistoricalCache, (ids)));
        require(!ok && vm.load(proxy, _slot(0, 0)) != 0, "active epoch cleanup was not atomic");
        vm.warp(START + 120);
        migration.clearHistoricalCache(ids);
        migration.clearHistoricalCache(ids);
        for (uint256 i; i < ids.length; ++i) {
            require(vm.load(proxy, _slot(ids[i], 0)) == 0 && vm.load(proxy, _slot(ids[i], 3)) == 0, "legacy row retained");
        }
        require(migration.verifiedSeed(1) == secondSeed, "cleanup changed canonical cache");
        admin.upgrade(proxy, address(new ZoruDrandBeacon()), "");
        ZoruDrandBeacon beacon = ZoruDrandBeacon(proxy);
        require(beacon.verificationConfigId() == config && beacon.verifiedSeed(1) == bytes32(0), "upgrade trust");

        (, bytes memory later, bytes32 laterSeed,) = CryptoOracleVectors.roundVector(2);
        vm.warp(START + 50_000 * 60);
        require(beacon.publish(50_000, later) == laterSeed, "new scheduled epoch authentication");
        require(beacon.verifiedSeed(1) == 0 && beacon.verifiedSeed(50_000) == laterSeed, "single canonical cache");
        require(vm.load(proxy, _slot(50_000, 0)) == 0 && vm.load(proxy, _slot(50_000, 3)) == 0, "legacy cache write");
        vm.store(proxy, _slot(0, 0), firstSeed);
        vm.store(proxy, _slot(0, 3), beacon.cacheTrustId());
        require(beacon.verifiedSeed(0) == 0, "reserved legacy cache reader");
        (ok,) = proxy.call(abi.encodeCall(ZoruDrandBeacon.publish, (uint48(0), first)));
        require(!ok, "historical publication admitted");
        (ok,) = proxy.call(abi.encodeCall(ZoruDrandBeaconMigration.clearHistoricalCache, (ids)));
        require(!ok, "temporary cleanup remains in final runtime");
    }
}

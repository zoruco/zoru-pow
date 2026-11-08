// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {IZoruBeaconSource} from "../src/IZoruMining.sol";
import {SuiteSupport} from "./SuiteSupport.sol";
import {AlwaysAcceptEngine, Vm} from "./ZoruProtocol.t.sol";

contract DelayedBeacon is IZoruBeaconSource {
    uint256 public immutable launchTime;
    mapping(uint48 => bytes32) public seeds;

    constructor(uint256 start) {
        launchTime = start;
    }

    function releaseTime(uint48 epoch) external view returns (uint256) {
        return launchTime + uint256(epoch) * 60;
    }

    function verifiedSeed(uint48 epoch) external view returns (bytes32) {
        return seeds[epoch];
    }

    function setSeed(uint48 epoch, bytes32 seed) external {
        seeds[epoch] = seed;
    }
}

contract ZoruContinuityTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant START = 1_800_000_000;
    address constant ALICE = address(0xA11CE);
    ZoruToken token;
    ZoruLedger ledger;
    ZoruAdminAdapter admin;
    DelayedBeacon beacon;
    bytes32 first;

    function setUp() public {
        vm.chainId(6736);
        vm.warp(START - 5);
        token = new ZoruToken(address(this));
        address source;
        (ledger, admin,, source) = SuiteSupport.mockSuite(
            token, address(new DelayedBeacon(START)), address(new AlwaysAcceptEngine()), START, type(uint256).max >> 16
        );
        beacon = DelayedBeacon(source);
        beacon.setSeed(0, keccak256("seed zero"));
        vm.warp(START + 1);
        first = ledger.submit(0, ALICE, 1);
    }

    function testRolloverProofsEarnRewardsAndHandoffFreezesCounts() public {
        vm.warp(START + 61);
        ZoruLedger.MiningWork memory work = ledger.miningWork();
        require(
            work.epoch == 0 && work.closesAt == START + 90 && work.needsBeacon && work.active, "valid rollover work"
        );
        bytes32 second = ledger.submit(0, ALICE, 2);
        vm.expectRevert(ZoruLedger.EpochNotClosed.selector);
        ledger.seal(0);
        // An arbitrary openEpoch caller cannot cut off the bridge early.
        vm.expectRevert(ZoruLedger.InvalidProof.selector);
        ledger.openEpoch(1);
        beacon.setSeed(1, keccak256("seed one"));
        work = ledger.miningWork();
        require(work.epoch == 1 && work.closesAt == START + 150 && !work.needsBeacon && work.active, "next work ready");
        vm.expectRevert(ZoruLedger.InvalidEpoch.selector);
        ledger.submit(0, ALICE, 3);
        uint256 nextTarget = ledger.targetForEpoch(1);
        ledger.submit(1, ALICE, 4);
        require(ledger.epochInfo(1).target == nextTarget, "retarget frozen after handoff");
        ledger.seal(0);
        require(ledger.claim(first) + ledger.claim(second) == 5 * 1e8, "reward conservation");
        require(ledger.epochInfo(0).proofCount == 2 && ledger.emissionIndex() == 2, "one allocation per epoch");
    }

    function testRolloverDeadlineIsExclusiveAndClaimsCannotBeHeldForever() public {
        vm.warp(START + 89);
        ledger.submit(0, ALICE, 2);
        vm.warp(START + 90);
        ZoruLedger.MiningWork memory work = ledger.miningWork();
        require(work.epoch == 1 && work.needsBeacon, "bounded bridge");
        vm.expectRevert(ZoruLedger.InvalidEpoch.selector);
        ledger.submit(0, ALICE, 3);
        ledger.seal(0);
        require(ledger.claim(first) > 0, "settlement without a working next beacon");
    }

    function testSealedOrOlderWorkCannotBeResurrected() public {
        vm.warp(START + 61);
        beacon.setSeed(1, keccak256("one"));
        ledger.seal(0);
        beacon.setSeed(1, bytes32(0));
        ZoruLedger.MiningWork memory work = ledger.miningWork();
        require(work.epoch == 1, "sealed work stays closed");
        vm.expectRevert(ZoruLedger.InvalidEpoch.selector);
        ledger.submit(0, ALICE, 2);
        vm.warp(START + 121);
        vm.expectRevert(ZoruLedger.InvalidEpoch.selector);
        ledger.submit(0, ALICE, 3);
    }

    function testRolloverCannotBypassScheduledUpgrade() public {
        vm.warp(START + 50);
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = address(new ZoruLedger());
        admin.scheduleUpgrade(u);
        vm.warp(START + 61);
        vm.expectRevert(ZoruLedger.UpgradePending.selector);
        ledger.submit(0, ALICE, 2);
        vm.expectRevert(ZoruLedger.UpgradePending.selector);
        ledger.miningWork();
    }

    function testFirstProofCanUseAuthenticatedUnopenedPreviousEpoch() public {
        vm.warp(START - 5);
        ZoruToken freshToken = new ZoruToken(address(this));
        (ZoruLedger fresh,,, address source) = SuiteSupport.mockSuite(
            freshToken,
            address(new DelayedBeacon(START)),
            address(new AlwaysAcceptEngine()),
            START,
            type(uint256).max >> 16
        );
        DelayedBeacon freshBeacon = DelayedBeacon(source);
        freshBeacon.setSeed(0, keccak256("authenticated previous seed"));
        vm.warp(START + 61);
        ZoruLedger.MiningWork memory work = fresh.miningWork();
        require(
            work.epoch == 0 && work.active && work.needsBeacon && work.seed != bytes32(0),
            "unopened work remains usable"
        );
        vm.expectRevert(ZoruLedger.InvalidProof.selector);
        fresh.openEpoch(1);
        bytes32 proof = fresh.submit(0, ALICE, 111);
        require(
            fresh.epochInfo(0).proofCount == 1 && fresh.emissionIndex() == 1, "first transition proof allocated once"
        );
        freshBeacon.setSeed(1, keccak256("next authenticated seed"));
        fresh.seal(0);
        require(fresh.claim(proof) == 5 * 1e8, "first transition proof earns its budget");
    }

    function testEmergencyRevisionInvalidatesPreviousEpochWork() public {
        vm.warp(START + 61);
        SuiteSupport.emergencyLedger(admin, address(new ZoruLedger()), "");
        ZoruLedger.MiningWork memory work = ledger.miningWork();
        require(work.epoch == 1, "no old generation rollover");
        vm.expectRevert(ZoruLedger.InvalidEpoch.selector);
        ledger.submit(0, ALICE, 2);
    }
}

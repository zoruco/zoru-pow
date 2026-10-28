// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {IZoruBeaconSource} from "../src/IZoruMining.sol";
import {MockBeacon} from "./MockBeacon.sol";
import {AdversarialFixture} from "./ZoruAdversarial.t.sol";

contract RetimedLedgerFixture is ZoruLedger {
    function configureClock(uint256 nextLaunch) external {
        address admin = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"01")))));
        require(msg.sender == admin);
        launchTime = nextLaunch;
    }
}

contract ZoruLongTermTest is AdversarialFixture {
    function _retime(uint256 nextLaunch) internal {
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = address(new RetimedLedgerFixture());
        u.ledgerData = abi.encodeCall(RetimedLedgerFixture.configureClock, (nextLaunch));
        u.beaconImplementation = address(new MockBeacon(nextLaunch));
        u.beaconData = abi.encodeCall(IZoruBeaconSource.releaseTime, (uint48(0)));
        coordinator.emergencyUpgrade(u);
    }

    function testClockRewindCannotReopenSealedEpochOrSpendOtherBacking() public {
        bytes32 first = ledger.submit(0, ALICE, 101);
        vm.warp(START + 61);
        bytes32 other = ledger.submit(1, BOB, 102);
        vm.warp(START + 121);
        ledger.seal(0);
        ledger.seal(1);
        ledger.claim(first);
        require(token.balanceOf(address(ledger)) == 5e8);
        uint256 sealedGeneration = ledger.epochInfo(0).generation;
        _retime(START + 121);
        require(ledger.epochInfo(0).generation == sealedGeneration, "sealed snapshot is immutable");
        require(ledger.epochNow() == 0 && ledger.epochInfo(0).isSealed);
        vm.expectRevert(ZoruLedger.InvalidEpoch.selector);
        ledger.submit(0, ALICE, 103);
        require(token.balanceOf(ALICE) == 5e8, "settled reward is unchanged");
        require(token.balanceOf(address(ledger)) == 5e8, "other epoch remains backed");
        ledger.claim(other);
        require(token.balanceOf(BOB) == 5e8 && ledger.fundedLiability() == 0);

    }

    function testClockRewindCannotDelayAlreadyMatureBudget() public {
        vm.warp(START + 61);
        bytes32 digest = ledger.submit(1, ALICE, 104);
        vm.warp(START + 121);
        _retime(START + 121);
        ledger.seal(1);
        ledger.claim(digest);
        require(token.balanceOf(ALICE) == 5e8 && ledger.unfundedLiability() == 0);
    }
}

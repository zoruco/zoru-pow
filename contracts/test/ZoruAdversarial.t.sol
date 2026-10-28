// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {SuiteSupport} from "./SuiteSupport.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {IZoruBeaconSource, IZoruWorkEngine} from "../src/IZoruMining.sol";
import {MockBeacon} from "./MockBeacon.sol";
import {AlwaysAcceptEngine, RejectEngine, TestFutureIssuer} from "./ZoruProtocol.t.sol";

interface AdversarialVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function warp(uint256) external;
    function chainId(uint256) external;
    function prank(address) external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function load(address, bytes32) external view returns (bytes32);
    function etch(address, bytes calldata) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

contract OutageBeacon is IZoruBeaconSource {
    function releaseTime(uint48 epoch) external pure returns (uint256) {
        return 1_800_000_000 + uint256(epoch) * 60;
    }

    function verifiedSeed(uint48) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract GasGriefEngine is IZoruWorkEngine {
    function valid(bytes32, uint256) external pure returns (bool result) {
        assembly {
            result := 0
            for {} 1 {} {}
        }
    }
}

contract GasGriefBeacon is IZoruBeaconSource {
    function releaseTime(uint48 epoch) external pure returns (uint256) {
        return 1_800_000_000 + uint256(epoch) * 60;
    }

    function verifiedSeed(uint48) external pure returns (bytes32 result) {
        assembly {
            result := 0
            for {} 1 {} {}
        }
    }
}

contract ReenterEngine is IZoruWorkEngine {
    ZoruLedger immutable ledger;

    constructor(ZoruLedger ledger_) {
        ledger = ledger_;
    }

    function valid(bytes32, uint256) external view returns (bool) {
        (bool ok, bytes memory reason) = address(ledger).staticcall(abi.encodeCall(ledger.claim, (bytes32(0))));
        require(!ok && reason.length == 4 && bytes4(reason) == ZoruLedger.Reentered.selector, "reentrancy guard");
        return false;
    }
}

abstract contract AdversarialFixture {
    AdversarialVm constant vm = AdversarialVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant START = 1_800_000_000;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    ZoruToken token;
    ZoruLedger ledger;
    ZoruAdminAdapter coordinator;
    MockBeacon beacon;
    AlwaysAcceptEngine engine;

    function setUp() public virtual {
        vm.chainId(6736);
        vm.warp(START - 10);
        token = new ZoruToken(address(this));
        ledger = makeLedger(token, new MockBeacon(START), 1 << 100);
        vm.warp(START + 1);
    }

    function makeLedger(ZoruToken t, IZoruBeaconSource source, uint256 target) internal returns (ZoruLedger l) {
        address b;
        address e;
        if (address(source) == address(beacon)) source = new MockBeacon(START);
        (l, coordinator, e, b) =
            SuiteSupport.mockSuite(t, address(source), address(new AlwaysAcceptEngine()), START, target);
        engine = AlwaysAcceptEngine(e);
        beacon = MockBeacon(b);
    }

    function upgradeMocks(IZoruWorkEngine nextWork, IZoruBeaconSource nextSource) internal {
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation =
            address(nextWork) == address(engine) ? address(new AlwaysAcceptEngine()) : address(nextWork);
        u.beaconImplementation =
            address(nextSource) == address(beacon) ? address(new MockBeacon(START)) : address(nextSource);
        coordinator.emergencyUpgrade(u);
    }
}

contract ZoruTokenSafetyTest is AdversarialFixture {
    function testNoClockOrReservationSelectorsOnToken() public {
        string[7] memory forbidden = [
            "launchTime()",
            "currentEpoch()",
            "emissionIndex()",
            "reserveEpoch(uint48)",
            "mintReserved(uint48)",
            "budgetForIndex(uint256)",
            "HALVING_EPOCHS()"
        ];
        for (uint256 i; i < forbidden.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(forbidden[i], uint256(0)));
            require(!ok, "immutable token must not expose mining policy");
        }
    }

    function testIssuerRevocationAndReplacementNeverCallOldIssuer() public {
        token.setIssuer(address(new GasGriefEngine()));
        token.setIssuer(address(0));
        token.setIssuer(address(this));
        token.mint(ALICE, 10);
        require(token.balanceOf(ALICE) == 10, "external issuer recovery");
        vm.expectRevert(ZoruToken.InvalidIssuer.selector);
        token.setIssuer(BOB);
    }

    function testInvalidReceiverRollsBackLifetimeCounter() public {
        token.setIssuer(address(this));
        vm.expectRevert();
        token.mint(address(0), 100);
        require(token.lifetimeMinted() == 0 && token.totalSupply() == 0, "atomic mint failure");
    }

    function testUnauthorizedIssuerChangeAndMintFail() public {
        vm.expectRevert();
        vm.prank(BOB);
        token.setIssuer(address(this));
        vm.expectRevert(ZoruToken.NotIssuer.selector);
        vm.prank(BOB);
        token.mint(BOB, 1);
    }

    function testFuzzMintSplitsNeverExceedLifetimeCap(uint128 a, uint128 b) public {
        token.setIssuer(address(this));
        uint256 first = uint256(a) % (token.MAX_SUPPLY() + 1);
        uint256 second = uint256(b) % (token.MAX_SUPPLY() - first + 1);
        token.mint(ALICE, first);
        token.mint(BOB, second);
        uint256 remainder = token.MAX_SUPPLY() - first - second;
        token.mint(ALICE, remainder);
        vm.expectRevert(ZoruToken.CapExceeded.selector);
        token.mint(BOB, 1);
        require(token.lifetimeMinted() == token.MAX_SUPPLY(), "exact cap");
        require(token.totalSupply() == token.lifetimeMinted(), "no burn/remint channel");
    }

    function testFuzzERC20AllowanceAndSupplyConservation(uint64 supplySeed, uint64 spendSeed) public {
        uint256 supply = uint256(supplySeed) % 1e12 + 1;
        uint256 spend = uint256(spendSeed) % (supply + 1);
        token.setIssuer(address(this));
        token.mint(ALICE, supply);
        vm.prank(ALICE);
        token.approve(BOB, spend);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, spend);
        require(token.balanceOf(ALICE) + token.balanceOf(BOB) == supply, "ERC20 conservation");
        require(token.allowance(ALICE, BOB) == 0, "allowance consumed");
        vm.expectRevert();
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 1);
        require(token.lifetimeMinted() == supply, "transfer cannot expand cap");
    }
}

contract ZoruLedgerAdversarialTest is AdversarialFixture {
    function testPastBeaconScheduleCannotBeUsedForFutureLedgerWork() public {
        upgradeMocks(engine, new MockBeacon(START - 60));
        vm.expectRevert(ZoruLedger.InvalidConfiguration.selector);
        ledger.submit(0, ALICE, 1);
        require(ledger.allocatedSupply() == 0, "precomputed old seed cannot allocate");
    }

    function testOwnerAppointedEngineCanApproveFakeWorkButBudgetStaysBounded() public {
        bytes32 digest = ledger.submit(0, ALICE, 1);
        require(uint256(digest) >= ledger.epochInfo(0).target, "insecure owner-appointed mock bypasses work");
        require(ledger.allocatedSupply() == 5e8, "fake share cannot expand period budget");
        // Explicit trust limitation; does not claim malicious-engine resistance.
    }

    function testLedgerHalvingScheduleAndTerminalResidueSumExactlyToCap() public view {
        uint256 sum;
        for (uint256 era; era < 29; era++) {
            sum += (uint256(5e8) >> era) * 2_100_000;
        }
        require(ledger.budgetForIndex(2_100_000 - 1) == 5e8, "before halving");
        require(ledger.budgetForIndex(2_100_000) == 25e7, "at halving");
        require(sum + ledger.budgetForIndex(29 * 2_100_000) == token.MAX_SUPPLY(), "exact issuance ceiling");
        require(ledger.budgetForIndex(29 * 2_100_000 + 1) == 0, "subsidy ends");
    }

    function testPartialTopUpMintsOnlyDeficit() public {
        token.setIssuer(address(this));
        token.mint(address(ledger), 2e8);
        token.setIssuer(address(ledger));
        ledger.submit(0, ALICE, 1);
        vm.warp(START + 60);
        ledger.seal(0);
        require(token.totalSupply() == 5e8 && ledger.fundedLiability() == 5e8, "only missing three coins minted");
    }

    function testFirstEverEmptyEpochRecoversEvenWithBeaconOutage() public {
        vm.warp(START - 1);
        ZoruLedger empty = makeLedger(token, new OutageBeacon(), 1);
        vm.warp(START);
        require(empty.openEpoch(0) == 1, "initial difficulty");
        vm.warp(START + 60);
        require(empty.openEpoch(1) == 4, "no proof required to recover");
        for (uint256 i; i < 10; i++) {
            require(empty.openEpoch(1) == 4, "one adjustment per epoch");
        }
        vm.warp(START + 60 * 1000);
        require(empty.openEpoch(1000) == empty.MAX_TARGET(), "saturating long recovery");
        require(empty.emissionIndex() == 0 && empty.allocatedSupply() == 0, "no empty rewards");
    }

    function testFirstProofDelayDoesNotSelectDifficulty() public {
        uint256 frozen = ledger.openEpoch(0);
        vm.warp(START + 59);
        ledger.submit(0, ALICE, 1);
        require(ledger.epochInfo(0).target == frozen, "first-proof timing cannot loosen target");
        require(ledger.openEpoch(0) == frozen, "repeat open cannot retarget");
    }

    function testTimestampBoundaryAndFinalSecondSpamConserveReward() public {
        vm.warp(START + 59);
        for (uint256 i; i < 64; i++) {
            ledger.submit(0, ALICE, i);
        }
        uint256 oldTarget = ledger.epochInfo(0).target;
        vm.warp(START + 60);
        vm.expectRevert(ZoruLedger.InvalidEpoch.selector);
        ledger.submit(0, BOB, 999);
        uint256 next = ledger.openEpoch(1);
        require(next == oldTarget * 60 / 64, "closed count, not first proof timestamp");
        bytes32 proof = ledger.submit(1, BOB, 2);
        ledger.seal(0);
        require(ledger.epochInfo(1).target == next, "settlement cannot change active work");
        require(ledger.allocatedSupply() == 10e8, "spam does not multiply budgets");
        require(proof != bytes32(0), "next epoch remains open");
    }

    function testInvalidProofDoesNotAllocateBudgetOrConsumeEmissionIndex() public {
        upgradeMocks(new RejectEngine(), beacon);
        vm.expectRevert(ZoruLedger.InvalidProof.selector);
        ledger.submit(0, ALICE, 1);
        require(ledger.totalProofs() == 0 && ledger.emissionIndex() == 0, "failed proof atomic");
        require(ledger.allocatedSupply() == 0 && token.totalSupply() == 0, "no emission");
    }

    function testGasGriefEngineCannotPreventImmediateRecovery() public {
        upgradeMocks(new GasGriefEngine(), beacon);
        vm.expectRevert();
        ledger.submit(0, ALICE, 1);
        upgradeMocks(engine, beacon);
        ledger.submit(0, ALICE, 1);
        require(ledger.totalProofs() == 1, "no wait for next epoch");
    }

    function testGasGriefBeaconCannotPreventClockProgressOrRecovery() public {
        upgradeMocks(engine, new GasGriefBeacon());
        ledger.openEpoch(0);
        vm.expectRevert();
        ledger.submit(0, ALICE, 1);
        upgradeMocks(engine, beacon);
        ledger.submit(0, ALICE, 1);
        require(ledger.totalProofs() == 1, "beacon recovery external to failed module");
    }

    function testMidEpochRecoveryKeepsOldProofsAndChangesGeneration() public {
        bytes32 a = ledger.submit(0, ALICE, 1);
        uint256 generation = ledger.epochInfo(0).generation;
        upgradeMocks(engine, beacon);
        bytes32 b = ledger.submit(0, ALICE, 1);
        require(a != b && ledger.epochInfo(0).generation > generation, "fresh work domain");
        vm.warp(START + 60);
        ledger.seal(0);
        require(ledger.claim(a) + ledger.claim(b) == 5e8, "old proof rights intact");
    }

    function testSchedulingAgainPreservesAlreadyActivatedModule() public {
        RejectEngine reject = new RejectEngine();
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = address(reject);
        coordinator.scheduleUpgrade(u);
        vm.warp(START + 60);
        coordinator.executeScheduledUpgrade();
        u.engineImplementation = address(new AlwaysAcceptEngine());
        coordinator.scheduleUpgrade(u);
        vm.expectRevert(ZoruLedger.InvalidProof.selector);
        ledger.submit(1, ALICE, 1);
        vm.warp(START + 120);
        coordinator.executeScheduledUpgrade();
        ledger.submit(2, ALICE, 1);
    }

    function testFrontRunnerCannotRedirectOriginalBeneficiary() public {
        vm.prank(BOB);
        bytes32 proof = ledger.submit(0, ALICE, 1);
        vm.expectRevert(ZoruLedger.DuplicateProof.selector);
        vm.prank(ALICE);
        ledger.submit(0, ALICE, 1);
        vm.warp(START + 60);
        ledger.seal(0);
        vm.prank(BOB);
        ledger.claim(proof);
        require(token.balanceOf(ALICE) == 5e8 && token.balanceOf(BOB) == 0, "copy is only sponsorship");
    }

    function testWrongChainAndContractHaveDifferentProofDomains() public {
        bytes32 seed = beacon.verifiedSeed(0);
        bytes32 original = ledger.digestFor(0, seed, ALICE, 1);
        vm.chainId(6737);
        require(original != ledger.digestFor(0, seed, ALICE, 1), "chain replay");
        vm.chainId(6736);
        vm.warp(START - 1);
        ZoruLedger other = makeLedger(token, beacon, 1 << 100);
        require(original != other.digestFor(0, seed, ALICE, 1), "deployment replay");
    }

    function testReentrantModuleCannotMutateClaimOrAccounting() public {
        upgradeMocks(new ReenterEngine(ledger), beacon);
        vm.expectRevert(ZoruLedger.InvalidProof.selector);
        ledger.submit(0, ALICE, 1);
        require(ledger.totalProofs() == 0 && ledger.paidSupply() == 0, "no reentrant payment");
    }

    function testPendingLiabilitiesConsumeRemainingMintCapacity() public {
        token.setIssuer(address(this));
        token.mint(BOB, token.MAX_SUPPLY() - 10e8);
        token.setIssuer(address(ledger));
        ledger.submit(0, ALICE, 1);
        vm.warp(START + 60);
        ledger.submit(1, BOB, 2);
        vm.warp(START + 120);
        vm.expectRevert(ZoruLedger.NoMoreEmission.selector);
        ledger.submit(2, BOB, 3);
        ledger.seal(1);
        ledger.seal(0);
        require(token.totalSupply() == token.MAX_SUPPLY(), "pending supply reserved locally");
    }

    function testDonatedBackingIsUsedOnceAndDoesNotDoubleMint() public {
        token.setIssuer(address(this));
        token.mint(address(ledger), 5e8);
        token.setIssuer(address(ledger));
        ledger.submit(0, ALICE, 1);
        vm.warp(START + 60);
        ledger.seal(0);
        require(token.totalSupply() == 5e8, "pre-funded epoch cannot mint twice");
        require(ledger.freeBalance() == 0 && ledger.fundedLiability() == 5e8, "backing encumbered");
    }

    function testCompromisedOwnerCanExhaustCapButCannotIncreaseIt() public {
        ledger.submit(0, ALICE, 1);
        token.setIssuer(address(this));
        token.mint(BOB, token.MAX_SUPPLY());
        vm.warp(START + 60);
        vm.expectRevert(ZoruLedger.FundingUnavailable.selector);
        ledger.seal(0);
        require(ledger.unfundedLiability() == 5e8, "recorded debt not erased");
        vm.expectRevert(ZoruToken.CapExceeded.selector);
        token.mint(BOB, 1);
        // Intentional demonstration of the direct-owner trust limitation.
    }

    function testFuzzClaimOrderAndRoundingConserveBudget(uint8 sizeSeed, uint64 nonceSeed) public {
        uint256 size = uint256(sizeSeed) % 40 + 1;
        bytes32[] memory ids = new bytes32[](size);
        for (uint256 i; i < size; i++) {
            ids[i] = ledger.submit(0, address(uint160(1000 + i)), uint256(nonceSeed) + i);
        }
        vm.warp(START + 60);
        ledger.seal(0);
        uint256 sum;
        for (uint256 i = size; i != 0;) {
            i--;
            sum += ledger.claim(ids[i]);
        }
        require(sum == 5e8 && ledger.fundedLiability() == 0, "exact telescoping distribution");
        require(token.balanceOf(address(ledger)) == 0, "no rounding dust lost");
    }

    function testFuzzTargetRecoversWithoutOverflow(uint8 skippedSeed) public {
        uint256 skipped = uint256(skippedSeed) + 1;
        vm.warp(START + 60 * skipped);
        uint256 target = ledger.openEpoch(uint48(skipped));
        require(target >= (1 << 100) && target <= ledger.MAX_TARGET(), "bounded recovery");
        require(ledger.openEpoch(uint48(skipped)) == target, "no intra-epoch amplification");
    }
}

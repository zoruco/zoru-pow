// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {SuiteSupport} from "./SuiteSupport.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruKeccakEngine} from "../src/ZoruKeccakEngine.sol";
import {IZoruWorkEngine, IZoruBeaconSource} from "../src/IZoruMining.sol";
import {MockBeacon} from "./MockBeacon.sol";

interface Vm {
    function warp(uint256) external;
    function chainId(uint256) external;
    function prank(address) external;
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
}

/// @notice TEST-ONLY mock accepts any digest. Does NOT establish cryptographic
///         mining security; used to test accounting and liveness invariants.
contract AlwaysAcceptEngine is IZoruWorkEngine {
    function valid(bytes32, uint256) external pure returns (bool) {
        return true;
    }
}

contract RejectEngine is IZoruWorkEngine {
    function valid(bytes32, uint256) external pure returns (bool) {
        return false;
    }
}

contract TestFutureIssuer {
    ZoruToken private immutable zoru;

    constructor(ZoruToken token_) {
        zoru = token_;
    }

    function mint(address recipient, uint256 amount) external {
        zoru.mint(recipient, amount);
    }
}

contract ZoruProtocolTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    ZoruToken token;
    ZoruLedger ledger;
    ZoruAdminAdapter coordinator;
    MockBeacon beacon;
    AlwaysAcceptEngine engine;
    uint256 start = 1_800_000_000;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA10);

    function setUp() public {
        vm.chainId(6736);
        vm.warp(start - 5);
        token = new ZoruToken(address(this));
        address work;
        address source;
        (ledger, coordinator, work, source) = SuiteSupport.mockSuite(
            token, address(new MockBeacon(start)), address(new AlwaysAcceptEngine()), start, ledgerSafeTarget()
        );
        engine = AlwaysAcceptEngine(work);
        beacon = MockBeacon(source);
        vm.warp(start + 1);
    }

    function ledgerSafeTarget() internal pure returns (uint256) {
        return type(uint256).max >> 16;
    }

    event GasSample(string label, uint256 gasUsed);

    function testGasSamplesLocalEvmOnly() public {
        uint256 beforeGas = gasleft();
        bytes32 proofA = ledger.submit(0, alice, 123);
        emit GasSample("firstProofInEpoch", beforeGas - gasleft());
        beforeGas = gasleft();
        ledger.submit(0, bob, 456);
        emit GasSample("additionalProofInEpoch", beforeGas - gasleft());
        vm.warp(start + 61);
        beforeGas = gasleft();
        ledger.seal(0);
        emit GasSample("sealEpochWithMint", beforeGas - gasleft());
        beforeGas = gasleft();
        ledger.claim(proofA);
        emit GasSample("claimOneProof", beforeGas - gasleft());
    }

    function testExtremeDifficultyCannotOverflowTelemetryAndBlockMiners() public {
        ZoruToken isolated = new ZoruToken(address(this));
        (ZoruLedger lowTarget,,,) = SuiteSupport.mockSuite(
            isolated, address(new MockBeacon(start + 60)), address(new AlwaysAcceptEngine()), start + 60, 1
        );
        vm.warp(start + 61);
        lowTarget.submit(0, alice, 1);
        lowTarget.submit(0, bob, 2);
        require(lowTarget.totalProofs() == 2, "must not revert on work overflow");
        require(lowTarget.networkWorkEstimate() == type(uint256).max, "saturated estimate");
        require(lowTarget.epochInfo(0).verifiedWorkEstimate == type(uint256).max, "per epoch saturated");
    }

    function testRustAndSolidityKeccakPreimageVectorMatches() public pure {
        bytes32 seed = hex"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        bytes32 digest = keccak256(
            abi.encode(
                keccak256(bytes("ZORU-FLOWPOW-PROOF-1")),
                uint256(6736),
                address(0x1111111111111111111111111111111111111111),
                address(0x2222222222222222222222222222222222222222),
                uint256(1),
                uint48(7),
                seed,
                address(0x3333333333333333333333333333333333333333),
                uint256(123456)
            )
        );
        require(digest == hex"963264d99ac63fe196f59276394a9cbc64aa513fcbd6f33e8bfb5ae90221ea92", "Rust mismatch");
    }

    function testTokenEightDecimalsAndExactCap() public view {
        require(token.decimals() == 8, "decimals");
        require(token.MAX_SUPPLY() == 21_000_000 * 1e8, "cap");
        require(token.totalSupply() == 0, "genesis supply");
        require(ledger.INITIAL_BUDGET() == 5 * 1e8, "budget");
        require(ledger.TERMINAL_DUST() == 27_300_000, "dust");
        require(ledger.NORMAL_ERAS() == 29, "era count");
    }

    function testMultiMinerProofsAcceptedInSameEpochAndPermissionlessClaim() public {
        vm.prank(alice);
        bytes32 a = ledger.submit(0, alice, 1);
        vm.prank(bob);
        bytes32 b = ledger.submit(0, bob, 2);
        vm.prank(carol);
        bytes32 c = ledger.submit(0, carol, 3);

        ZoruLedger.Epoch memory e = ledger.epochInfo(0);
        require(e.proofCount == 3, "must accept 3 proofs");
        require(token.totalSupply() == 0, "mint should be delayed until seal");
        require(ledger.totalProofs() == 3, "total verified proofs");

        vm.warp(start + 61);
        ledger.seal(0);
        require(token.totalSupply() == 5 * 1e8, "mint exactly once");
        uint256 a0 = ledger.claim(a);
        uint256 b0 = ledger.claim(b);
        uint256 c0 = ledger.claim(c);
        require(a0 + b0 + c0 == 5 * 1e8, "conservation");
        require(token.balanceOf(alice) == a0, "beneficiary A");
        require(token.balanceOf(bob) == b0, "beneficiary B");
        require(token.balanceOf(carol) == c0, "beneficiary C");
        require(token.balanceOf(address(ledger)) == 0, "escrow drained");
    }

    function testNewEpochDoesNotWaitForPreviousSeal() public {
        bytes32 a = ledger.submit(0, alice, 1);
        vm.warp(start + 61);
        bytes32 b = ledger.submit(1, bob, 2);
        require(ledger.totalProofs() == 2, "continuous admission");
        require(token.totalSupply() == 0, "no settlement required");
        ledger.seal(0);
        require(token.balanceOf(alice) == 0, "claim required");
        vm.warp(start + 121);
        ledger.seal(1);
        require(ledger.claim(a) == 5 * 1e8 && ledger.claim(b) == 5 * 1e8, "both paid");
        require(token.totalSupply() == 10 * 1e8, "only 2 emissions");
    }

    function testDuplicateClaimAndProofRejected() public {
        bytes32 a = ledger.submit(0, alice, 55);
        vm.expectRevert(ZoruLedger.DuplicateProof.selector);
        ledger.submit(0, alice, 55);
        vm.expectRevert(ZoruLedger.EpochNotClosed.selector);
        ledger.seal(0);
        vm.expectRevert(ZoruLedger.NotClaimable.selector);
        ledger.claim(a);
        vm.warp(start + 61);
        ledger.seal(0);
        vm.expectRevert(ZoruLedger.AlreadySealed.selector);
        ledger.seal(0);
        ledger.claim(a);
        vm.expectRevert(ZoruLedger.NotClaimable.selector);
        ledger.claim(a);
    }

    function testNoEmissionOnEmptyRoundsAndDifficultyRecovery() public {
        vm.warp(start + 60 * 1000 + 1);
        require(ledger.epochNow() == 1000, "epoch arithmetic");
        require(ledger.emissionIndex() == 0, "empty epochs do not emit");
        ledger.submit(1000, alice, 1);
        require(ledger.emissionIndex() == 1, "one emission round");
        vm.warp(start + 60 * 1001 + 1);
        ledger.submit(1001, bob, 2);
        require(ledger.emissionIndex() == 2, "second emission round");
        require(ledger.epochInfo(1001).target >= 1, "target valid");
    }

    function testEmergencyPauseKeepsOldClaimsAvailable() public {
        bytes32 a = ledger.submit(0, alice, 1);
        ledger.setAdmissionPaused(true);
        vm.expectRevert(ZoruLedger.Paused.selector);
        ledger.submit(0, bob, 2);
        vm.warp(start + 61);
        ledger.seal(0);
        ledger.claim(a);
        require(token.balanceOf(alice) == 5 * 1e8, "claims survive mining pause");
    }

    function testAppointedIssuerCanMintWithoutEpochPolicyButNeverExceedCap() public {
        vm.expectRevert(ZoruToken.NotIssuer.selector);
        token.mint(alice, 1);
        token.setIssuer(address(this));
        token.mint(alice, 123);
        token.mint(bob, 777);
        vm.warp(start - 100);
        token.mint(alice, 100); // Token has no launch/spacing/halving clock.
        token.mint(bob, token.MAX_SUPPLY() - 1000);
        vm.expectRevert(ZoruToken.CapExceeded.selector);
        token.mint(alice, 1);
        require(token.totalSupply() == token.MAX_SUPPLY(), "hard cap");
        require(token.lifetimeMinted() == token.MAX_SUPPLY(), "lifetime cap");
    }

    /// @notice Wallet multiplication alone does not increase reward when the
    /// number of accepted proofs is kept equal. This uses an insecure PoW mock
    /// deliberately to isolate identity/sybil accounting from hash difficulty.
    function testSybilOneHundredWalletsVersusOneWalletSameAcceptedWork() public {
        uint256 proofEach = 100;
        bytes32[] memory oneWalletProofs = new bytes32[](proofEach);
        bytes32[] memory manyWalletProofs = new bytes32[](proofEach);
        uint256 i;
        for (i = 0; i < proofEach; i++) {
            oneWalletProofs[i] = ledger.submit(0, alice, i + 1000);
            address cloneAddress = address(uint160(0xF0000 + i));
            manyWalletProofs[i] = ledger.submit(0, cloneAddress, i + 2000);
        }
        ZoruLedger.Epoch memory e = ledger.epochInfo(0);
        // 101 addresses, but that is not proof of 101 independent humans.
        require(e.proofCount == 2 * proofEach, "equal accepted work");
        vm.warp(start + 61);
        ledger.seal(0);
        uint256 oneWalletReward;
        uint256 manyWalletReward;
        for (i = 0; i < proofEach; i++) {
            oneWalletReward += ledger.claim(oneWalletProofs[i]);
            manyWalletReward += ledger.claim(manyWalletProofs[i]);
        }
        require(oneWalletReward == manyWalletReward, "wallet multiplication must not increase expected/proof payout");
        require(oneWalletReward == (5 * 1e8) / 2, "half period budget");
        // 101 beneficiary addresses are visible through ProofAccepted logs,
        // but NOT stored as an inflated on-chain "miner count".
        require(ledger.totalProofs() == 2 * proofEach, "only counted real proof events");
        require(token.totalSupply() == 5 * 1e8, "single emission");
    }

    function testFundedClaimsSurviveIssuerRotationAndUnfundedEpochNeedsTopUp() public {
        bytes32 fundedProof = ledger.submit(0, alice, 55);
        vm.warp(start + 61);
        ledger.seal(0);
        bytes32 pendingProof = ledger.submit(1, bob, 66);
        TestFutureIssuer next = new TestFutureIssuer(token);
        token.setIssuer(address(next));
        vm.expectRevert(ZoruLedger.InactiveIssuer.selector);
        ledger.submit(1, carol, 77);
        vm.warp(start + 121);
        vm.expectRevert(ZoruLedger.FundingUnavailable.selector);
        ledger.seal(1); // Cannot reuse the funded first epoch's backing.
        require(!ledger.epochInfo(1).isSealed, "failed funding must be atomic");
        require(ledger.fundedLiability() == 5 * 1e8, "old backing protected");
        require(ledger.claim(fundedProof) == 5 * 1e8, "funded claim survives revocation");
        next.mint(address(ledger), 5 * 1e8);
        ledger.seal(1); // Recovered with actual tokens, no old mint privilege.
        require(ledger.claim(pendingProof) == 5 * 1e8, "top-up funds pending claim");
        require(token.totalSupply() == 10 * 1e8, "no double mint on seal");
        require(ledger.fundedLiability() == 0, "fully paid");
    }

    function testKernelBoundary() public {
        ZoruKeccakEngine realEngine = new ZoruKeccakEngine();
        require(realEngine.valid(bytes32(uint256(2)), 3), "2 < 3");
        require(!realEngine.valid(bytes32(uint256(3)), 3), "3 !< 3");
    }

    function testModuleSwitchOnlyAffectsNextEpoch() public {
        bytes32 oldProof = ledger.submit(0, alice, 1);
        RejectEngine reject = new RejectEngine();
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = address(reject);
        coordinator.scheduleUpgrade(u);
        ledger.submit(0, bob, 2); // existing epoch engine frozen
        vm.warp(start + 61);
        coordinator.executeScheduledUpgrade();
        vm.expectRevert(ZoruLedger.InvalidProof.selector);
        ledger.submit(1, carol, 3);
        ledger.seal(0);
        require(ledger.claim(oldProof) > 0, "past work safe");
    }

    function testProofIsBoundToBeneficiaryAndEpoch() public view {
        bytes32 seed = beacon.verifiedSeed(0);
        bytes32 aa = ledger.digestFor(0, seed, alice, 1);
        bytes32 bb = ledger.digestFor(0, seed, bob, 1);
        bytes32 ee = ledger.digestFor(1, seed, alice, 1);
        require(aa != bb && aa != ee, "wallet and epoch binding");
    }
}

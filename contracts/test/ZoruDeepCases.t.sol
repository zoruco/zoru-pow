// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {AdversarialFixture} from "./ZoruAdversarial.t.sol";
import {DeepTestPanic, DeepTestNoReturn, DeepTestGasLoop} from "./DeepTestHarness.sol";

contract ShortEngineReturn {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 31)
        }
    }
}

contract NonCanonicalBoolEngine {
    fallback() external {
        assembly {
            mstore(0, 2)
            return(0, 32)
        }
    }
}

contract ZoruDeepCasesTest is AdversarialFixture {
    function _fault(address impl) internal {
        address original = coordinator.implementationOf(address(engine));
        uint256 allocated = ledger.allocatedSupply();
        uint256 count = ledger.totalProofs();
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = impl;
        coordinator.emergencyUpgrade(u);
        (bool ok,) = address(ledger).call(abi.encodeCall(ZoruLedger.submit, (uint48(0), ALICE, uint256(10))));
        require(
            !ok && ledger.allocatedSupply() == allocated && ledger.totalProofs() == count,
            "fault must roll back admission"
        );
        u.engineImplementation = original;
        coordinator.emergencyUpgrade(u);
        ledger.submit(0, ALICE, 10);
        require(ledger.totalProofs() == count + 1, "external recovery still admits work");
    }

    function testPanicEngineRecoveryDoesNotLoseAccounting() public {
        _fault(address(new DeepTestPanic()));
    }

    function testNoReturnEngineRecoveryDoesNotLoseAccounting() public {
        _fault(address(new DeepTestNoReturn()));
    }

    function testShortReturnEngineRecoveryDoesNotLoseAccounting() public {
        _fault(address(new ShortEngineReturn()));
    }

    function testInvalidBoolEngineRecoveryDoesNotLoseAccounting() public {
        _fault(address(new NonCanonicalBoolEngine()));
    }

    function testGasLoopEngineRecoveryDoesNotLoseAccounting() public {
        _fault(address(new DeepTestGasLoop()));
    }

    function testTrailingBytesCannotBypassProofDeduplicationAndShortCalldataIsRejected() public {
        bytes32 accepted = ledger.submit(0, ALICE, 7);
        bytes memory duplicate =
            bytes.concat(abi.encodeCall(ZoruLedger.submit, (uint48(0), ALICE, uint256(7))), hex"deadbeef");
        (bool ok,) = address(ledger).call(duplicate);
        require(!ok && ledger.totalProofs() == 1 && ledger.emissionIndex() == 1, "ABI suffix cannot create new proof");
        (ok,) = address(ledger).call(abi.encodePacked(ZoruLedger.submit.selector, bytes32(uint256(0))));
        require(!ok && ledger.totalProofs() == 1, "short ABI cannot corrupt proof");
        vm.warp(START + 60);
        ledger.seal(0);
        vm.expectRevert();
        ledger.seal(0);
        ledger.claim(accepted);
        vm.expectRevert();
        ledger.claim(accepted);
        require(token.balanceOf(ALICE) == 5e8 && ledger.paidSupply() == 5e8, "seal/claim exactly once");
    }

    function testSameNonceDifferentBeneficiaryAndEpochAreDistinctValidWork() public {
        bytes32 a = ledger.submit(0, ALICE, 7);
        bytes32 b = ledger.submit(0, BOB, 7);
        require(a != b, "beneficiary domain");
        vm.warp(START + 60);
        bytes32 c = ledger.submit(1, ALICE, 7);
        require(a != c && b != c, "epoch domain");
        vm.expectRevert();
        ledger.submit(0, ALICE, 7);
        require(ledger.totalProofs() == 3 && ledger.emissionIndex() == 2, "unique work, two epoch budgets");
    }

    function testEmptySealAndRepeatedOpenOrSchedulingDoNotCreateEmission() public {
        ledger.openEpoch(0);
        ledger.openEpoch(0);
        uint256 target = ledger.epochInfo(0).target;
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = coordinator.implementationOf(address(engine));
        coordinator.scheduleUpgrade(u);
        coordinator.scheduleUpgrade(u);
        coordinator.cancelUpgrade();
        coordinator.cancelUpgrade();
        require(ledger.epochInfo(0).target == target && ledger.emissionIndex() == 0, "idempotent opens and plans");
        vm.warp(START + 60);
        vm.expectRevert();
        ledger.seal(0);
        require(token.totalSupply() == 0 && ledger.allocatedSupply() == 0, "no empty subsidy");
    }

    function testSettledClaimRemainsSettledAcrossLedgerEngineBeaconRollback() public {
        bytes32 proof = ledger.submit(0, ALICE, 1);
        vm.warp(START + 60);
        ledger.seal(0);
        ledger.claim(proof);
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = coordinator.implementationOf(address(ledger));
        u.engineImplementation = coordinator.implementationOf(address(engine));
        u.beaconImplementation = coordinator.implementationOf(address(beacon));
        coordinator.emergencyUpgrade(u);
        coordinator.emergencyUpgrade(u);
        vm.expectRevert();
        ledger.claim(proof);
        require(
            token.balanceOf(ALICE) == 5e8 && ledger.paidSupply() == 5e8 && ledger.fundedLiability() == 0,
            "settled reward never paid twice"
        );
    }

    function testFuzzDuplicateSenderAndCalldataSuffixDoNotAlterAccounting(uint256 nonce, bytes8 suffix) public {
        bytes32 accepted = ledger.submit(0, ALICE, nonce);
        vm.prank(BOB);
        (bool ok,) =
            address(ledger).call(bytes.concat(abi.encodeCall(ZoruLedger.submit, (uint48(0), ALICE, nonce)), suffix));
        require(
            !ok && ledger.totalProofs() == 1 && ledger.emissionIndex() == 1 && ledger.allocatedSupply() == 5e8,
            "dedupe economic state"
        );
        vm.warp(START + 60);
        ledger.seal(0);
        ledger.claim(accepted);
        require(token.balanceOf(BOB) == 0 && token.balanceOf(ALICE) == 5e8, "copier cannot redirect payout");
    }

    /// @notice In-memory accounting test with mock work, NOT 10K signed VEX tx.
    function testTenThousandSybilWalletsReceiveOnlyTheirAcceptedWorkShare() public {
        uint256 n = 10_000;
        bytes32[] memory single = new bytes32[](n);
        bytes32[] memory split = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            single[i] = ledger.submit(0, ALICE, i);
            split[i] = ledger.submit(0, address(uint160(0xF00000 + i)), i);
        }
        require(ledger.totalProofs() == 2 * n && ledger.emissionIndex() == 1, "All proofs must share one epoch budget");
        vm.warp(START + 60);
        ledger.seal(0);
        uint256 one;
        uint256 many;
        for (uint256 i; i < n; ++i) {
            one += ledger.claim(single[i]);
            many += ledger.claim(split[i]);
        }
        require(
            one == 250_000_000 && many == one && ledger.paidSupply() == 500_000_000,
            "Splitting proofs across wallets must not change the total reward"
        );
        require(ledger.fundedLiability() == 0 && token.totalSupply() == 500_000_000, "All claims must settle the funded epoch");
    }
}

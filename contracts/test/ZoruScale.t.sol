// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {SuiteSupport} from "./SuiteSupport.sol";
import {MockBeacon} from "./MockBeacon.sol";
import {AlwaysAcceptEngine} from "./ZoruProtocol.t.sol";

interface ScaleVm {
    function warp(uint256) external;
    function chainId(uint256) external;
}

/// @notice Accounting scale only. Real native RAM and cryptography are tested separately.
contract ZoruScaleTest {
    ScaleVm private constant vm = ScaleVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant START = 1_800_000_000;

    function _scale(uint256 count) private {
        vm.chainId(6736);
        vm.warp(START - 1);
        ZoruToken token = new ZoruToken(address(this));
        (ZoruLedger ledger,,,) = SuiteSupport.mockSuite(
            token, address(new MockBeacon(START)), address(new AlwaysAcceptEngine()), START, type(uint256).max >> 16
        );
        vm.warp(START + 1);
        bytes32[] memory digests = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            digests[i] = ledger.submit(0, address(uint160(100 + i % 4)), i);
        }
        require(ledger.totalProofs() == count && ledger.epochInfo(0).proofCount == count, "proof count");
        require(ledger.allocatedSupply() == 500_000_000 && token.totalSupply() == 0, "allocation");
        vm.warp(START + 61);
        ledger.seal(0);
        for (uint256 i; i < count; ++i) ledger.claim(digests[i]);
        require(ledger.fundedSupply() == 500_000_000 && ledger.paidSupply() == 500_000_000, "reward partition");
        require(ledger.fundedLiability() == 0 && ledger.unfundedLiability() == 0, "liabilities");
        require(token.balanceOf(address(ledger)) == 0 && token.totalSupply() == 500_000_000, "supply");
        uint256 balances;
        for (uint256 i; i < 4; ++i) balances += token.balanceOf(address(uint160(100 + i)));
        require(balances == 500_000_000, "beneficiaries");
        (bool ok,) = address(ledger).call(abi.encodeCall(ZoruLedger.claim, (digests[count - 1])));
        require(!ok, "duplicate claim");
    }

    function test100ProofsAndClaims() public { _scale(100); }
    function test1000ProofsAndClaims() public { _scale(1_000); }
    function test10000ProofsAndClaims() public { _scale(10_000); }
    function test20000ProofsAndClaims() public { _scale(20_000); }
}

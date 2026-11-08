// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;
import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
interface ForkVm {
    function envAddress(string calldata) external returns (address);
    function envBytes32(string calldata) external returns (bytes32);
    function warp(uint256) external;
    function prank(address) external;
    function expectRevert(bytes4) external;
}
/// @notice Run ONLY on a pinned, local Foundry mainnet fork. No keys or broadcasts.
contract ContinuityForkTest {
    ForkVm constant vm = ForkVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    struct Checkpoint { bytes32 proof; bytes32 epoch; bytes32 totals; uint256 generation; }
    function proofHash(ZoruLedger ledger, bytes32 digest) internal view returns (bytes32) {
        (address who, uint48 epoch, uint256 index, bool claimed) = ledger.proofs(digest);
        return keccak256(abi.encode(who, epoch, index, claimed));
    }
    function totals(ZoruLedger ledger, ZoruToken token) internal view returns (bytes32) {
        return keccak256(abi.encode(ledger.allocatedSupply(), ledger.fundedSupply(), ledger.paidSupply(),
            ledger.totalProofs(), token.totalSupply(), token.lifetimeMinted()));
    }
    function testScheduledUpgradePreservesActualMainnetProofAndPaysItsBeneficiary() public {
        require(block.chainid == 6736, "wrong fork identity");
        ZoruToken token = ZoruToken(vm.envAddress("ZORU_FORK_TOKEN"));
        ZoruLedger ledger = ZoruLedger(vm.envAddress("ZORU_FORK_LEDGER"));
        ZoruAdminAdapter admin = ZoruAdminAdapter(vm.envAddress("ZORU_FORK_ADMIN"));
        bytes32 digest = vm.envBytes32("ZORU_FORK_PROOF");
        (address who, uint48 epoch, uint256 index, bool claimed) = ledger.proofs(digest);
        require(who != address(0) && index > 0 && !claimed, "choose a real unclaimed proof");
        Checkpoint memory before = Checkpoint(proofHash(ledger, digest), keccak256(abi.encode(ledger.epochInfo(epoch))),
            totals(ledger, token), ledger.moduleGeneration());
        address owner = token.owner();
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = address(new ZoruLedger());
        vm.prank(owner);
        admin.scheduleUpgrade(u);
        vm.warp(admin.activationTime() + 1);
        admin.executeScheduledUpgrade();
        require(token.owner() == owner && token.issuer() == address(ledger), "authority remains fixed");
        require(ledger.protocolAdmin() == address(admin) && !admin.recoveryRequired(), "healthy checkpoint");
        require(ledger.moduleGeneration() == before.generation + 1, "one generation change");
        require(ledger.ROLLOVER_GRACE_SECONDS() == 30, "new rules active");
        require(proofHash(ledger, digest) == before.proof, "accepted proof unchanged");
        require(keccak256(abi.encode(ledger.epochInfo(epoch))) == before.epoch, "historical epoch unchanged");
        require(totals(ledger, token) == before.totals, "upgrade cannot mint or rewrite accounting");
        ZoruLedger.Epoch memory historical = ledger.epochInfo(epoch);
        if (!historical.isSealed) ledger.seal(epoch);
        uint256 expected = historical.budget * index / historical.proofCount
            - historical.budget * (index - 1) / historical.proofCount;
        uint256 balance = token.balanceOf(who);
        require(ledger.claim(digest) == expected, "exact entitlement");
        require(token.balanceOf(who) == balance + expected, "original beneficiary paid");
        vm.expectRevert(ZoruLedger.NotClaimable.selector);
        ledger.claim(digest);
        require(token.lifetimeMinted() <= token.MAX_SUPPLY(), "immutable supply cap");
    }
}

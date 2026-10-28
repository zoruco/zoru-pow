// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {AlwaysAcceptEngine} from "./ZoruProtocol.t.sol";
import {AdversarialFixture} from "./ZoruAdversarial.t.sol";

/// @dev Minimal mock threshold executor, NOT a production multisig implementation.
/// It tests the ZORU owner-address contract interface without adopting a wallet vendor.
contract MockThreeOfFiveOwner {
    mapping(address => bool) public signer;
    mapping(bytes32 => mapping(address => bool)) public approved;
    uint256 public nonce;

    constructor(address[5] memory signers) {
        for (uint256 i; i < 5; ++i) {
            require(signers[i] != address(0) && !signer[signers[i]], "distinct signers");
            signer[signers[i]] = true;
        }
    }

    function proposal(address target, bytes calldata data) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), nonce, target, keccak256(data)));
    }

    function approve(address target, bytes calldata data) external {
        require(signer[msg.sender], "not signer");
        bytes32 id = proposal(target, data);
        require(!approved[id][msg.sender], "duplicate");
        approved[id][msg.sender] = true;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        bytes32 id = proposal(target, data);
        uint256 approvals;
        for (uint256 i = 0; i < 5; ++i) {
            address actor = address(uint160(0x5100 + i));
            if (approved[id][actor]) ++approvals;
        }
        require(approvals >= 3, "3 of 5 required");
        nonce++;
        (bool ok, bytes memory output) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(output, 32), mload(output))
            }
        }
        return output;
    }
}

contract ZoruFutureMultisigOwnershipTest is AdversarialFixture {
    MockThreeOfFiveOwner multisig;

    function setUp() public override {
        super.setUp();
        address[5] memory signers;
        for (uint160 i; i < 5; ++i) signers[i] = address(0x5100 + i);
        multisig = new MockThreeOfFiveOwner(signers);
    }

    function _approve(address target, bytes memory data, uint160 signerIndex) internal {
        vm.prank(address(0x5100 + signerIndex));
        multisig.approve(target, data);
    }

    function testOwnerCanLaterMoveToThreeOfFiveWithoutChangingTokenOrProxy() public {
        bytes32 proof = ledger.submit(0, ALICE, 1);
        address existingOwner = token.owner();
        address oldIssuer = token.issuer();
        address oldCoordinator = address(coordinator);
        address oldLedger = address(ledger);
        address oldEngine = address(engine);
        address oldBeacon = address(beacon);

        token.transferOwnership(address(multisig));
        require(token.owner() == existingOwner && token.pendingOwner() == address(multisig),
            "transfer pending until 3-of-5 accepts");

        bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
        _approve(address(token), accept, 0);
        _approve(address(token), accept, 1);
        vm.expectRevert();
        multisig.execute(address(token), accept);
        vm.prank(address(0x5099));
        vm.expectRevert();
        multisig.approve(address(token), accept);
        _approve(address(token), accept, 2);
        multisig.execute(address(token), accept);

        require(token.owner() == address(multisig) && token.pendingOwner() == address(0),
            "multisig now sole token owner");
        require(token.issuer() == oldIssuer && address(coordinator) == oldCoordinator
            && address(ledger) == oldLedger && address(engine) == oldEngine
            && address(beacon) == oldBeacon, "addresses and issuer unchanged");

        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = address(new AlwaysAcceptEngine());
        vm.expectRevert(ZoruAdminAdapter.OnlyOwner.selector);
        coordinator.emergencyUpgrade(u);
        vm.prank(address(0x5101));
        vm.expectRevert(ZoruAdminAdapter.OnlyOwner.selector);
        coordinator.emergencyUpgrade(u);

        bytes memory upgrade = abi.encodeCall(ZoruAdminAdapter.emergencyUpgrade, (u));
        _approve(address(coordinator), upgrade, 0);
        _approve(address(coordinator), upgrade, 1);
        vm.expectRevert();
        multisig.execute(address(coordinator), upgrade);
        _approve(address(coordinator), upgrade, 3);
        multisig.execute(address(coordinator), upgrade);

        require(coordinator.suiteRevision() == 2 && !coordinator.recoveryRequired(),
            "owner-approved upgrade executed under threshold");
        require(token.owner() == address(multisig) && token.issuer() == oldIssuer,
            "multisig retains complete authority without issuer changes");

        vm.warp(START + 60);
        ledger.seal(0);
        require(ledger.claim(proof) == 5e8, "previously accepted reward survives owner transfer");
    }

    function testThreeOfFiveExecutorPreventsDuplicateApprovalAndOldProposalReplay() public {
        token.transferOwnership(address(multisig));
        bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
        _approve(address(token), accept, 0);
        vm.prank(address(0x5100));
        vm.expectRevert();
        multisig.approve(address(token), accept);
        _approve(address(token), accept, 1);
        _approve(address(token), accept, 2);
        multisig.execute(address(token), accept);
        require(token.owner() == address(multisig), "approved ownership acceptance");
        vm.expectRevert();
        multisig.execute(address(token), accept);
    }
}

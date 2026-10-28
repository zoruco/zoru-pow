// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {SuiteSupport} from "./SuiteSupport.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockBeacon} from "./MockBeacon.sol";
import {AlwaysAcceptEngine} from "./ZoruProtocol.t.sol";

interface InvariantVm {
    function warp(uint256) external;
    function chainId(uint256) external;
}

/// @notice Stateful accounting model on real contract bytecode. Uses an
/// always-accept engine; it tests liabilities/operations, not PoW hardness.
contract ZoruHandler {
    InvariantVm constant vm = InvariantVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant START = 1_800_000_000;
    ZoruToken public token;
    ZoruLedger public ledger;
    ZoruAdminAdapter public coordinator;
    MockBeacon public beacon;
    AlwaysAcceptEngine public engine;
    bytes32[] public ids;
    uint256 public nonce;
    uint256 public ghostPaid;

    constructor() {
        vm.chainId(6736);
        vm.warp(START - 10);
        token = new ZoruToken(address(this));
        address e;
        address b;
        (ledger, coordinator, e, b) = SuiteSupport.mockSuite(
            token, address(new MockBeacon(START)), address(new AlwaysAcceptEngine()), START, uint256(1 << 100)
        );
        engine = AlwaysAcceptEngine(e);
        beacon = MockBeacon(b);
        vm.warp(START);
    }

    function stepSubmit(uint8 beneficiary) external {
        if (token.issuer() != address(ledger)) return;
        if (!coordinator.workActive(ledger.epochNow(), ledger.moduleGeneration())) return;
        ids.push(ledger.submit(ledger.epochNow(), address(uint160(1000 + uint256(beneficiary))), nonce++));
    }

    function stepAdvance(uint8 secondsSeed) external {
        vm.warp(block.timestamp + 1 + uint256(secondsSeed) % 180);
    }

    function stepSeal(uint8 lookback) external {
        uint256 current = ledger.epochNow();
        if (current == 0) return;
        try ledger.seal(uint48(current - 1 - uint256(lookback) % current)) {} catch {}
    }

    function stepClaim(uint16 index) external {
        if (ids.length == 0) return;
        try ledger.claim(ids[uint256(index) % ids.length]) returns (uint256 paid) {
            ghostPaid += paid;
        } catch {}
    }

    function stepIssuer(bool revoke) external {
        token.setIssuer(revoke ? address(0) : address(ledger));
    }

    function stepTopUp(uint64 amountSeed) external {
        uint256 remaining = token.MAX_SUPPLY() - token.lifetimeMinted();
        uint256 amount = uint256(amountSeed) % 1e8;
        if (amount > remaining) amount = remaining;
        token.setIssuer(address(this));
        token.mint(address(ledger), amount);
        token.setIssuer(address(ledger));
    }

    function stepRecover() external {
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = address(new AlwaysAcceptEngine());
        coordinator.emergencyUpgrade(u);
    }

    function stepSchedule() external {
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = address(new AlwaysAcceptEngine());
        coordinator.scheduleUpgrade(u);
    }

    function stepExecute() external {
        if (coordinator.hasPendingUpgrade() && block.timestamp >= coordinator.activationTime()) {
            coordinator.executeScheduledUpgrade();
        }
    }

    function drain() external {
        coordinator.cancelUpgrade();
        token.setIssuer(address(ledger));
        vm.warp(START + (uint256(ledger.epochNow()) + 1) * 60);
        for (uint256 i; i < ids.length; i++) {
            (, uint48 epoch,,) = ledger.proofs(ids[i]);
            try ledger.seal(epoch) {} catch {}
            try ledger.claim(ids[i]) returns (uint256 paid) {
                ghostPaid += paid;
            } catch {}
        }
        require(ledger.paidSupply() == ledger.allocatedSupply(), "every accepted proof remains payable");
        require(ledger.fundedLiability() == 0 && ledger.unfundedLiability() == 0, "all liabilities drain");
    }
}

contract ZoruStatefulInvariantTest {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }
    ZoruHandler handler;

    function setUp() public {
        handler = new ZoruHandler();
    }

    function targetContracts() external view returns (address[] memory contracts_) {
        contracts_ = new address[](1);
        contracts_[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory selectors_) {
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.stepSubmit.selector;
        selectors[1] = handler.stepAdvance.selector;
        selectors[2] = handler.stepSeal.selector;
        selectors[3] = handler.stepClaim.selector;
        selectors[4] = handler.stepIssuer.selector;
        selectors[5] = handler.stepTopUp.selector;
        selectors[6] = handler.stepRecover.selector;
        selectors[7] = handler.stepSchedule.selector;
        selectors[8] = handler.stepExecute.selector;
        selectors_ = new FuzzSelector[](1);
        selectors_[0] = FuzzSelector(address(handler), selectors);
    }

    function invariantCapLiabilitiesBackingAndPaidConservation() public view {
        ZoruToken t = handler.token();
        ZoruLedger l = handler.ledger();
        ZoruAdminAdapter c = handler.coordinator();
        require(
            c.ledgerProxy() == address(l) && c.engineProxy() == address(l.engine())
                && c.beaconProxy() == address(l.beacon()) && address(l.token()) == address(t),
            "permanent suite pointers"
        );
        require(l.moduleGeneration() == c.suiteRevision(), "implementation revision synchronized");
        require(t.totalSupply() == t.lifetimeMinted() && t.totalSupply() <= t.MAX_SUPPLY(), "global immutable cap");
        require(l.paidSupply() == handler.ghostPaid(), "actual paid accounting");
        require(l.paidSupply() <= l.fundedSupply() && l.fundedSupply() <= l.allocatedSupply(), "liability order");
        require(l.allocatedSupply() <= t.MAX_SUPPLY(), "allocated cap");
        require(t.balanceOf(address(l)) >= l.fundedLiability(), "funded claims backed");
        require(
            l.allocatedSupply() == l.paidSupply() + l.fundedLiability() + l.unfundedLiability(), "liabilities partition"
        );
    }

    function afterInvariant() external {
        handler.drain();
    }
}

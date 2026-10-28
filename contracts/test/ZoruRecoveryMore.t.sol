// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {SuiteSupport} from "./SuiteSupport.sol";
import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {IZoruWorkEngine, IZoruBeaconSource} from "../src/IZoruMining.sol";
import {MockBeacon} from "./MockBeacon.sol";
import {AlwaysAcceptEngine} from "./ZoruProtocol.t.sol";
import {AdversarialFixture} from "./ZoruAdversarial.t.sol";
import {BrokenLedger} from "./ZoruRecovery.t.sol";

contract SevenCoinPolicy is ZoruLedger {
    function budgetForIndex(uint256) public pure override returns (uint256) {
        return 7e8;
    }
}

contract StorageCollisionFixture {
    function smashTokenPointer() external {
        assembly { sstore(0, 0) }
    }
}

contract RepairTokenPointerFixture is ZoruLedger {
    function repairTokenPointer(ZoruToken correctToken) external {
        address admin = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"01")))));
        require(msg.sender == admin, "only external proxy admin repair");
        token = correctToken;
    }
}

contract ZoruExternalRecoveryTest is AdversarialFixture {
    ZoruAdminAdapter adapter;
    ProxyAdmin proxyAdmin;
    bytes32 constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    function setUp() public override {
        vm.chainId(6736);
        vm.warp(START - 10);
        token = new ZoruToken(address(this));
        address e;
        address b;
        (ledger, adapter, e, b) = SuiteSupport.mockSuite(
            token, address(new MockBeacon(START)), address(new AlwaysAcceptEngine()), START, uint256(1 << 100)
        );
        coordinator = adapter;
        engine = AlwaysAcceptEngine(e);
        beacon = MockBeacon(b);
        proxyAdmin = ProxyAdmin(adapter.adminOf(address(ledger)));
        vm.warp(START + 1);
    }

    function testFactoryRegistersActualAdminAtomically() public view {
        require(
            address(proxyAdmin) == address(uint160(uint256(vm.load(address(ledger), ADMIN_SLOT)))),
            "actual ERC1967 admin"
        );
        require(proxyAdmin.owner() == address(adapter), "one root owner through adapter");
    }

    function testRegistrationRejectsUnrelatedAdminOwnedBySameAdapter() public {
        TransparentUpgradeableProxy other = new TransparentUpgradeableProxy(
            address(new ZoruLedger()),
            address(adapter),
            abi.encodeCall(ZoruLedger.initialize, (token, beacon, engine, START + 60, uint256(1)))
        );
        ProxyAdmin wrong = new ProxyAdmin(address(adapter));
        vm.expectRevert(ZoruAdminAdapter.InvalidAdmin.selector);
        adapter.registerProxy(address(other), wrong);
    }

    function testRecoveryPreservesFundedAndUnfundedEpochs() public {
        bytes32 a = ledger.submit(0, ALICE, 1);
        vm.warp(START + 60);
        ledger.seal(0);
        bytes32 b = ledger.submit(1, BOB, 2);
        bytes32 stateHash = keccak256(
            abi.encode(
                ledger.epochInfo(0),
                ledger.epochInfo(1).budget,
                ledger.epochInfo(1).proofCount,
                ledger.allocatedSupply(),
                ledger.fundedSupply()
            )
        );
        SuiteSupport.emergencyLedger(adapter, address(new BrokenLedger()), "");
        vm.expectRevert();
        ledger.fundedLiability();
        SuiteSupport.emergencyLedger(adapter, address(new ZoruLedger()), "");
        require(
            stateHash
                == keccak256(
                    abi.encode(
                        ledger.epochInfo(0),
                        ledger.epochInfo(1).budget,
                        ledger.epochInfo(1).proofCount,
                        ledger.allocatedSupply(),
                        ledger.fundedSupply()
                    )
                ),
            "storage continuity"
        );
        require(ledger.claim(a) == 5e8, "funded claim intact");
        vm.warp(START + 120);
        ledger.seal(1);
        require(ledger.claim(b) == 5e8, "pending allocation intact");
    }

    function testChangedEconomicsAreLedgerCodeAndPreserveOldBudget() public {
        bytes32 old = ledger.submit(0, ALICE, 1);
        SuiteSupport.emergencyLedger(adapter, address(new SevenCoinPolicy()), "");
        vm.warp(START + 60);
        bytes32 next = ledger.submit(1, BOB, 2);
        require(ledger.epochInfo(0).budget == 5e8 && ledger.epochInfo(1).budget == 7e8, "stored old budget, new policy");
        ledger.seal(0);
        vm.warp(START + 120);
        ledger.seal(1);
        require(ledger.claim(old) == 5e8 && ledger.claim(next) == 7e8, "immutable token imposes no reward rule");
        require(token.totalSupply() == 12e8, "cap remains independent");
    }

    function testEngineAndBeaconProxyRecoverExternallyWhenBothBroken() public {
        address work = address(engine);
        address source = address(beacon);
        bytes32 a = ledger.submit(0, ALICE, 1);
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = address(new BrokenLedger());
        u.beaconImplementation = address(new BrokenLedger());
        adapter.emergencyUpgrade(u);
        vm.expectRevert();
        ledger.submit(0, BOB, 2);
        u.engineImplementation = address(new AlwaysAcceptEngine());
        u.beaconImplementation = address(new MockBeacon(START));
        adapter.emergencyUpgrade(u);
        require(address(ledger.engine()) == work && address(ledger.beacon()) == source, "permanent proxies");
        bytes32 b = ledger.submit(0, BOB, 2);
        vm.warp(START + 60);
        ledger.seal(0);
        require(ledger.claim(a) + ledger.claim(b) == 5e8, "old and new work paid");
    }

    function testExternalAdminCanRepairCollisionThatBreaksLedgerOwnerLookup() public {
        bytes32 proof = ledger.submit(0, ALICE, 1);
        SuiteSupport.emergencyLedger(
            adapter,
            address(new StorageCollisionFixture()),
            abi.encodeCall(StorageCollisionFixture.smashTokenPointer, ())
        );
        SuiteSupport.emergencyLedger(
            adapter,
            address(new RepairTokenPointerFixture()),
            abi.encodeCall(RepairTokenPointerFixture.repairTokenPointer, (token))
        );
        require(address(ledger.token()) == address(token), "repair independent of corrupted token pointer");
        vm.warp(START + 60);
        ledger.seal(0);
        require(ledger.claim(proof) == 5e8, "mapping not overwritten");
        // Demonstrates recovery of this specific collision, not arbitrary destroyed state.
    }

    function testAdapterCanBeReplacedWithoutCallingLedger() public {
        SuiteSupport.emergencyLedger(adapter, address(new BrokenLedger()), "");
        ZoruAdminAdapter next = new ZoruAdminAdapter(token);
        next.authorizeHandoverFrom(adapter);
        adapter.handoverSuite(next);
        SuiteSupport.emergencyLedger(next, address(new ZoruLedger()), "");
        require(ledger.epochNow() == 0, "adapter replacement does not need working ledger");
        require(adapter.adminOf(address(ledger)) == address(0), "no stale old adapter control");
    }

    function testImplementationAndProxyCannotBeReinitialized() public {
        ZoruLedger logic = new ZoruLedger();
        vm.expectRevert();
        logic.initialize(token, beacon, engine, START + 60, 1);
        vm.expectRevert();
        ledger.initialize(token, beacon, engine, START + 60, 1);
    }

    function testNonOwnerCannotDeployRecoverOrReplaceAdmin() public {
        vm.expectRevert(ZoruAdminAdapter.OnlyOwner.selector);
        vm.prank(BOB);
        adapter.deployProxy(address(ledger), "");
        vm.expectRevert(ZoruLedger.OnlyCoordinator.selector);
        vm.prank(BOB);
        ledger.onImplementationUpgrade(2, true);
        vm.expectRevert(ZoruAdminAdapter.OnlyOwner.selector);
        vm.prank(BOB);
        adapter.handoverProxy(address(ledger), adapter);
    }
}

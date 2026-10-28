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

interface RecoveryVm {
    function warp(uint256) external;
    function prank(address) external;
    function load(address, bytes32) external view returns (bytes32);
    function expectRevert() external;
    function expectRevert(bytes4) external;
}

contract RecoveryAlwaysAccept is IZoruWorkEngine {
    function valid(bytes32, uint256) external pure returns (bool) {
        return true;
    }
}

/// @notice Intentional broken test fixture used to confirm external proxy recovery.
contract BrokenLedger {
    fallback() external payable {
        revert("BROKEN");
    }
}

contract ZoruRecoveryTest {
    RecoveryVm constant vm = RecoveryVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    uint256 constant START = 1_800_000_000;
    ZoruToken token;
    ZoruLedger ledger;
    ZoruAdminAdapter adapter;
    ProxyAdmin actualProxyAdmin;
    MockBeacon beacon;
    RecoveryAlwaysAccept engine;

    function setUp() public {
        vm.warp(START - 10);
        token = new ZoruToken(address(this));
        address e;
        address b;
        (ledger, adapter, e, b) = SuiteSupport.mockSuite(
            token, address(new MockBeacon(START)), address(new RecoveryAlwaysAccept()), START, type(uint256).max >> 16
        );
        engine = RecoveryAlwaysAccept(e);
        beacon = MockBeacon(b);
        actualProxyAdmin = ProxyAdmin(adapter.adminOf(address(ledger)));
        vm.warp(START + 1);
    }

    function testRecoverFromFullyBrokenLedgerAndPreserveOldClaim() public {
        bytes32 proof = ledger.submit(0, address(0xA11CE), 1);
        vm.warp(START + 61);
        ledger.seal(0);
        BrokenLedger broken = new BrokenLedger();
        SuiteSupport.emergencyLedger(adapter, address(broken), "");
        vm.expectRevert();
        ledger.epochNow();
        ZoruLedger restored = new ZoruLedger();
        SuiteSupport.emergencyLedger(adapter, address(restored), "");
        require(ledger.claim(proof) == 5 * 1e8, "must preserve old proof");
        require(token.balanceOf(address(0xA11CE)) == 5 * 1e8, "must pay exactly once");
    }

    function testSingleOwnerFollowsTwoStepTokenOwnership() public {
        address next = address(0xA11CE);
        token.transferOwnership(next);
        ZoruLedger replacement = new ZoruLedger();
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = address(replacement);
        require(token.owner() == address(this), "pending owner no access");
        vm.expectRevert(ZoruAdminAdapter.OnlyOwner.selector);
        vm.prank(next);
        adapter.emergencyUpgrade(u);
        vm.prank(next);
        token.acceptOwnership();
        vm.expectRevert(ZoruAdminAdapter.OnlyOwner.selector);
        adapter.emergencyUpgrade(u);
        vm.prank(next);
        adapter.emergencyUpgrade(u);
        require(token.owner() == next, "single authority");
    }

    function testRenounceDisabled() public {
        vm.expectRevert(ZoruToken.RenounceDisabled.selector);
        token.renounceOwnership();
    }

    function testOnlyOwnerCanRegisterAndUpgrade() public {
        ZoruLedger replacement = new ZoruLedger();
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = address(replacement);
        vm.expectRevert(ZoruAdminAdapter.OnlyOwner.selector);
        vm.prank(address(0xB0B));
        adapter.emergencyUpgrade(u);
        require(actualProxyAdmin.owner() == address(adapter), "owned by adapter");
    }
}

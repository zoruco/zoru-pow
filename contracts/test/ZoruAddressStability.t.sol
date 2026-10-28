// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruKeccakEngine} from "../src/ZoruKeccakEngine.sol";
import {ZoruDrandBeacon} from "../src/ZoruDrandBeacon.sol";
import {IZoruWorkEngine} from "../src/IZoruMining.sol";
import {BLS} from "zoru-evmnet/BLS.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AdversarialFixture, AdversarialVm} from "./ZoruAdversarial.t.sol";
import {AlwaysAcceptEngine, RejectEngine} from "./ZoruProtocol.t.sol";
import {BrokenLedger} from "./ZoruRecovery.t.sol";
import {MockBeacon} from "./MockBeacon.sol";
import {SevenCoinPolicy} from "./ZoruRecoveryMore.t.sol";

contract StatefulKernelFixture is ZoruKeccakEngine {
    uint256 public additionalState;

    function initializeV2(uint256 n) external reinitializer(2) {
        additionalState = n;
    }
}

contract ExtendedBeaconFixture is ZoruDrandBeacon {
    uint256 public additionalState;

    function initializeV2(uint256 n) external reinitializer(2) {
        additionalState = n;
    }
}

contract DifferentKeyBeaconFixture is ZoruDrandBeacon {
    function publicKey() public pure override returns (BLS.PointG2 memory key) {
        // Valid negated G2 point: a different key, without an invalid-point gas burn.
        key = super.publicKey();
        uint256 p = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        key.y[0] = p - key.y[0];
        key.y[1] = p - key.y[1];
    }
}

contract DigestOnlyEngineFixture is IZoruWorkEngine {
    bytes32 immutable permitted;

    constructor(bytes32 digest) {
        permitted = digest;
    }

    function valid(bytes32 digest, uint256) external view returns (bool) {
        return digest == permitted;
    }
}

contract CorruptProxySlotsFixture {
    function corruptImplementation() external {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assembly { sstore(slot, 0) }
    }

    function corruptAdminSlot() external {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        assembly { sstore(slot, 0) }
    }
}

contract ZoruAddressStabilityTest is AdversarialFixture {
    bytes32 constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    function fixedAddresses() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(token),
                address(ledger),
                address(engine),
                address(beacon),
                token.issuer(),
                address(ledger.engine()),
                address(ledger.beacon())
            )
        );
    }

    function actualImplementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function engineUpgrade(address implementation) internal pure returns (ZoruAdminAdapter.SuiteUpgrade memory u) {
        u.engineImplementation = implementation;
    }

    function testNormalUpgradeKeepsEveryPublicAddressAndIssuer() public {
        bytes32 addressesBefore = fixedAddresses();
        address oldImpl = actualImplementation(address(engine));
        bytes32 accepted = ledger.submit(0, ALICE, 1);
        RejectEngine replacement = new RejectEngine();
        coordinator.scheduleUpgrade(engineUpgrade(address(replacement)));
        require(actualImplementation(address(engine)) == oldImpl, "scheduling cannot replace active code");
        ledger.submit(0, BOB, 2);
        vm.warp(START + 59);
        ledger.submit(0, BOB, 3);
        vm.expectRevert(ZoruAdminAdapter.NotReady.selector);
        coordinator.executeScheduledUpgrade();
        vm.warp(START + 60);
        vm.expectRevert(ZoruLedger.UpgradePending.selector);
        ledger.openEpoch(1);
        vm.expectRevert(ZoruLedger.UpgradePending.selector);
        ledger.targetForEpoch(1);
        vm.prank(BOB); // Anyone can execute owner-approved work.
        coordinator.executeScheduledUpgrade();
        require(fixedAddresses() == addressesBefore, "token, proxies, pointers, issuer stay");
        require(
            actualImplementation(address(engine)) == address(replacement) && oldImpl != address(replacement),
            "implementation address changes"
        );
        require(ledger.epochInfo(0).generation == 1 && ledger.moduleGeneration() == 2, "closed snapshot retained");
        vm.expectRevert(ZoruLedger.InvalidProof.selector);
        ledger.submit(1, ALICE, 4);
        ledger.seal(0);
        require(ledger.claim(accepted) > 0, "old accepted work remains claimable");
    }

    function testEngineAddressEqualityCannotDetectImplementationRevision() public {
        address pointer = address(ledger.engine());
        coordinator.scheduleUpgrade(engineUpgrade(address(new AlwaysAcceptEngine())));
        vm.warp(START + 60);
        coordinator.executeScheduledUpgrade();
        ledger.submit(1, ALICE, 1);
        require(address(ledger.engine()) == pointer && ledger.epochInfo(1).engine == pointer, "same proxy equality");
        require(ledger.epochInfo(1).generation == 2, "generation detects changed implementation");
        (, address oldImpl,,,,) = coordinator.revisionInfo(1);
        (, address newImpl,,,,) = coordinator.revisionInfo(2);
        require(oldImpl != newImpl, "implementation snapshots are revision-specific");
    }

    function testEmergencyInvalidatesUnsubmittedOldWorkButPaysAcceptedProofs() public {
        bytes32 addressesBefore = fixedAddresses();
        vm.recordLogs();
        bytes32 oldAccepted = ledger.submit(0, ALICE, 1);
        bytes32 seed = ledger.epochInfo(0).seed;
        bytes32 stale = ledger.digestFor(0, seed, ALICE, 2);
        bytes32 fresh = keccak256(
            abi.encode(
                ledger.PROOF_DOMAIN(),
                block.chainid,
                address(ledger),
                address(token),
                uint256(2),
                uint48(0),
                seed,
                ALICE,
                uint256(3)
            )
        );
        coordinator.emergencyUpgrade(engineUpgrade(address(new DigestOnlyEngineFixture(fresh))));
        require(fixedAddresses() == addressesBefore && ledger.moduleGeneration() == 2, "emergency keeps proxies");
        require(ledger.digestFor(0, seed, ALICE, 2) != stale, "old generation domain retired");
        vm.expectRevert(ZoruLedger.InvalidProof.selector);
        ledger.submit(0, ALICE, 2);
        bytes32 next = ledger.submit(0, ALICE, 3);
        require(next == fresh, "fresh revision proof");
        AdversarialVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature = keccak256("ProofAccepted(uint48,bytes32,address,uint256,uint256)");
        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(ledger) && logs[i].topics[0] == signature) {
                (, uint256 generation) = abi.decode(logs[i].data, (uint256, uint256));
                require(generation == ++seen, "proof log preserves historical generation");
            }
        }
        require(seen == 2, "old and fresh proof contexts logged");
        vm.warp(START + 60);
        ledger.seal(0);
        require(
            ledger.claim(oldAccepted) + ledger.claim(next) == 5e8,
            "accepted proof compatibility and reward conservation"
        );
    }

    function testBrokenLedgerEngineBeaconThenRollbackAllAtSameAddresses() public {
        bytes32 beforeAddresses = fixedAddresses();
        bytes32 proof = ledger.submit(0, ALICE, 1);
        address l = actualImplementation(address(ledger));
        address e = actualImplementation(address(engine));
        address b = actualImplementation(address(beacon));
        BrokenLedger broken = new BrokenLedger();
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = address(broken);
        u.engineImplementation = address(broken);
        u.beaconImplementation = address(broken);
        coordinator.emergencyUpgrade(u);
        require(coordinator.recoveryRequired(), "failed hook cannot freeze external admin");
        vm.expectRevert();
        ledger.epochNow();
        u.ledgerImplementation = l;
        u.engineImplementation = e;
        u.beaconImplementation = b;
        coordinator.emergencyUpgrade(u);
        require(!coordinator.recoveryRequired() && fixedAddresses() == beforeAddresses, "rollback restores suite");
        require(ledger.moduleGeneration() == 3, "rollback is fresh generation, not replay of revision 1");
        vm.warp(START + 60);
        ledger.seal(0);
        require(ledger.claim(proof) == 5e8, "old reward survived fatal logic");
    }

    function testBadNormalUpgradeRevertsAtomicallyAndOwnerCanCancel() public {
        bytes32 beforeAddresses = fixedAddresses();
        address oldEngine = actualImplementation(address(engine));
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = address(new RejectEngine());
        u.ledgerImplementation = address(new BrokenLedger());
        coordinator.scheduleUpgrade(u);
        vm.warp(START + 60);
        vm.expectRevert();
        coordinator.executeScheduledUpgrade();
        require(
            coordinator.suiteRevision() == 1 && actualImplementation(address(engine)) == oldEngine,
            "atomic rollback of earlier component"
        );
        require(coordinator.hasPendingUpgrade(), "failed plan remains reviewable");
        coordinator.cancelUpgrade();
        ledger.submit(1, ALICE, 1);
        require(fixedAddresses() == beforeAddresses, "cancel does not change proxies");
    }

    function testRawUpgradeAndDirectProxyAdminCannotBypassEpochCoordination() public {
        address next = address(new RejectEngine());
        vm.expectRevert(ZoruAdminAdapter.CoordinatedUpgradeRequired.selector);
        coordinator.upgrade(address(engine), next, "");
        ProxyAdmin admin = ProxyAdmin(coordinator.adminOf(address(engine)));
        vm.expectRevert();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(engine)), next, "");
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(engine)).upgradeToAndCall(next, "");
    }

    function testPublicProxyCannotBeItsOwnImplementation() public {
        vm.expectRevert(ZoruAdminAdapter.InvalidUpgrade.selector);
        coordinator.scheduleUpgrade(engineUpgrade(address(engine)));
        vm.expectRevert(ZoruAdminAdapter.InvalidUpgrade.selector);
        coordinator.emergencyUpgrade(engineUpgrade(address(ledger)));
    }

    function testIndividualSuiteAdminHandoverForbidden() public {
        ZoruAdminAdapter next = new ZoruAdminAdapter(token);
        vm.expectRevert(ZoruAdminAdapter.CoordinatedUpgradeRequired.selector);
        coordinator.handoverProxy(address(engine), next);
    }

    function testUnknownSelectorCannotChangePublicPointers() public {
        bytes32 beforeAddresses = fixedAddresses();
        (bool changed,) = address(ledger).call(hex"ffffffff");
        require(!changed && fixedAddresses() == beforeAddresses, "no fallback pointer replacement");
    }

    function testNormalBadEngineCanRollbackImmediatelyInsideNewEpoch() public {
        bytes32 beforeAddresses = fixedAddresses();
        address original = actualImplementation(address(engine));
        coordinator.scheduleUpgrade(engineUpgrade(address(new BrokenLedger())));
        vm.warp(START + 60);
        coordinator.executeScheduledUpgrade();
        vm.expectRevert();
        ledger.submit(1, ALICE, 1);
        coordinator.emergencyUpgrade(engineUpgrade(original));
        ledger.submit(1, ALICE, 1);
        require(
            fixedAddresses() == beforeAddresses && ledger.moduleGeneration() == 3, "immediate rollback, no epoch wait"
        );
    }

    function testSuiteAdminHandoverWhileLedgerBrokenPreservesAddressesAndClaims() public {
        bytes32 beforeAddresses = fixedAddresses();
        bytes32 proof = ledger.submit(0, ALICE, 1);
        address original = actualImplementation(address(ledger));
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = address(new BrokenLedger());
        coordinator.emergencyUpgrade(u);
        ZoruAdminAdapter next = new ZoruAdminAdapter(token);
        next.authorizeHandoverFrom(coordinator);
        coordinator.handoverSuite(next);
        u.ledgerImplementation = original;
        next.emergencyUpgrade(u);
        require(
            fixedAddresses() == beforeAddresses && ledger.protocolAdmin() == address(next),
            "same suite with new external coordinator"
        );
        vm.warp(START + 60);
        ledger.seal(0);
        require(ledger.claim(proof) == 5e8, "historical claim intact after handover");
    }

    function testCorruptImplementationSlotCanStillBeExternallyRolledBack() public {
        address pointer = address(engine);
        ZoruAdminAdapter.SuiteUpgrade memory u = engineUpgrade(address(new CorruptProxySlotsFixture()));
        u.engineData = abi.encodeCall(CorruptProxySlotsFixture.corruptImplementation, ());
        coordinator.emergencyUpgrade(u);
        require(actualImplementation(pointer) == address(0), "fixture corrupts dispatch slot");
        vm.expectRevert();
        ledger.submit(0, ALICE, 1);
        coordinator.emergencyUpgrade(engineUpgrade(address(new AlwaysAcceptEngine())));
        require(address(ledger.engine()) == pointer, "repair preserves proxy address");
        ledger.submit(0, ALICE, 1);
    }

    function testMutableAdminSlotIsNotTheTransparentProxysActualAdmin() public {
        address pointer = address(engine);
        address actualAdmin = coordinator.adminOf(pointer);
        ZoruAdminAdapter.SuiteUpgrade memory u = engineUpgrade(address(new CorruptProxySlotsFixture()));
        u.engineData = abi.encodeCall(CorruptProxySlotsFixture.corruptAdminSlot, ());
        coordinator.emergencyUpgrade(u);
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        require(vm.load(pointer, slot) == bytes32(0), "ERC1967 storage field was overwritten");
        coordinator.emergencyUpgrade(engineUpgrade(address(new AlwaysAcceptEngine())));
        require(coordinator.adminOf(pointer) == actualAdmin, "registry follows immutable actual admin");
        ledger.submit(0, ALICE, 1);
    }

    function testFatalProxyBytecodeLossCannotBeRepairedByImplementationUpgrade() public {
        vm.etch(address(ledger), hex""); // Local fixture only; models shell destruction.
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = address(new ZoruLedger());
        vm.expectRevert();
        coordinator.emergencyUpgrade(u);
        require(address(ledger).code.length == 0, "cannot recreate fatal proxy shell via ordinary upgrade");
        require(token.MAX_SUPPLY() == 21_000_000 * 1e8, "token code remains independent");
    }

    function testHandoverCannotBeFrontRunByUnapprovedCaller() public {
        ZoruAdminAdapter next = new ZoruAdminAdapter(token);
        vm.expectRevert(ZoruAdminAdapter.InvalidAdmin.selector);
        vm.prank(BOB);
        next.acceptSuiteHandover();
    }

    function testOwnerTransferPreservesAllAddressesAndNewOwnerCanUpgrade() public {
        bytes32 beforeAddresses = fixedAddresses();
        token.transferOwnership(BOB);
        ZoruAdminAdapter.SuiteUpgrade memory u = engineUpgrade(address(new AlwaysAcceptEngine()));
        vm.expectRevert(ZoruAdminAdapter.OnlyOwner.selector);
        vm.prank(BOB);
        coordinator.emergencyUpgrade(u);
        vm.prank(BOB);
        token.acceptOwnership();
        vm.expectRevert(ZoruAdminAdapter.OnlyOwner.selector);
        coordinator.emergencyUpgrade(u);
        vm.prank(BOB);
        coordinator.emergencyUpgrade(u);
        require(fixedAddresses() == beforeAddresses && token.owner() == BOB, "one owner, same public suite");
    }

    function testNormalUpgradeDoesNotHoldFundedClaimUntilActivation() public {
        bytes32 proof = ledger.submit(0, ALICE, 1);
        vm.warp(START + 60);
        ledger.seal(0);
        coordinator.scheduleUpgrade(engineUpgrade(address(new RejectEngine())));
        vm.warp(START + 120);
        require(ledger.claim(proof) == 5e8, "pending upgrade must not gate historical funded claims");
    }

    function testFuzzRepeatedUpgradesKeepAddressesAndClaims(uint8 roundsSeed) public {
        uint256 rounds = uint256(roundsSeed) % 6 + 1;
        bytes32 addressesBefore = fixedAddresses();
        bytes32 proof = ledger.submit(0, ALICE, 1);
        for (uint256 i; i < rounds; i++) {
            coordinator.emergencyUpgrade(engineUpgrade(address(new AlwaysAcceptEngine())));
            require(fixedAddresses() == addressesBefore, "no address drift across random upgrade sequence");
        }
        require(ledger.moduleGeneration() == rounds + 1, "monotonic generations");
        vm.warp(START + 60);
        ledger.seal(0);
        require(ledger.claim(proof) == 5e8, "proof liability retained");
    }
}

contract ZoruProductionModuleProxyTest is AdversarialFixture {
    bytes constant SIG =
        hex"139a803860ff6d842b822b8b37eaeccc4e278dd44440535a976530a1a503e85e11d84b824f18e608a85e627e6b1b08322060cbcf7eca1ea78489252907e8473a";
    bytes32 constant RANDOMNESS = hex"4da14d73e62d0c909d143e61a2adce866f6be3e7a9d58b1e32a95c87e780569c";
    uint256 constant LAUNCH = 1_727_521_075 + (1_000_000 - 1) * 3;

    function testStatelessProductionKernelInitializerAndReinitializerSemantics() public {
        ZoruKeccakEngine impl = new ZoruKeccakEngine();
        vm.expectRevert();
        impl.initialize();
        address proxy = coordinator.deployProxy(address(impl), abi.encodeCall(ZoruKeccakEngine.initialize, ()));
        vm.expectRevert();
        ZoruKeccakEngine(proxy).initialize();
        require(ZoruKeccakEngine(proxy).valid(bytes32(uint256(2)), 3), "proxy kernel semantics");
        StatefulKernelFixture next = new StatefulKernelFixture();
        coordinator.upgrade(proxy, address(next), abi.encodeCall(StatefulKernelFixture.initializeV2, (77)));
        require(StatefulKernelFixture(proxy).additionalState() == 77, "appended state initialized once");
        vm.expectRevert();
        StatefulKernelFixture(proxy).initializeV2(88);
        coordinator.upgrade(proxy, address(impl), "");
        require(ZoruKeccakEngine(proxy).valid(bytes32(uint256(2)), 3), "rollback semantics same proxy");
        coordinator.upgrade(proxy, address(next), "");
        require(StatefulKernelFixture(proxy).additionalState() == 77, "state survives compatible rollback");
    }

    function testBeaconProxyPreservesClockAndKeyButRequiresCacheReauthentication() public {
        ZoruDrandBeacon impl = new ZoruDrandBeacon();
        vm.expectRevert();
        impl.initialize(LAUNCH);
        address proxy = coordinator.deployProxy(address(impl), abi.encodeCall(ZoruDrandBeacon.initialize, (LAUNCH)));
        ZoruDrandBeacon source = ZoruDrandBeacon(proxy);
        vm.expectRevert();
        source.initialize(LAUNCH + 60);
        bytes32 configBefore = source.verificationConfigId();
        vm.warp(LAUNCH);
        require(source.publish(0, SIG) == RANDOMNESS, "official signature under trusted key");
        ExtendedBeaconFixture next = new ExtendedBeaconFixture();
        coordinator.upgrade(proxy, address(next), abi.encodeCall(ExtendedBeaconFixture.initializeV2, (99)));
        require(
            source.launchTime() == LAUNCH && source.expectedRound(0) == 1_000_000, "storage not constructor immutables"
        );
        require(
            source.verificationConfigId() == configBefore && source.verifiedSeed(0) == bytes32(0),
            "unchanged key with cache excluded after changing implementation"
        );
        require(source.publish(0, SIG) == RANDOMNESS, "authenticated republication on new implementation");
        vm.expectRevert(ZoruDrandBeacon.AlreadyPublished.selector);
        source.publish(0, SIG);
        coordinator.upgrade(proxy, address(impl), "");
        require(source.verifiedSeed(0) == bytes32(0), "rollback cannot trust later implementation cache");
        require(source.publish(0, SIG) == RANDOMNESS, "rollback reauthenticates");
        coordinator.upgrade(proxy, address(next), "");
        require(source.verifiedSeed(0) == bytes32(0), "each implementation has a separate cache domain");
        require(ExtendedBeaconFixture(proxy).additionalState() == 99, "appended state retained");
        vm.expectRevert();
        ExtendedBeaconFixture(proxy).initializeV2(1);
    }

    function testChangingTrustedKeyCannotReuseOldCachedRandomness() public {
        ZoruDrandBeacon impl = new ZoruDrandBeacon();
        address proxy = coordinator.deployProxy(address(impl), abi.encodeCall(ZoruDrandBeacon.initialize, (LAUNCH)));
        ZoruDrandBeacon source = ZoruDrandBeacon(proxy);
        vm.warp(LAUNCH);
        source.publish(0, SIG);
        bytes32 originalConfig = source.verificationConfigId();
        coordinator.upgrade(proxy, address(new DifferentKeyBeaconFixture()), "");
        require(
            source.verificationConfigId() != originalConfig && source.verifiedSeed(0) == bytes32(0),
            "cache tied to exact verification context"
        );
        vm.expectRevert();
        source.publish(0, SIG);
        coordinator.upgrade(proxy, address(impl), "");
        require(source.verifiedSeed(0) == RANDOMNESS, "valid original cache restored with original trusted key");
    }
}

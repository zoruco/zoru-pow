// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruDrandBeacon} from "../src/ZoruDrandBeacon.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {AlwaysAcceptEngine} from "./ZoruProtocol.t.sol";
import {CryptoCacheRepairFixture} from "./ZoruCryptoVerification.t.sol";
import {CryptoOracleVectors} from "./CryptoOracleVectors.sol";

interface CacheSuiteVm {
    function warp(uint256) external;
    function store(address, bytes32, bytes32) external;
    function prank(address) external;
}

/// @dev The permissive engine isolates cache/accounting recovery from hash cost.
/// Signature verification still uses the production Beacon and official vectors.
contract ZoruCacheSuiteRecoveryTest {
    CacheSuiteVm constant vm = CacheSuiteVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant START = 1_730_521_072;
    address constant ALICE = address(0xa11ce);
    address constant BOB = address(0xb0b);
    ZoruToken token;
    ZoruLedger ledger;
    ZoruDrandBeacon beacon;
    ZoruAdminAdapter admin;
    address logic;

    function setUp() public {
        vm.warp(START - 1);
        token = new ZoruToken(address(this));
        admin = new ZoruAdminAdapter(token);
        logic = address(new ZoruDrandBeacon());
        ZoruAdminAdapter.SuiteDeployment memory d;
        d.ledgerImplementation = address(new ZoruLedger());
        d.engineImplementation = address(new AlwaysAcceptEngine());
        d.engineData = abi.encodeWithSignature("valid(bytes32,uint256)", bytes32(0), 1);
        d.beaconImplementation = logic;
        d.beaconData = abi.encodeCall(ZoruDrandBeacon.initialize, (START));
        d.launchTime = START;
        d.initialTarget = type(uint256).max >> 16;
        (address l,, address b) = admin.deploySuite(d);
        ledger = ZoruLedger(l);
        beacon = ZoruDrandBeacon(b);
        token.setIssuer(l);
        vm.warp(START);
    }

    function publish(uint48 epoch) internal returns (bytes32 expected) {
        (, bytes memory signature, bytes32 seed,) = CryptoOracleVectors.roundVector(epoch);
        require(beacon.publish(epoch, signature) == seed, "authenticated seed");
        return seed;
    }

    function upgrade(address implementation, bytes memory data) internal {
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.beaconImplementation = implementation;
        u.beaconData = data;
        admin.emergencyUpgrade(u);
        require(!admin.recoveryRequired(), "coordinated ledger checkpoint");
    }

    function addresses() internal view returns (bytes32) {
        return keccak256(abi.encode(address(token), address(ledger), address(beacon),
            address(ledger.engine()), token.issuer(), ledger.protocolAdmin(), admin.adminOf(address(beacon))));
    }

    function testSuiteUpgradeAutomaticallyRetiresUnsafeCacheAndPreservesClaims() public {
        bytes32 stable = addresses();
        publish(0);
        bytes32 paidProof = ledger.submit(0, ALICE, 1);
        vm.warp(START + 60);
        ledger.seal(0);
        require(ledger.claim(paidProof) == 5e8, "prior epoch fully paid");
        bytes32 authentic = publish(1);
        bytes32 pendingProof = ledger.submit(1, BOB, 2);
        bytes32 previousDigest = ledger.digestFor(1, authentic, BOB, 3);

        // Reproduce a poisoned old verifier without changing the trusted key.
        CryptoCacheRepairFixture unsafeOld = new CryptoCacheRepairFixture();
        bytes32 fake = keccak256("bad historical verifier result");
        upgrade(address(unsafeOld), abi.encodeCall(unsafeOld.writeCache, (1, fake)));
        bytes32 config = beacon.verificationConfigId();
        upgrade(logic, "");
        require(admin.suiteRevision() == 3 && ledger.moduleGeneration() == 3, "fresh generation");
        require(beacon.verificationConfigId() == config, "key, DST and round policy unchanged");
        require(beacon.verifiedSeed(1) == bytes32(0), "unsafe historical cache rejected automatically");
        require(beacon.verifiedSeed(0) == bytes32(0), "prior generation cache invalidated without cleanup");
        require(ledger.epochInfo(1).seed == bytes32(0), "no stale ledger seed");
        (bool ok,) = address(ledger).call(abi.encodeCall(ZoruLedger.submit, (1, BOB, 3)));
        require(!ok, "no admission until a real signature is republished");
        require(publish(1) == authentic, "recovered official signature");
        bytes32 fresh = ledger.submit(1, BOB, 3);
        require(fresh != previousDigest && ledger.epochInfo(1).generation == 3, "stale work domain retired");
        require(addresses() == stable, "all public addresses and issuer stay fixed");

        vm.warp(START + 120);
        ledger.seal(1);
        require(ledger.claim(pendingProof) + ledger.claim(fresh) == 5e8, "pending accepted work preserved");
        (ok,) = address(ledger).call(abi.encodeCall(ZoruLedger.claim, (paidProof)));
        require(!ok, "settled claim cannot replay");
        require(token.balanceOf(ALICE) == 5e8 && token.balanceOf(BOB) == 5e8, "rewards conserved");
        require(ledger.paidSupply() == 10e8 && ledger.fundedLiability() == 0
            && ledger.unfundedLiability() == 0 && token.balanceOf(address(ledger)) == 0, "no residual liability");
    }

    function testAuthenticatedCacheReadsStayWithinLedgerModuleGasLimit() public {
        bytes32 original = publish(0);
        uint256 maxGas = ledger.MODULE_CALL_GAS();

        (bool ok, bytes memory response) = address(beacon).staticcall{gas: maxGas}(
            abi.encodeCall(ZoruDrandBeacon.verifiedSeed, (uint48(0)))
        );
        require(ok && response.length == 32 && abi.decode(response, (bytes32)) == original,
            "authenticated cache must fit the Ledger gas allowance");
        bytes32 first = ledger.submit(0, ALICE, 91);
        require(first != bytes32(0) && ledger.totalProofs() == 1, "first accepted work");
        upgrade(logic, "");
        require(beacon.verifiedSeed(0) == bytes32(0), "old cache retired");

        require(publish(0) == original, "signed round republished");
        (ok, response) = address(beacon).staticcall{gas: maxGas}(
            abi.encodeCall(ZoruDrandBeacon.verifiedSeed, (uint48(0)))
        );
        require(ok && response.length == 32 && abi.decode(response, (bytes32)) == original,
            "revalidated cache must fit the same gas allowance");
        bytes32 second = ledger.submit(0, ALICE, 92);
        require(second != first && ledger.totalProofs() == 2, "post-upgrade work accepted");
    }

    function testSameImplementationNewSuiteRevisionAutomaticallyRejectsOldCache() public {
        bytes32 expected = publish(0);
        bytes32 oldDomain = beacon.cacheTrustId();
        require(beacon.verifiedSeed(0) == expected, "original authenticated cache");

        upgrade(logic, "");
        require(beacon.cacheTrustId() != oldDomain, "suite generation changes trust domain");
        require(beacon.verifiedSeed(0) == bytes32(0), "no stale cache under the new revision");
        require(publish(0) == expected, "republication requires authentic signature");
        require(beacon.verifiedSeed(0) == expected, "new generation revalidated");

        bytes32 secondDomain = beacon.cacheTrustId();
        upgrade(logic, "");
        require(beacon.cacheTrustId() != secondDomain && beacon.verifiedSeed(0) == bytes32(0),
            "rollback to identical implementation never resurrects old generation cache");
    }

    function testEngineOnlySuiteUpgradeInvalidatesBeaconCacheWithoutCleanup() public {
        bytes32 expected = publish(0);
        bytes32 oldDomain = beacon.cacheTrustId();
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = admin.implementationOf(address(ledger.engine()));
        admin.emergencyUpgrade(u);
        require(!admin.recoveryRequired(), "ledger must checkpoint automatically");
        require(beacon.cacheTrustId() != oldDomain && beacon.verifiedSeed(0) == bytes32(0),
            "suite generation retires cached randomness");
        require(publish(0) == expected, "current verifier may authenticate again");
    }

    function testScheduledUpgradeAutomaticallyRetiresCacheWhenEpochChanges() public {
        bytes32 expected = publish(0);
        bytes32 priorDomain = beacon.cacheTrustId();
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.beaconImplementation = logic;
        admin.scheduleUpgrade(u);
        require(beacon.verifiedSeed(0) == expected, "scheduled change cannot invalidate early");

        vm.warp(START + 60);
        vm.prank(BOB);
        admin.executeScheduledUpgrade();
        require(!admin.recoveryRequired() && admin.suiteRevision() == 2, "normal upgrade complete");
        require(beacon.cacheTrustId() != priorDomain && beacon.verifiedSeed(0) == bytes32(0),
            "automatic cache retirement at activation");
        require(publish(0) == expected, "authenticated republication after upgrade");
    }

    function testBrokenScheduledUpgradeRevertsAtomicallyWithoutStrandingCache() public {
        bytes32 expected = publish(0);
        bytes32 priorDomain = beacon.cacheTrustId();
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.beaconImplementation = logic;
        u.beaconData = abi.encodeWithSignature("missingUpgradeHook()");
        admin.scheduleUpgrade(u);
        vm.warp(START + 60);
        (bool succeeded,) = address(admin).call(abi.encodeCall(admin.executeScheduledUpgrade, ()));
        require(!succeeded, "malformed upgrade call must fail");
        require(admin.hasPendingUpgrade() && !admin.recoveryRequired() && admin.suiteRevision() == 1,
            "failed upgrade cannot change coordinator state");
        require(beacon.cacheTrustId() == priorDomain && beacon.verifiedSeed(0) == expected,
            "failed upgrade cannot clear authenticated cache");
    }

    function testCoordinatorHandoverFailsClosedUntilApprovedRecoveryAndPreservesClaims() public {
        bytes32 original = publish(0);
        bytes32 proof = ledger.submit(0, ALICE, 7);
        bytes32 oldDomain = beacon.cacheTrustId();
        ZoruAdminAdapter next = new ZoruAdminAdapter(token);
        next.authorizeHandoverFrom(admin);
        admin.handoverSuite(next);

        require(next.recoveryRequired(), "coordinator handover must pause work");
        require(beacon.cacheTrustId() != oldDomain, "new coordinator changes cache revision");
        require(beacon.verifiedSeed(0) == bytes32(0), "old cache is not trusted after handover");
        (bool accepted,) = address(ledger).call(abi.encodeCall(ZoruLedger.submit, (0, BOB, 8)));
        require(!accepted, "work may not proceed before coordinator recovery");

        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = next.implementationOf(address(ledger.engine()));
        next.emergencyUpgrade(u);
        require(!next.recoveryRequired() && ledger.protocolAdmin() == address(next),
            "owner-authorized recovery rebinds the suite");
        require(beacon.verifiedSeed(0) == bytes32(0), "old cache cannot reactivate");
        (, bytes memory authenticSignature,,) = CryptoOracleVectors.roundVector(0);
        require(beacon.publish(0, authenticSignature) == original,
            "authentic republication resumes work");
        vm.warp(START + 60);
        ledger.seal(0);
        require(ledger.claim(proof) == 5e8, "prior accepted proof remains claimable");
    }

    function testActualAdminCanRepairAfterEip1967AdminSlotCorruption() public {
        publish(0);
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        vm.store(address(beacon), slot, bytes32(uint256(uint160(address(this)))));
        uint48[] memory epochs = new uint48[](1);
        (bool ok,) = address(beacon).call(abi.encodeCall(ZoruDrandBeacon.invalidateEpochs, (epochs)));
        require(!ok, "mutable admin slot cannot grant authority");
        upgrade(logic, abi.encodeCall(ZoruDrandBeacon.invalidateEpochs, (epochs)));
        require(beacon.verifiedSeed(0) == bytes32(0), "immutable actual ProxyAdmin still works");
        publish(0);
    }

    function testMaximumRepairBatchAcceptsDuplicateAndExtremeEpochs() public {
        publish(0);
        uint48[] memory epochs = new uint48[](64);
        for (uint256 i = 1; i < 64; ++i) epochs[i] = type(uint48).max;
        upgrade(logic, abi.encodeCall(ZoruDrandBeacon.invalidateEpochs, (epochs)));
        require(beacon.verifiedSeed(0) == bytes32(0) && beacon.verifiedSeed(type(uint48).max) == bytes32(0),
            "bounded, idempotent cache repair");
        publish(0);
    }

    function testFuzzUnauthorizedInvalidationCannotChangeCache(address caller, uint48 epoch) public {
        if (caller == admin.adminOf(address(beacon))) return;
        bytes32 expected = publish(0);
        uint48[] memory epochs = new uint48[](2);
        epochs[1] = epoch;
        vm.prank(caller);
        (bool ok,) = address(beacon).call(abi.encodeCall(ZoruDrandBeacon.invalidateEpochs, (epochs)));
        require(!ok && beacon.verifiedSeed(0) == expected, "public cache cannot be invalidated");
    }
}

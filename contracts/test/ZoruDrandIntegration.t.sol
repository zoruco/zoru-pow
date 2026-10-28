// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruDrandBeacon} from "../src/ZoruDrandBeacon.sol";
import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruKeccakEngine} from "../src/ZoruKeccakEngine.sol";
import {IZoruBeaconSource, IZoruWorkEngine} from "../src/IZoruMining.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface DrandVm {
    function warp(uint256) external;
    function chainId(uint256) external;
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
}

contract ZoruDrandIntegrationTest {
    DrandVm constant vm = DrandVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes constant SIG =
        hex"139a803860ff6d842b822b8b37eaeccc4e278dd44440535a976530a1a503e85e11d84b824f18e608a85e627e6b1b08322060cbcf7eca1ea78489252907e8473a";
    bytes32 constant RANDOMNESS = hex"4da14d73e62d0c909d143e61a2adce866f6be3e7a9d58b1e32a95c87e780569c";
    uint256 constant GENESIS = 1_727_521_075;
    uint256 constant LAUNCH = GENESIS + (1_000_000 - 1) * 3;

    function makeBeacon(uint256 start) internal returns (ZoruDrandBeacon) {
        ZoruToken root = new ZoruToken(address(this));
        ZoruAdminAdapter admin = new ZoruAdminAdapter(root);
        return ZoruDrandBeacon(
            admin.deployProxy(address(new ZoruDrandBeacon()), abi.encodeCall(ZoruDrandBeacon.initialize, (start)))
        );
    }

    function testOfficialSignatureRoundAndCache() public {
        ZoruDrandBeacon beacon = makeBeacon(LAUNCH);
        require(beacon.expectedRound(0) == 1_000_000, "official vector");
        require(beacon.expectedRound(1) == 1_000_020, "60-sec step");
        require(beacon.releaseTime(1) == LAUNCH + 60, "epoch alignment");
        vm.warp(LAUNCH - 1);
        vm.expectRevert(ZoruDrandBeacon.NotYetReleased.selector);
        beacon.publish(0, SIG);
        vm.warp(LAUNCH);
        require(beacon.publish(0, SIG) == RANDOMNESS, "bls verified");
        require(beacon.verifiedSeed(0) == RANDOMNESS, "stored");
        vm.expectRevert(ZoruDrandBeacon.AlreadyPublished.selector);
        beacon.publish(0, SIG);
    }

    function testWrongRoundAndGarbageSignatureRejected() public {
        ZoruDrandBeacon wrongRound = makeBeacon(LAUNCH + 3);
        vm.warp(LAUNCH + 3);
        vm.expectRevert(ZoruDrandBeacon.InvalidSignature.selector);
        wrongRound.publish(0, SIG);
        vm.expectRevert(ZoruDrandBeacon.InvalidSignatureLength.selector);
        wrongRound.publish(0, hex"01");
        ZoruToken root = new ZoruToken(address(this));
        ZoruAdminAdapter admin = new ZoruAdminAdapter(root);
        ZoruDrandBeacon logic = new ZoruDrandBeacon();
        vm.expectRevert();
        admin.deployProxy(address(logic), abi.encodeCall(ZoruDrandBeacon.initialize, (LAUNCH + 1)));
    }

    function testInfinityAndMalformedCurveCoordinatesRejected() public {
        ZoruDrandBeacon beacon = makeBeacon(LAUNCH);
        vm.warp(LAUNCH);
        vm.expectRevert();
        beacon.publish(0, new bytes(64));
        vm.expectRevert();
        beacon.publish(0, abi.encode(type(uint256).max, type(uint256).max));
        require(beacon.verifiedSeed(0) == bytes32(0), "invalid signatures must not poison cache");
    }

    function testLiveProofWithRealBeaconAndKeccakMining() public {
        vm.chainId(6736);
        vm.warp(LAUNCH - 10);
        ZoruToken token = new ZoruToken(address(this));
        ZoruAdminAdapter admin = new ZoruAdminAdapter(token);
        ZoruAdminAdapter.SuiteDeployment memory d;
        d.ledgerImplementation = address(new ZoruLedger());
        d.engineImplementation = address(new ZoruKeccakEngine());
        d.engineData = abi.encodeCall(ZoruKeccakEngine.initialize, ());
        d.beaconImplementation = address(new ZoruDrandBeacon());
        d.beaconData = abi.encodeCall(ZoruDrandBeacon.initialize, (LAUNCH));
        d.launchTime = LAUNCH;
        d.initialTarget = type(uint256).max >> 16;
        (address l,, address b) = admin.deploySuite(d);
        ZoruLedger ledger = ZoruLedger(l);
        ZoruDrandBeacon beacon = ZoruDrandBeacon(b);
        token.setIssuer(l);
        vm.warp(LAUNCH);
        (bool forged,) = b.call{gas: 800000}(abi.encodeCall(beacon.publish, (0, abi.encode(uint256(1), uint256(2)))));
        require(!forged && beacon.verifiedSeed(0) == bytes32(0), "forgery must not create seed");
        vm.expectRevert(ZoruLedger.InvalidProof.selector);
        ledger.submit(0, address(0xA11CE), 0);
        require(ledger.allocatedSupply() == 0 && ledger.totalProofs() == 0 && token.totalSupply() == 0, "failed authentication cannot allocate reward");
        beacon.publish(0, SIG);
        address beneficiary = address(0xA11CE);
        uint256 nonce = 0;
        // Full real Keccak target search; expected ~2^16 attempts.
        // Test does not claim the mining environment can handle this in practice.
        bytes32 domain = ledger.PROOF_DOMAIN();
        uint256 target = ledger.MAX_TARGET();
        bytes memory preimage = abi.encode(
            domain,
            block.chainid,
            address(ledger),
            address(token),
            uint256(1),
            uint48(0),
            RANDOMNESS,
            beneficiary,
            uint256(0)
        );
        bytes32 candidate;
        while (true) {
            // Reuse a fixed 9-word payload: no repeated EVM-memory allocations.
            assembly {
                mstore(add(preimage, 288), nonce)
                candidate := keccak256(add(preimage, 32), 288)
            }
            if (uint256(candidate) < target) break;
            nonce++;
            require(nonce < 1_000_000, "unreasonably many attempts");
        }
        require(ledger.digestFor(0, RANDOMNESS, beneficiary, nonce) == candidate, "preimage matches");
        bytes32 digest = ledger.submit(0, beneficiary, nonce);
        require(uint256(digest) < ledger.MAX_TARGET(), "actual proof");
        require(ledger.epochInfo(0).proofCount == 1, "admitted");
        vm.warp(LAUNCH + 61);
        ledger.seal(0);
        require(ledger.claim(digest) == 5 * 1e8, "real proof paid");
        require(token.balanceOf(beneficiary) == 5 * 1e8, "beneficiary paid");
    }
}

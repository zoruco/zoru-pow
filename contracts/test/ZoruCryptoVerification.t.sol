// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {BLS} from "zoru-evmnet/BLS.sol";
import {ZoruDrandBeacon} from "../src/ZoruDrandBeacon.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruToken} from "../src/ZoruToken.sol";
import {CryptoOracleVectors} from "./CryptoOracleVectors.sol";

interface CryptoVm {
    function warp(uint256) external;
    function expectRevert() external;
}

contract DifferentCryptoKey is ZoruDrandBeacon {
    function publicKey() public pure override returns (BLS.PointG2 memory key) {
        key = super.publicKey();
        uint256 p = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        key.y[0] = p - key.y[0];
        key.y[1] = p - key.y[1];
    }
}

/// @dev Deliberately unsafe test double for a compromised old verifier.
/// Never include this implementation in a deployment manifest.
contract CryptoCacheRepairFixture is ZoruDrandBeacon {
    function writeCache(uint48 epoch, bytes32 seed) external {
        bytes32 seedSlot = keccak256(abi.encode(epoch, uint256(0)));
        bytes32 configSlot = keccak256(abi.encode(epoch, uint256(3)));
        bytes32 config = verificationConfigId();
        assembly { sstore(seedSlot, seed) sstore(configSlot, config) }
    }

    function clearCache(uint48 epoch) external {
        bytes32 seedSlot = keccak256(abi.encode(epoch, uint256(0)));
        bytes32 configSlot = keccak256(abi.encode(epoch, uint256(3)));
        assembly { sstore(seedSlot, 0) sstore(configSlot, 0) }
    }
}

contract ZoruCryptoVerificationTest {
    CryptoVm constant vm = CryptoVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant P = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    uint256 constant Q = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 constant GENESIS = 1727521075;
    bytes constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";

    function make(uint64 round) internal returns (ZoruDrandBeacon beacon, ZoruAdminAdapter admin, address logic) {
        admin = new ZoruAdminAdapter(new ZoruToken(address(this)));
        logic = address(new ZoruDrandBeacon());
        beacon = ZoruDrandBeacon(admin.deployProxy(logic, abi.encodeCall(ZoruDrandBeacon.initialize, (GENESIS + (uint256(round) - 1) * 3))));
    }

    function testGoOracleHashPointsAndOfficialRounds() public {
        for (uint256 i; i < 3; ++i) {
            (uint64 round, bytes memory sig, bytes32 seed, bytes memory expected) = CryptoOracleVectors.roundVector(i);
            BLS.PointG1 memory point = BLS.hashToPoint(DST, abi.encodePacked(keccak256(abi.encodePacked(round))));
            require(keccak256(BLS.g1Marshal(point)) == keccak256(expected), "Go hash point mismatch");
            (ZoruDrandBeacon beacon,,) = make(round);
            vm.warp(beacon.releaseTime(0));
            require(beacon.publish(0, sig) == seed && seed == sha256(sig), "official round");
        }
        for (uint256 i; i < 4; ++i) {
            (bytes memory msg_, bytes memory expected) = CryptoOracleVectors.hashVector(i);
            require(keccak256(BLS.g1Marshal(BLS.hashToPoint(DST, msg_))) == keccak256(expected), "independent generic vector");
        }
    }

    function testEverySignatureBitRejectsWithoutCacheMutation() public {
        for (uint256 vector; vector < 3; ++vector) {
            (uint64 round, bytes memory original,,) = CryptoOracleVectors.roundVector(vector);
            (ZoruDrandBeacon beacon,,) = make(round);
            vm.warp(beacon.releaseTime(0));
            for (uint256 bit; bit < 512; ++bit) {
                bytes memory bad = abi.encodePacked(original);
                bad[bit / 8] = bytes1(uint8(bad[bit / 8]) ^ uint8(1 << (bit % 8)));
                (bool ok,) = address(beacon).call(abi.encodeCall(beacon.publish, (0, bad)));
                require(!ok && beacon.verifiedSeed(0) == bytes32(0), "mutated bit accepted or cached");
            }
        }
    }

    function testIndependentRfcExpansionAndFieldVectors() public pure {
        for (uint256 i; i < 4; ++i) {
            (bytes memory message,) = CryptoOracleVectors.hashVector(i);
            (bytes memory expanded, uint256[2] memory field) = CryptoOracleVectors.expansionVector(i);
            require(keccak256(BLS.expandMsgTo96(DST, message)) == keccak256(expanded), "independent XMD");
            uint256[2] memory actual = BLS.hashToField(DST, message);
            require(actual[0] == field[0] && actual[1] == field[1], "48-byte field reduction");
        }
    }

    function testLengthsCoordinatesSwapAndRoundReplayReject() public {
        (uint64 round, bytes memory sig,,) = CryptoOracleVectors.roundVector(0);
        (ZoruDrandBeacon beacon,,) = make(round);
        vm.warp(beacon.releaseTime(2));
        uint256[7] memory boundaries = [uint256(0), 1, P - 1, P, P + 1, Q, type(uint256).max];
        for (uint256 i; i < boundaries.length; ++i) {
            for (uint256 j; j < boundaries.length; ++j) {
                (bool ok,) = address(beacon).call(abi.encodeCall(beacon.publish, (0, abi.encode(boundaries[i], boundaries[j]))));
                require(!ok, "boundary coordinate accepted");
            }
        }
        for (uint256 length; length < 67; ++length) {
            if (length == 64) continue;
            (bool ok,) = address(beacon).call(abi.encodeCall(beacon.publish, (0, new bytes(length))));
            require(!ok, "invalid signature length");
        }
        BLS.PointG1 memory point = BLS.g1Unmarshal(sig);
        (bool swapped,) = address(beacon).call(abi.encodeCall(beacon.publish, (0, abi.encode(point.y, point.x))));
        (bool replay,) = address(beacon).call(abi.encodeCall(beacon.publish, (1, sig)));
        require(!swapped && !replay && beacon.verifiedSeed(0) == bytes32(0), "swap/replay");
    }

    function testOnCurveForgeriesAndNegatedSignatureReject() public {
        (uint64 round, bytes memory sig,,) = CryptoOracleVectors.roundVector(0);
        (ZoruDrandBeacon beacon,,) = make(round);
        vm.warp(beacon.releaseTime(0));
        for (uint256 scalar = 1; scalar <= 32; ++scalar) {
            (bool multiplied, bytes memory forged) = address(7).staticcall(abi.encode(uint256(1), uint256(2), scalar));
            require(multiplied && forged.length == 64, "independent EIP196 point");
            (bool ok,) = address(beacon).call{gas: 800000}(abi.encodeCall(beacon.publish, (0, forged)));
            require(!ok && beacon.verifiedSeed(0) == bytes32(0), "on-curve forgery");
        }
        BLS.PointG1 memory point = BLS.g1Unmarshal(sig);
        (bool accepted,) = address(beacon).call(abi.encodeCall(beacon.publish, (0, abi.encode(point.x, P - point.y))));
        require(!accepted, "negated signature");
        (accepted,) = address(beacon).call(abi.encodeCall(beacon.publish, (0, abi.encode(point.x + P, point.y))));
        require(!accepted && beacon.verifiedSeed(0) == bytes32(0), "noncanonical equivalent");
    }

    function testWrongDstRoundWidthAndKeyCannotVerify() public {
        (uint64 round, bytes memory sig,,) = CryptoOracleVectors.roundVector(0);
        (ZoruDrandBeacon beacon,,) = make(round);
        BLS.PointG1 memory signature = BLS.g1Unmarshal(sig);
        (bool accepted,) = BLS.verifySingle(signature, beacon.publicKey(), BLS.hashToPoint(bytes("WRONG_DST"), abi.encodePacked(keccak256(abi.encodePacked(round)))));
        require(!accepted, "wrong DST");
        (accepted,) = BLS.verifySingle(signature, beacon.publicKey(), BLS.hashToPoint(DST, abi.encodePacked(keccak256(abi.encode(round)))));
        require(!accepted, "32-byte round");
        BLS.PointG2 memory key = beacon.publicKey();
        (key.x[0], key.x[1]) = (key.x[1], key.x[0]);
        (accepted,) = BLS.verifySingle(signature, key, BLS.hashToPoint(DST, abi.encodePacked(keccak256(abi.encodePacked(round)))));
        require(!accepted, "wrong G2 limb order");
    }

    function testPairingRejectsOnCurveWrongSubgroupG2() public view {
        BLS.PointG2 memory bad = BLS.PointG2([uint256(2), uint256(1)], [uint256(7292567877523311580221095596750716176434782432868683424513645834767876293070), uint256(19659275751359636165940301690575149581329631496732780143538578556285923319774)]);
        require(BLS.isValidPointG2(bad), "fixture must pass curve-only helper");
        (bool ok,) = address(8).staticcall{gas: 250000}(abi.encode(uint256(1), uint256(2), bad.x[1], bad.x[0], bad.y[1], bad.y[0]));
        require(!ok, "non-subgroup pairing input accepted");
        (ok,) = address(8).staticcall{gas: 250000}(abi.encode(uint256(0), uint256(0), bad.x[1], bad.x[0], bad.y[1], bad.y[0]));
        require(!ok, "infinite G1 must not bypass G2 membership");
    }

    function testG2CoordinateFieldBoundsAndInfinitySemantics() public {
        (ZoruDrandBeacon beacon,,) = make(1000000);
        BLS.PointG2 memory key = beacon.publicKey();
        uint256[6] memory original = [uint256(1), uint256(2), key.x[1], key.x[0], key.y[1], key.y[0]];
        for (uint256 coordinate = 2; coordinate < 6; ++coordinate) {
            for (uint256 delta; delta < 3; ++delta) {
                uint256[6] memory input;
                for (uint256 i; i < 6; ++i) input[i] = original[i];
                input[coordinate] = P - 1 + delta;
                (bool coordinateAccepted,) = address(8).staticcall{gas: 150000}(abi.encode(input));
                require(!coordinateAccepted, "invalid G2 field coordinate");
            }
        }
        (bool ok, bytes memory output) = address(8).staticcall(abi.encode(uint256(1), uint256(2), uint256(0), uint256(0), uint256(0), uint256(0)));
        require(ok && abi.decode(output, (uint256)) == 1, "EIP197 infinity is neutral; wrapper must bind its fixed nonzero key");
    }

    function testPrecompileConformanceAndEmptyPairingNotAPublishProof() public {
        require(P != Q, "field and group orders");
        (bool ok, bytes memory output) = address(8).staticcall("");
        require(ok && output.length == 32 && abi.decode(output, (uint256)) == 1, "EIP197 empty product");
        (ok,) = address(8).staticcall{gas: 100000}(hex"01");
        require(!ok, "pairing malformed length");
        (ok, output) = address(7).staticcall(abi.encode(uint256(1), uint256(2), Q));
        require(ok && output.length == 64 && keccak256(output) == keccak256(new bytes(64)), "G1 cofactor/order");
        (ok,) = address(6).staticcall{gas: 10000}(abi.encode(P, uint256(2), uint256(0), uint256(0)));
        require(!ok, "noncanonical field");
        (ZoruDrandBeacon beacon,,) = make(1000000);
        vm.warp(beacon.releaseTime(0));
        (ok,) = address(beacon).call(abi.encodeCall(beacon.publish, (0, new bytes(0))));
        require(!ok, "empty proof");
        (ok,) = address(beacon).call(abi.encodeCall(beacon.publish, (0, new bytes(64))));
        require(!ok && beacon.verifiedSeed(0) == bytes32(0), "infinity proof");
    }

    function testLowGasFailureCannotPoisonCache() public {
        (uint64 round, bytes memory sig, bytes32 seed,) = CryptoOracleVectors.roundVector(0);
        (ZoruDrandBeacon beacon,,) = make(round);
        vm.warp(beacon.releaseTime(0));
        (bool ok,) = address(beacon).call{gas: 30000}(abi.encodeCall(beacon.publish, (0, sig)));
        require(!ok && beacon.verifiedSeed(0) == bytes32(0), "gas failure cached");
        require(beacon.publish(0, sig) == seed, "valid retry");
    }

    function testCacheKeyChangeAndRollbackUseSameProxy() public {
        (uint64 round, bytes memory sig, bytes32 seed,) = CryptoOracleVectors.roundVector(0);
        (ZoruDrandBeacon beacon, ZoruAdminAdapter admin, address original) = make(round);
        vm.warp(beacon.releaseTime(0));
        beacon.publish(0, sig);
        bytes32 config = beacon.verificationConfigId();
        admin.upgrade(address(beacon), address(new DifferentCryptoKey()), "");
        require(beacon.verificationConfigId() != config && beacon.verifiedSeed(0) == bytes32(0), "old key cache reused");
        (bool ok,) = address(beacon).call(abi.encodeCall(beacon.publish, (0, sig)));
        require(!ok && beacon.verifiedSeed(0) == bytes32(0), "invalid new key cache");
        admin.upgrade(address(beacon), original, "");
        require(beacon.verificationConfigId() == config && beacon.verifiedSeed(0) == seed, "rollback valid cache");
    }

    function testUnsafeVerifierCacheIsNotTrustedAfterRestoringHonestCode() public {
        (uint64 round, bytes memory sig, bytes32 validSeed,) = CryptoOracleVectors.roundVector(0);
        (ZoruDrandBeacon beacon, ZoruAdminAdapter admin, address original) = make(round);
        vm.warp(beacon.releaseTime(0));
        bytes32 fake = keccak256("deliberately corrupted test cache");
        CryptoCacheRepairFixture unsafeLogic = new CryptoCacheRepairFixture();
        admin.upgrade(address(beacon), address(unsafeLogic), abi.encodeCall(unsafeLogic.writeCache, (0, fake)));
        admin.upgrade(address(beacon), original, "");
        // A new implementation cannot infer that matching old cache data was corrupt.
        require(beacon.verifiedSeed(0) == bytes32(0), "old verifier cache must be rejected");
        (bool unauthorized,) = address(beacon).call(abi.encodeCall(unsafeLogic.writeCache, (0, fake)));
        require(!unauthorized, "honest implementation must not expose cache writes");
        admin.upgrade(address(beacon), address(unsafeLogic), abi.encodeCall(unsafeLogic.clearCache, (0)));
        admin.upgrade(address(beacon), original, "");
        require(beacon.verifiedSeed(0) == bytes32(0), "explicit cache invalidation");
        require(beacon.publish(0, sig) == validSeed, "authenticated publication after repair");
    }

    function testRoundBoundsAndReleaseBoundary() public {
        (ZoruDrandBeacon beacon,,) = make(1000000);
        require(beacon.expectedRound(type(uint48).max) == uint64(uint256(1000000) + uint256(type(uint48).max) * 20), "round overflow");
        (,,bytes32 seed,) = CryptoOracleVectors.roundVector(1);
        (,bytes memory sig,,) = CryptoOracleVectors.roundVector(1);
        vm.warp(beacon.releaseTime(1) - 1);
        (bool ok,) = address(beacon).call(abi.encodeCall(beacon.publish, (1, sig)));
        require(!ok, "early release");
        vm.warp(beacon.releaseTime(1));
        require(beacon.publish(1, sig) == seed, "boundary round");
        ZoruAdminAdapter admin = new ZoruAdminAdapter(new ZoruToken(address(this)));
        address implementation = address(new ZoruDrandBeacon());
        vm.expectRevert();
        admin.deployProxy(implementation, abi.encodeCall(ZoruDrandBeacon.initialize, (GENESIS - 1)));
    }

    function testFuzzFieldMappingInverseAndSquareRoot(uint256 raw) public view {
        uint256 u = raw % P;
        uint256[2] memory point = BLS.mapToPoint(u);
        require(BLS.isValidPointG1(BLS.PointG1(point[0], point[1])), "map off curve");
        uint256 inverse = BLS.inverse(u);
        require(u == 0 ? inverse == 0 : mulmod(u, inverse, P) == 1, "inverse");
        uint256 square = mulmod(u, u, P);
        (uint256 root, bool exists) = BLS.sqrt(square);
        require(exists && mulmod(root, root, P) == square, "sqrt");
    }
}

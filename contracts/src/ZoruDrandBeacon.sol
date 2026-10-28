// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IZoruBeaconSource} from "./IZoruMining.sol";
import {BLS} from "zoru-evmnet/BLS.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

interface IBeaconProxyAdminOwner {
    function owner() external view returns (address);
}

interface IBeaconSuiteRevision {
    function beaconProxy() external view returns (address);
    function suiteRevision() external view returns (uint256);
}

/// @notice Authenticated, scheduled drand evmnet round adapter.
/// @dev PROTOTYPE ONLY: BLS library is experimental and unaudited.
/// No owner writes randomness. Anybody can publish a valid signed round.
/// Launch must be set before the first scheduled round is published.
contract ZoruDrandBeacon is IZoruBeaconSource, Initializable {
    uint256 public constant DRAND_GENESIS = 1_727_521_075;
    uint256 public constant DRAND_PERIOD = 3;
    uint256 public constant ZORU_EPOCH_PERIOD = 60;
    uint256 public constant DRAND_ROUNDS_PER_EPOCH = 20;
    bytes32 public constant CHAIN_HASH = hex"04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3";
    string public constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";

    // Keep the original cache at slot 0. Config is proxy storage, not code immutables.
    mapping(uint48 => bytes32) private cachedSeed;
    uint256 public launchTime;
    uint64 public launchRound;
    mapping(uint48 => bytes32) private cachedConfig;

    error InvalidLaunch();
    error InvalidSignatureLength();
    error InvalidRound();
    error InvalidSignature();
    error NotYetReleased();
    error AlreadyPublished();
    error OnlyProxyAdmin();
    error InvalidBatch();

    event BeaconPublished(uint48 indexed epoch, uint64 indexed round, bytes32 randomness);
    event BeaconCacheInvalidated(uint48 indexed epoch);

    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 launchTime_) external initializer {
        if (
            launchTime_ < DRAND_GENESIS || (launchTime_ - DRAND_GENESIS) % DRAND_PERIOD != 0
                || launchTime_ > type(uint64).max
        ) revert InvalidLaunch();
        launchTime = launchTime_;
        uint256 first = (launchTime_ - DRAND_GENESIS) / DRAND_PERIOD + 1;
        if (first > type(uint64).max - type(uint48).max * DRAND_ROUNDS_PER_EPOCH) revert InvalidLaunch();
        launchRound = uint64(first);
    }

    function verificationConfigId() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                CHAIN_HASH,
                keccak256(bytes(DST)),
                publicKey(),
                DRAND_GENESIS,
                DRAND_PERIOD,
                ZORU_EPOCH_PERIOD,
                DRAND_ROUNDS_PER_EPOCH,
                launchTime,
                launchRound
            )
        );
    }

    /// @notice Identifies cache entries verified by this implementation in this suite revision.
    /// @dev Upgrading the Beacon changes its implementation, and a coordinated suite upgrade
    /// also advances the revision. Older entries become unreadable without iterating epochs.
    /// The verifier configuration ID remains independent of the implementation revision.
    function cacheTrustId() public view returns (bytes32) {
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address implementation;
        assembly {
            implementation := sload(implementationSlot)
        }

        address proxyAdmin =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"01")))));
        uint256 revision;
        if (proxyAdmin.code.length != 0) {
            address coordinator = IBeaconProxyAdminOwner(proxyAdmin).owner();
            if (IBeaconSuiteRevision(coordinator).beaconProxy() == address(this)) {
                revision = IBeaconSuiteRevision(coordinator).suiteRevision();
                if (revision == 0) revert InvalidRound();
            }
        }
        return keccak256(
            abi.encode("ZORU_AUTHENTICATED_CACHE", verificationConfigId(), address(this), implementation, revision)
        );
    }

    function verifiedSeed(uint48 epoch) external view override returns (bytes32) {
        return cachedConfig[epoch] == cacheTrustId() ? cachedSeed[epoch] : bytes32(0);
    }

    /// @notice Clears selected cached results during an owner-authorized proxy upgrade.
    /// @dev Callable only through the actual ProxyAdmin upgrade-and-call path.
    /// Keep the batch bounded so an oversized repair cannot exhaust the transaction.
    function invalidateEpochs(uint48[] calldata epochs) external {
        address proxyAdmin =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"01")))));
        if (msg.sender != proxyAdmin) revert OnlyProxyAdmin();
        if (epochs.length == 0 || epochs.length > 64) revert InvalidBatch();

        for (uint256 i = 0; i < epochs.length; ++i) {
            delete cachedSeed[epochs[i]];
            delete cachedConfig[epochs[i]];
            emit BeaconCacheInvalidated(epochs[i]);
        }
    }

    function expectedRound(uint48 epoch) public view returns (uint64) {
        return uint64(uint256(launchRound) + uint256(epoch) * DRAND_ROUNDS_PER_EPOCH);
    }

    function releaseTime(uint48 epoch) public view override returns (uint256) {
        return launchTime + uint256(epoch) * ZORU_EPOCH_PERIOD;
    }

    function publicKey() public pure virtual returns (BLS.PointG2 memory) {
        return BLS.PointG2(
            [
                0x557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f,
                0x7e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382
            ],
            [
                0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b,
                0x95685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6
            ]
        );
    }

    /// @notice Public signature publication; accepts ONLY the predetermined
    /// signed round for this epoch. Gas paid by sender of this transaction.
    function publish(uint48 epoch, bytes calldata signature) external returns (bytes32 randomness) {
        if (block.timestamp < releaseTime(epoch)) revert NotYetReleased();
        bytes32 config = cacheTrustId();
        if (cachedSeed[epoch] != bytes32(0) && cachedConfig[epoch] == config) revert AlreadyPublished();
        if (signature.length != 64) revert InvalidSignatureLength();

        uint64 round = expectedRound(epoch);
        if (round == 0) revert InvalidRound();
        BLS.PointG1 memory point = BLS.g1Unmarshal(signature);
        if (!BLS.isValidPointG1(point)) revert InvalidSignature();
        (bool pairingSuccess, bool callSuccess) = BLS.verifySingle(
            point, publicKey(), BLS.hashToPoint(bytes(DST), abi.encodePacked(keccak256(abi.encodePacked(round))))
        );
        if (!pairingSuccess || !callSuccess) revert InvalidSignature();

        randomness = sha256(signature);
        if (randomness == bytes32(0)) revert InvalidSignature();
        cachedSeed[epoch] = randomness;
        cachedConfig[epoch] = config;
        emit BeaconPublished(epoch, round, randomness);
    }
}

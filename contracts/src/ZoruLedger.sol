// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ZoruToken} from "./ZoruToken.sol";
import {IZoruBeaconSource, IZoruWorkEngine} from "./IZoruMining.sol";
import {IZoruUpgradeCoordinator} from "./IZoruUpgrade.sol";

/// @notice Multi-proof epoch accounting and claim accounting. NOT AUDITED.
/// @dev A production deployment MUST use an independently audited on-chain
///      authenticated unpredictable future beacon. MockBeacon is TEST ONLY.
///      All mining policy lives here, outside the immutable token. External
///      transparent proxy administration must remain independent of this code.
contract ZoruLedger is Initializable {
    uint256 public constant CAP = 21_000_000 * 1e8;
    uint256 public constant INITIAL_BUDGET = 5 * 1e8;
    uint256 public constant HALVING_EPOCHS = 2_100_000;
    uint256 public constant NORMAL_ERAS = 29;
    uint256 public constant NORMAL_REWARD_EPOCHS = NORMAL_ERAS * HALVING_EPOCHS;
    uint256 public constant TERMINAL_DUST = 27_300_000;
    uint256 public constant EPOCH_SECONDS = 60;
    uint256 public constant DESIRED_PROOFS = 60;
    uint256 public constant MAX_TARGET = type(uint256).max >> 16;
    uint256 public constant MODULE_CALL_GAS = 100_000;
    bytes32 public constant PROOF_DOMAIN = keccak256("ZORU-FLOWPOW-PROOF-1");

    struct Epoch {
        uint256 target;
        bytes32 seed;
        uint256 budget;
        uint256 proofCount;
        uint256 verifiedWorkEstimate;
        address engine;
        bool isSealed;
        address beaconSource;
        uint256 generation;
        uint256 closesAt;
    }

    struct AcceptedProof {
        address beneficiary;
        uint48 epoch;
        uint256 indexPlusOne;
        bool claimed;
    }

    ZoruToken public token;
    IZoruBeaconSource public beacon;
    IZoruWorkEngine public engine;
    uint256 public launchTime;
    uint256 public initialTarget;
    uint256 public emissionIndex;
    uint256 public allocatedSupply;
    /// @notice Total funded epoch budgets, including external token top-ups.
    uint256 public fundedSupply;
    uint256 public paidSupply;
    uint256 public totalProofs;
    uint256 public networkWorkEstimate;
    uint48 public lastOpenedEpoch;
    bool public hasOpened;
    bool public admissionPaused;
    bool public claimsPaused;
    bool private entered;

    mapping(uint48 => Epoch) private epochs;
    mapping(bytes32 => AcceptedProof) public proofs;

    uint256 public moduleGeneration;
    address public protocolAdmin;

    error OnlyOwner();
    error Paused();
    error Reentered();
    error InvalidConfiguration();
    error InvalidEpoch();
    error InvalidProof();
    error DuplicateProof();
    error EpochNotClosed();
    error AlreadySealed();
    error NotClaimable();
    error NoMoreEmission();
    error InactiveIssuer();
    error FundingUnavailable();
    error Insolvent();
    error PermanentProxyAddresses();
    error UpgradePending();
    error OnlyCoordinator();

    /// @dev The beneficiary field is an ADDRESS, not a verified human/device.
    ///      Clients may count DISTINCT addresses in logs; Sybil splitting is cheap.
    event ProofAccepted(
        uint48 indexed epoch, bytes32 indexed digest, address indexed beneficiary, uint256 index, uint256 generation
    );
    event EpochSealed(uint48 indexed epoch, uint256 mintedAmount, uint256 proofCount);
    event RewardClaimed(uint48 indexed epoch, bytes32 indexed digest, address indexed beneficiary, uint256 amount);
    event EpochOpened(uint48 indexed epoch, uint256 target, address engine, address beacon, uint256 generation);
    event ModulesRecovered(uint48 indexed epoch, address engine, address beacon, uint256 generation);

    modifier onlyOwner() {
        if (msg.sender != token.owner()) revert OnlyOwner();
        _;
    }
    modifier nonReentrant() {
        if (entered) revert Reentered();
        entered = true;
        _;
        entered = false;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        ZoruToken token_,
        IZoruBeaconSource beacon_,
        IZoruWorkEngine engine_,
        uint256 launchTime_,
        uint256 initialTarget_
    ) external initializer {
        if (
            address(token_).code.length == 0 || address(beacon_).code.length == 0 || address(engine_).code.length == 0
                || launchTime_ <= block.timestamp || initialTarget_ == 0 || initialTarget_ > MAX_TARGET
        ) revert InvalidConfiguration();
        token = token_;
        beacon = beacon_;
        engine = engine_;
        launchTime = launchTime_;
        initialTarget = initialTarget_;
        moduleGeneration = 1;
    }

    function epochNow() public view returns (uint48) {
        if (block.timestamp < launchTime) revert InvalidEpoch();
        uint256 current = (block.timestamp - launchTime) / EPOCH_SECONDS;
        if (current > type(uint48).max) revert InvalidEpoch();
        return uint48(current);
    }

    function budgetForIndex(uint256 index) public pure virtual returns (uint256) {
        if (index < NORMAL_REWARD_EPOCHS) {
            return INITIAL_BUDGET >> (index / HALVING_EPOCHS);
        }
        return index == NORMAL_REWARD_EPOCHS ? TERMINAL_DUST : 0;
    }

    function epochInfo(uint48 epoch) external view returns (Epoch memory) {
        return epochs[epoch];
    }

    /// @notice One-time suite binding after all three proxy constructors finish.
    /// No function can replace the public engine/beacon pointer thereafter.
    function bindPermanentProxies(address coordinator) external {
        if (protocolAdmin != address(0) || msg.sender != coordinator) revert OnlyCoordinator();
        _checkCoordinator(coordinator);
        protocolAdmin = coordinator;
        moduleGeneration = IZoruUpgradeCoordinator(coordinator).suiteRevision();
    }

    function _checkCoordinator(address coordinator) internal view {
        IZoruUpgradeCoordinator c = IZoruUpgradeCoordinator(coordinator);
        if (
            c.token() != address(token) || c.ledgerProxy() != address(this) || c.engineProxy() != address(engine)
                || c.beaconProxy() != address(beacon)
        ) revert PermanentProxyAddresses();
        address actualAdmin = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"01")))));
        if (c.adminOf(address(this)) != actualAdmin) revert OnlyCoordinator();
        (bool ok, bytes memory result) = actualAdmin.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || result.length != 32 || abi.decode(result, (address)) != coordinator) revert OnlyCoordinator();
    }

    /// @notice Only actual external ProxyAdmin may adopt a replacement coordinator.
    /// This can be called in upgradeAndCall after a broken ledger is replaced.
    function adoptUpgradeCoordinator(address next) external {
        address actualAdmin = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"01")))));
        if (msg.sender != actualAdmin) revert OnlyCoordinator();
        _checkCoordinator(next);
        protocolAdmin = next;
    }

    function onImplementationUpgrade(uint256 revision, bool emergency) external nonReentrant {
        if (msg.sender != protocolAdmin || protocolAdmin == address(0)) revert OnlyCoordinator();
        _checkCoordinator(protocolAdmin);
        if (revision <= moduleGeneration || revision != IZoruUpgradeCoordinator(protocolAdmin).suiteRevision()) {
            revert InvalidConfiguration();
        }
        if (block.timestamp >= launchTime) {
            uint48 current = epochNow();
            Epoch storage active = epochs[current];
            if (!emergency && hasOpened && current < lastOpenedEpoch) revert InvalidEpoch();
            if (!emergency && active.proofCount != 0) revert InvalidEpoch();
            if (active.target != 0 && !active.isSealed && (!hasOpened || current >= lastOpenedEpoch)) {
                active.generation = revision;
                active.seed = bytes32(0);
                // Addresses themselves remain the original public proxies.
                active.engine = address(engine);
                active.beaconSource = address(beacon);
            }
            emit ModulesRecovered(current, address(engine), address(beacon), revision);
        }
        moduleGeneration = revision;
    }

    function _checkWork(uint48 epoch) internal view {
        if (protocolAdmin == address(0) || !IZoruUpgradeCoordinator(protocolAdmin).workActive(epoch, moduleGeneration)) revert UpgradePending();
    }

    function setAdmissionPaused(bool paused) external onlyOwner {
        admissionPaused = paused;
    }

    function setClaimsPaused(bool paused) external onlyOwner {
        claimsPaused = paused;
    }

    function digestFor(uint48 epoch, bytes32 seed, address beneficiary, uint256 nonce) public view returns (bytes32) {
        uint256 generation = epochs[epoch].generation;
        if (generation == 0) {
            generation = moduleGeneration;
        }
        return keccak256(
            abi.encode(
                PROOF_DOMAIN, block.chainid, address(this), address(token), generation, epoch, seed, beneficiary, nonce
            )
        );
    }

    function _targetForNewEpoch(uint48 epoch) internal view returns (uint256) {
        // Before the FIRST ever opened epoch, time-based recovery must
        // still occur: otherwise an overly hard initialTarget bricks mining.
        if (!hasOpened) {
            uint256 initialSkipped = uint256(epoch);
            if (initialSkipped >= 128) return MAX_TARGET;
            uint256 firstShift = initialSkipped * 2;
            if (firstShift >= 256 || initialTarget > (MAX_TARGET >> firstShift)) return MAX_TARGET;
            return initialTarget << firstShift;
        }
        Epoch storage previous = epochs[lastOpenedEpoch];
        uint256 target = previous.target;
        uint256 observed = previous.proofCount;
        uint256 candidate = Math.mulDiv(target, DESIRED_PROOFS, observed == 0 ? 1 : observed);
        uint256 low = target / 4;
        if (low == 0) low = 1;
        uint256 high = target > MAX_TARGET / 4 ? MAX_TARGET : target * 4;
        target = candidate < low ? low : (candidate > high ? high : candidate);

        uint48 skipped = epoch - lastOpenedEpoch - 1;
        // Constant-bounded saturation, never loop through empty epochs.
        if (skipped >= 128) return MAX_TARGET;
        if (skipped != 0) {
            uint256 shift = uint256(skipped) * 2;
            if (shift >= 256 || target > (MAX_TARGET >> shift)) return MAX_TARGET;
            target <<= shift;
        }
        return target > MAX_TARGET ? MAX_TARGET : target;
    }

    function targetForEpoch(uint48 epoch) external view returns (uint256) {
        if (epoch != epochNow()) revert InvalidEpoch();
        if ((hasOpened && epoch < lastOpenedEpoch) || epochs[epoch].isSealed) revert InvalidEpoch();
        _checkWork(epoch);
        return epochs[epoch].target == 0 ? _targetForNewEpoch(epoch) : epochs[epoch].target;
    }

    /// @notice Clock-only progress needs neither proof nor a working beacon.
    function openEpoch(uint48 epoch) external nonReentrant returns (uint256) {
        if (epoch != epochNow()) revert InvalidEpoch();
        return _openEpoch(epoch).target;
    }

    function _openEpoch(uint48 epoch) internal returns (Epoch storage state) {
        _checkWork(epoch);
        if (hasOpened && epoch < lastOpenedEpoch) revert InvalidEpoch();
        state = epochs[epoch];
        if (state.isSealed) revert InvalidEpoch();
        if (state.target != 0) return state;
        uint256 target = _targetForNewEpoch(epoch);
        state.target = target;
        state.engine = address(engine);
        state.beaconSource = address(beacon);
        state.generation = moduleGeneration;
        state.closesAt = launchTime + (uint256(epoch) + 1) * EPOCH_SECONDS;
        lastOpenedEpoch = epoch;
        hasOpened = true;
        emit EpochOpened(epoch, target, state.engine, state.beaconSource, state.generation);
    }

    function fundedLiability() public view returns (uint256) {
        return fundedSupply - paidSupply;
    }

    function unfundedLiability() public view returns (uint256) {
        return allocatedSupply - fundedSupply;
    }

    function freeBalance() public view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        uint256 owed = fundedLiability();
        if (balance < owed) revert Insolvent();
        return balance - owed;
    }

    /// @notice Multiple proofs are accepted per epoch; no pending single winner.
    /// @dev Proof is subject to transaction inclusion time, not local discovery time.
    function submit(uint48 epoch, address beneficiary, uint256 nonce) external nonReentrant returns (bytes32 digest) {
        if (admissionPaused) revert Paused();
        if (token.issuer() != address(this)) revert InactiveIssuer();
        if (beneficiary == address(0) || epoch != epochNow()) revert InvalidEpoch();
        Epoch storage state = _openEpoch(epoch);
        bool first = state.proofCount == 0;
        if (state.seed == bytes32(0)) {
            if (
                IZoruBeaconSource(state.beaconSource).releaseTime{gas: MODULE_CALL_GAS}(epoch)
                    != launchTime + uint256(epoch) * EPOCH_SECONDS
            ) revert InvalidConfiguration();
            state.seed = IZoruBeaconSource(state.beaconSource).verifiedSeed{gas: MODULE_CALL_GAS}(epoch);
            if (state.seed == bytes32(0)) revert InvalidProof();
        }
        digest = digestFor(epoch, state.seed, beneficiary, nonce);
        if (proofs[digest].indexPlusOne != 0) revert DuplicateProof();
        if (!IZoruWorkEngine(state.engine).valid{gas: MODULE_CALL_GAS}(digest, state.target)) revert InvalidProof();
        if (first) {
            uint256 budget = budgetForIndex(emissionIndex);
            uint256 pending = unfundedLiability();
            uint256 capacity = token.MAX_SUPPLY() - token.lifetimeMinted() + freeBalance();
            if (budget == 0 || pending > capacity || budget > capacity - pending || budget > CAP - allocatedSupply) {
                revert NoMoreEmission();
            }
            state.budget = budget;
            allocatedSupply += budget;
            emissionIndex++;
        }
        uint256 index = state.proofCount++;
        proofs[digest] = AcceptedProof(beneficiary, epoch, index + 1, false);
        // This is an expected-work estimate derived from accepted proofs, not CPU measurements.
        uint256 estimated = type(uint256).max / state.target;
        // Saturate telemetry rather than disable admission at extreme difficulty.
        // These counters are estimates and must not govern reward issuance.
        state.verifiedWorkEstimate = _saturatingAdd(state.verifiedWorkEstimate, estimated);
        networkWorkEstimate = _saturatingAdd(networkWorkEstimate, estimated);
        totalProofs++;
        emit ProofAccepted(epoch, digest, beneficiary, index, state.generation);
    }

    function _saturatingAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        return b > type(uint256).max - a ? type(uint256).max : a + b;
    }

    /// @notice Independent of ongoing work in newer epochs. Caller funds gas.
    function seal(uint48 epoch) external nonReentrant {
        Epoch storage state = epochs[epoch];
        if (state.target == 0 || block.timestamp < state.closesAt) revert EpochNotClosed();
        if (state.proofCount == 0 || state.isSealed) revert AlreadySealed();
        uint256 available = freeBalance();
        uint256 deficit = available >= state.budget ? 0 : state.budget - available;
        if (deficit != 0 && token.issuer() != address(this)) revert FundingUnavailable();
        state.isSealed = true;
        fundedSupply += state.budget;
        // Top-ups fund revoked issuers without re-authorizing them. Existing
        // backing for other sealed claims is excluded from freeBalance().
        if (deficit != 0) token.mint(address(this), deficit);
        emit EpochSealed(epoch, state.budget, state.proofCount);
    }

    function claim(bytes32 digest) external nonReentrant returns (uint256 amount) {
        if (claimsPaused) revert Paused();
        if (token.balanceOf(address(this)) < fundedLiability()) revert Insolvent();
        AcceptedProof storage proof = proofs[digest];
        if (proof.indexPlusOne == 0 || proof.claimed) revert NotClaimable();
        Epoch storage state = epochs[proof.epoch];
        if (!state.isSealed) revert NotClaimable();
        uint256 index = proof.indexPlusOne - 1;
        amount =
            Math.mulDiv(state.budget, index + 1, state.proofCount) - Math.mulDiv(state.budget, index, state.proofCount);
        proof.claimed = true;
        paidSupply += amount;
        require(token.transfer(proof.beneficiary, amount), "ZORU_TRANSFER_FAILED");
        emit RewardClaimed(proof.epoch, digest, proof.beneficiary, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ZoruToken} from "./ZoruToken.sol";
import {IZoruStableLedger, IZoruUpgradeCoordinator} from "./IZoruUpgrade.sol";

/// @notice Single-owner external upgrades. Suite proxy addresses never change.
/// @dev OWNER-MANAGED UPGRADE MODULE. Normal upgrades are epoch-coordinated; emergency
/// upgrades never require a successful call to old implementation code.
contract ZoruAdminAdapter {
    ZoruToken public immutable token;
    mapping(address => address) public adminOf;
    mapping(address => address) public implementationOf;
    address public ledgerProxy;
    address public engineProxy;
    address public beaconProxy;
    uint256 public suiteRevision;
    bool public recoveryRequired;
    uint256 public launchTime;
    uint256 public epochSeconds;
    bool private entered;
    address public authorizedPrevious;

    struct RevisionSnapshot {
        address ledgerImplementation;
        address engineImplementation;
        address beaconImplementation;
        bytes32 ledgerCodehash;
        bytes32 engineCodehash;
        bytes32 beaconCodehash;
    }
    mapping(uint256 => RevisionSnapshot) public revisionInfo;

    struct SuiteUpgrade {
        address ledgerImplementation;
        bytes ledgerData;
        address engineImplementation;
        bytes engineData;
        address beaconImplementation;
        bytes beaconData;
    }

    struct SuiteDeployment {
        address ledgerImplementation;
        address engineImplementation;
        bytes engineData;
        address beaconImplementation;
        bytes beaconData;
        uint256 launchTime;
        uint256 initialTarget;
    }
    SuiteUpgrade private pendingUpgrade;
    bool public hasPendingUpgrade;
    uint48 public activationEpoch;
    uint256 public activationTime;

    error OnlyOwner();
    error InvalidAdmin();
    error AlreadyRegistered();
    error SuiteAlreadyBound();
    error CoordinatedUpgradeRequired();
    error InvalidUpgrade();
    error NotReady();
    error RecoveryPending();
    error Reentered();

    event AdminRegistered(address indexed proxy, address indexed proxyAdmin);
    event ImplementationUpgraded(address indexed proxy, address indexed implementation);
    event AdminTransferred(address indexed proxy, address indexed nextAdapter);
    event SuiteBound(address indexed ledger, address indexed engine, address indexed beacon);
    event UpgradeScheduled(uint48 indexed epoch, uint256 release, bytes32 payloadHash);
    event UpgradeCancelled();
    event SuiteUpgraded(uint256 indexed revision, bool emergency, bool ledgerNotified);

    constructor(ZoruToken token_) {
        if (address(token_).code.length == 0) revert InvalidAdmin();
        token = token_;
    }
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

    function expectedProxyAdmin(address proxy) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }

    function registerProxy(address proxy, ProxyAdmin proxyAdmin) external onlyOwner nonReentrant {
        _register(proxy, proxyAdmin);
    }

    function _register(address proxy, ProxyAdmin proxyAdmin) internal {
        if (
            proxy.code.length == 0 || address(proxyAdmin).code.length == 0
                || address(proxyAdmin) != expectedProxyAdmin(proxy) || proxyAdmin.owner() != address(this)
        ) revert InvalidAdmin();
        if (adminOf[proxy] != address(0)) revert AlreadyRegistered();
        adminOf[proxy] = address(proxyAdmin);
        emit AdminRegistered(proxy, address(proxyAdmin));
    }

    function _deploy(address implementation, bytes memory data) internal returns (address proxy) {
        if (implementation.code.length == 0 || data.length == 0) revert InvalidAdmin();
        proxy = address(new TransparentUpgradeableProxy(implementation, address(this), data));
        _register(proxy, ProxyAdmin(expectedProxyAdmin(proxy)));
        implementationOf[proxy] = implementation;
    }

    function deployProxy(address implementation, bytes calldata data)
        external
        onlyOwner
        nonReentrant
        returns (address)
    {
        return _deploy(implementation, data);
    }

    function deploySuite(SuiteDeployment calldata d)
        external
        onlyOwner
        nonReentrant
        returns (address ledger, address engine, address beacon)
    {
        if (ledgerProxy != address(0)) revert SuiteAlreadyBound();
        engine = _deploy(d.engineImplementation, d.engineData);
        beacon = _deploy(d.beaconImplementation, d.beaconData);
        ledger = _deploy(
            d.ledgerImplementation,
            abi.encodeWithSignature(
                "initialize(address,address,address,uint256,uint256)",
                address(token),
                beacon,
                engine,
                d.launchTime,
                d.initialTarget
            )
        );
        _bind(ledger, engine, beacon);
    }

    function bindSuite(address ledger, address engine, address beacon) external onlyOwner nonReentrant {
        _bind(ledger, engine, beacon);
    }

    function _bind(address ledger, address engine, address beacon) internal {
        if (ledgerProxy != address(0)) revert SuiteAlreadyBound();
        if (
            ledger == engine || ledger == beacon || engine == beacon || adminOf[ledger] == address(0)
                || adminOf[engine] == address(0) || adminOf[beacon] == address(0)
        ) revert InvalidAdmin();
        if (
            implementationOf[ledger] == address(0) || implementationOf[engine] == address(0)
                || implementationOf[beacon] == address(0)
        ) revert InvalidAdmin();
        IZoruStableLedger l = IZoruStableLedger(ledger);
        if (l.token() != address(token) || l.engine() != engine || l.beacon() != beacon) revert InvalidAdmin();
        ledgerProxy = ledger;
        engineProxy = engine;
        beaconProxy = beacon;
        suiteRevision = 1;
        launchTime = l.launchTime();
        epochSeconds = l.EPOCH_SECONDS();
        if (epochSeconds == 0) revert InvalidAdmin();
        l.bindPermanentProxies(address(this));
        _recordRevision();
        emit SuiteBound(ledger, engine, beacon);
    }

    function _recordRevision() internal {
        address l = implementationOf[ledgerProxy];
        address e = implementationOf[engineProxy];
        address b = implementationOf[beaconProxy];
        revisionInfo[suiteRevision] = RevisionSnapshot(l, e, b, l.codehash, e.codehash, b.codehash);
    }

    function workActive(uint48 epoch, uint256 generation) external view returns (bool) {
        return ledgerProxy != address(0) && !recoveryRequired && generation == suiteRevision
            && (!hasPendingUpgrade || epoch < activationEpoch);
    }

    function _isSuite(address proxy) internal view returns (bool) {
        return proxy != address(0) && (proxy == ledgerProxy || proxy == engineProxy || proxy == beaconProxy);
    }

    /// @notice For ancillary proxies only. Suite proxies must use coordinated paths.
    function upgrade(address proxy, address implementation, bytes calldata data) external onlyOwner nonReentrant {
        if (_isSuite(proxy)) revert CoordinatedUpgradeRequired();
        _upgrade(proxy, implementation, data);
    }

    function _upgrade(address proxy, address implementation, bytes memory data) internal {
        address admin = adminOf[proxy];
        if (admin == address(0) || implementation.code.length == 0) revert InvalidAdmin();
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, data);
        implementationOf[proxy] = implementation;
        emit ImplementationUpgraded(proxy, implementation);
    }

    function _validate(SuiteUpgrade calldata u) internal view {
        bool changed;
        if (u.ledgerImplementation != address(0)) {
            _validateImplementation(u.ledgerImplementation);
            changed = true;
        } else if (u.ledgerData.length != 0) {
            revert InvalidUpgrade();
        }
        if (u.engineImplementation != address(0)) {
            _validateImplementation(u.engineImplementation);
            changed = true;
        } else if (u.engineData.length != 0) {
            revert InvalidUpgrade();
        }
        if (u.beaconImplementation != address(0)) {
            _validateImplementation(u.beaconImplementation);
            changed = true;
        } else if (u.beaconData.length != 0) {
            revert InvalidUpgrade();
        }
        if (!changed || ledgerProxy == address(0)) revert InvalidUpgrade();
    }

    function _validateImplementation(address implementation) internal view {
        if (
            implementation.code.length == 0 || _isSuite(implementation) || implementation == address(token)
                || implementation == address(this) || implementation == adminOf[ledgerProxy]
                || implementation == adminOf[engineProxy] || implementation == adminOf[beaconProxy]
        ) revert InvalidUpgrade();
    }

    /// @notice Next epoch boundary, not governance/timelock. Emergency is immediate.
    function scheduleUpgrade(SuiteUpgrade calldata u) external onlyOwner nonReentrant {
        _validate(u);
        if (recoveryRequired) revert RecoveryPending();
        uint256 epoch = block.timestamp < launchTime ? 0 : (block.timestamp - launchTime) / epochSeconds + 1;
        if (epoch > type(uint48).max) revert InvalidUpgrade();
        activationEpoch = uint48(epoch);
        activationTime = launchTime + epoch * epochSeconds;
        pendingUpgrade = u;
        hasPendingUpgrade = true;
        emit UpgradeScheduled(activationEpoch, activationTime, keccak256(abi.encode(u)));
    }

    function cancelUpgrade() external onlyOwner nonReentrant {
        delete pendingUpgrade;
        hasPendingUpgrade = false;
        emit UpgradeCancelled();
    }

    /// @notice Re-read an intentionally revised ledger clock after recovery.
    /// It never gates the external emergency/rollback path.
    function refreshClock() external onlyOwner nonReentrant {
        if (ledgerProxy == address(0) || hasPendingUpgrade) revert InvalidUpgrade();
        IZoruStableLedger l = IZoruStableLedger(ledgerProxy);
        uint256 period = l.EPOCH_SECONDS();
        if (period == 0) revert InvalidUpgrade();
        launchTime = l.launchTime();
        epochSeconds = period;
    }

    function _perform(SuiteUpgrade memory u) internal {
        if (u.engineImplementation != address(0)) _upgrade(engineProxy, u.engineImplementation, u.engineData);
        if (u.beaconImplementation != address(0)) _upgrade(beaconProxy, u.beaconImplementation, u.beaconData);
        if (u.ledgerImplementation != address(0)) _upgrade(ledgerProxy, u.ledgerImplementation, u.ledgerData);
    }

    function executeScheduledUpgrade() external nonReentrant {
        if (!hasPendingUpgrade || block.timestamp < activationTime) revert NotReady();
        SuiteUpgrade memory u = pendingUpgrade;
        delete pendingUpgrade;
        hasPendingUpgrade = false;
        recoveryRequired = true;
        suiteRevision++;
        _perform(u);
        _recordRevision();
        // A normal upgrade must preserve the clock and support the checkpoint.
        IZoruStableLedger l = IZoruStableLedger(ledgerProxy);
        if (
            l.token() != address(token) || l.engine() != engineProxy || l.beacon() != beaconProxy
                || l.launchTime() != launchTime || l.EPOCH_SECONDS() != epochSeconds
        ) revert InvalidUpgrade();
        l.onImplementationUpgrade(suiteRevision, false);
        recoveryRequired = false;
        emit SuiteUpgraded(suiteRevision, false, true);
    }

    /// @notice Does not query old implementations or require a successful hook.
    /// If the new ledger is also broken, further external rollback still works.
    function emergencyUpgrade(SuiteUpgrade calldata u) external onlyOwner nonReentrant {
        _validate(u);
        delete pendingUpgrade;
        hasPendingUpgrade = false;
        recoveryRequired = true;
        suiteRevision++;
        _perform(u);
        _recordRevision();
        // Re-adopt this coordinator via actual ProxyAdmin, including after handover.
        (bool adopted,) = adminOf[ledgerProxy].call{gas: 600_000}(
            abi.encodeCall(
                ProxyAdmin.upgradeAndCall,
                (
                    ITransparentUpgradeableProxy(ledgerProxy),
                    implementationOf[ledgerProxy],
                    abi.encodeCall(IZoruStableLedger.adoptUpgradeCoordinator, (address(this)))
                )
            )
        );
        (bool notified,) = ledgerProxy.call{gas: 600_000}(
            abi.encodeCall(IZoruStableLedger.onImplementationUpgrade, (suiteRevision, true))
        );
        recoveryRequired = !(adopted && notified);
        emit SuiteUpgraded(suiteRevision, true, !recoveryRequired);
    }

    function handoverProxy(address proxy, ZoruAdminAdapter next) external onlyOwner nonReentrant {
        if (_isSuite(proxy)) revert CoordinatedUpgradeRequired();
        _handover(proxy, next);
        delete adminOf[proxy];
    }

    function _handover(address proxy, ZoruAdminAdapter next) internal {
        address admin = adminOf[proxy];
        if (
            admin == address(0) || address(next) == address(this) || address(next).code.length == 0
                || address(next.token()) != address(token)
        ) revert InvalidAdmin();
        ProxyAdmin(admin).transferOwnership(address(next));
        emit AdminTransferred(proxy, address(next));
    }

    /// @notice All three ProxyAdmins move atomically; public proxy addresses stay.
    /// A broken ledger is repaired by the new coordinator's emergency path.
    function handoverSuite(ZoruAdminAdapter next) external onlyOwner nonReentrant {
        if (ledgerProxy == address(0) || address(next) == address(this)) revert InvalidAdmin();
        _handover(ledgerProxy, next);
        _handover(engineProxy, next);
        _handover(beaconProxy, next);
        next.acceptSuiteHandover();
        delete adminOf[ledgerProxy];
        delete adminOf[engineProxy];
        delete adminOf[beaconProxy];
        recoveryRequired = true;
        delete pendingUpgrade;
        hasPendingUpgrade = false;
    }

    function acceptSuiteHandover() external nonReentrant {
        if (msg.sender != authorizedPrevious || authorizedPrevious == address(0)) revert InvalidAdmin();
        delete authorizedPrevious;
        IZoruUpgradeCoordinator previous = IZoruUpgradeCoordinator(msg.sender);
        if (ledgerProxy != address(0) || previous.token() != address(token)) revert InvalidAdmin();
        address l = previous.ledgerProxy();
        address e = previous.engineProxy();
        address b = previous.beaconProxy();
        _register(l, ProxyAdmin(expectedProxyAdmin(l)));
        _register(e, ProxyAdmin(expectedProxyAdmin(e)));
        _register(b, ProxyAdmin(expectedProxyAdmin(b)));
        ledgerProxy = l;
        engineProxy = e;
        beaconProxy = b;
        implementationOf[l] = previous.implementationOf(l);
        implementationOf[e] = previous.implementationOf(e);
        implementationOf[b] = previous.implementationOf(b);
        suiteRevision = previous.suiteRevision() + 1;
        launchTime = ZoruAdminAdapter(msg.sender).launchTime();
        epochSeconds = ZoruAdminAdapter(msg.sender).epochSeconds();
        recoveryRequired = true;
        _recordRevision();
        // No call into the ledger is required to transfer external authority.
        emit SuiteBound(l, e, b);
    }

    function authorizeHandoverFrom(ZoruAdminAdapter previous) external onlyOwner nonReentrant {
        if (address(previous.token()) != address(token) || previous.ledgerProxy() == address(0)) revert InvalidAdmin();
        authorizedPrevious = address(previous);
    }
}

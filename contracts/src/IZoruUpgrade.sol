// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

interface IZoruUpgradeCoordinator {
    function token() external view returns (address);
    function ledgerProxy() external view returns (address);
    function engineProxy() external view returns (address);
    function beaconProxy() external view returns (address);
    function suiteRevision() external view returns (uint256);
    function adminOf(address proxy) external view returns (address);
    function implementationOf(address proxy) external view returns (address);
    function workActive(uint48 epoch, uint256 generation) external view returns (bool);
}

interface IZoruStableLedger {
    function token() external view returns (address);
    function engine() external view returns (address);
    function beacon() external view returns (address);
    function launchTime() external view returns (uint256);
    function EPOCH_SECONDS() external view returns (uint256);
    function bindPermanentProxies(address coordinator) external;
    function onImplementationUpgrade(uint256 revision, bool emergency) external;
    function adoptUpgradeCoordinator(address next) external;
}

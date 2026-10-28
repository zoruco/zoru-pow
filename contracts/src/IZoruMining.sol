// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

interface IZoruBeaconSource {
    /// @notice Predetermined release time for this epoch, in chain seconds.
    function releaseTime(uint48 epoch) external view returns (uint256);
    /// @notice Must return ZERO unless the exact precommitted future-round beacon
    ///         signature has been cryptographically verified on-chain.
    function verifiedSeed(uint48 epoch) external view returns (bytes32 seed);
}

interface IZoruWorkEngine {
    function valid(bytes32 digest, uint256 target) external view returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @notice Kernel checks a domain-separated digest computed by the ledger.
/// @dev Domain/nonce/beneficiary binding is implemented in ZoruLedger.
contract ZoruKeccakEngine is Initializable {
    constructor() {
        _disableInitializers();
    }
    /// @notice Stateless kernel; initializer only seals proxy initialization.
    function initialize() external initializer {}

    function valid(bytes32 digest, uint256 target) external pure returns (bool) {
        return uint256(digest) < target;
    }
}

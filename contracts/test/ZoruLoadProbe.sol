// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruLedger} from "../src/ZoruLedger.sol";

/// @notice Bounded accounting load on the isolated test chain. No proof storage here.
contract ZoruLoadProbe {
    ZoruLedger public immutable ledger;

    constructor(ZoruLedger ledger_) {
        require(block.chainid == 46736 && address(ledger_).code.length != 0, "isolated test chain required");
        ledger = ledger_;
    }

    modifier onlyTestOwner() {
        require(msg.sender == ledger.token().owner(), "test owner required");
        _;
    }

    function submitBatch(uint48 epoch, uint256 firstNonce, uint256 count, address[] calldata beneficiaries)
        external onlyTestOwner
    {
        require(count != 0 && count <= 100 && beneficiaries.length == 4, "bounded test batch");
        for (uint256 i; i < count; ++i) ledger.submit(epoch, beneficiaries[(firstNonce + i) % 4], firstNonce + i);
    }

    function sealBatch(uint48[] calldata epochs) external onlyTestOwner {
        require(epochs.length != 0 && epochs.length <= 64, "bounded test batch");
        for (uint256 i; i < epochs.length; ++i) ledger.seal(epochs[i]);
    }

    function claimBatch(bytes32[] calldata digests) external onlyTestOwner {
        require(digests.length != 0 && digests.length <= 100, "bounded test batch");
        for (uint256 i; i < digests.length; ++i) ledger.claim(digests[i]);
    }
}

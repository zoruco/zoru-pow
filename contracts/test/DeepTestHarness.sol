// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @notice ONLY isolated local-chain transaction-order tests; never production beacon.
contract DeepTestBeacon is Initializable {
    uint256 public launchTime;

    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 launch) external initializer {
        launchTime = launch;
    }

    function releaseTime(uint48 epoch) external view returns (uint256) {
        return launchTime + uint256(epoch) * 60;
    }

    function verifiedSeed(uint48 epoch) external pure returns (bytes32) {
        return keccak256(abi.encode("DEEP_TEST_ONLY_NOT_RANDOM", epoch));
    }
}

contract DeepTestRevert {
    fallback() external {
        revert("TEST_BROKEN");
    }
}

contract DeepTestPanic {
    fallback() external {
        assert(false);
    }
}

contract DeepTestNoReturn {
    fallback() external {}
}

contract DeepTestGasLoop {
    fallback() external {
        assembly { for {} 1 {} {} }
    }
}

/// @notice TEST ONLY: a scheduled seed becomes visible after twenty seconds.
/// This models the authenticated publication delay without using any real keys.
contract DeepTestDelayedBeacon is Initializable {
    uint256 public launchTime;

    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 launch) external initializer {
        launchTime = launch;
    }

    function releaseTime(uint48 epoch) external view returns (uint256) {
        return launchTime + uint256(epoch) * 60;
    }

    function verifiedSeed(uint48 epoch) external view returns (bytes32) {
        if (block.timestamp < launchTime + uint256(epoch) * 60 + 20) return bytes32(0);
        return keccak256(abi.encode("DELAYED_TEST_ONLY_NOT_RANDOM", epoch));
    }
}

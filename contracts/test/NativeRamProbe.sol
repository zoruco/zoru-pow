// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @notice Isolated native RAM experiment. Never a production protocol module.
contract NativeRamProbe {
    mapping(uint256 => uint256) public values;
    event Probe(uint256 indexed key);

    function write(uint256 key, uint256 count) external {
        require(count > 0 && count <= 64, "bounded probe");
        for (uint256 i; i < count; ++i) values[key + i] = key + i + 1;
    }

    function clear(uint256 key, uint256 count) external {
        require(count > 0 && count <= 64, "bounded probe");
        for (uint256 i; i < count; ++i) delete values[key + i];
    }

    function ping(uint256 key) external {
        emit Probe(key);
    }

    function fail() external pure {
        revert("deliberate isolated failure");
    }
}

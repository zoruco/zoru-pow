// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruKeccakEngine} from "../src/ZoruKeccakEngine.sol";
import {IZoruWorkEngine} from "../src/IZoruMining.sol";

contract RuntimeBrokenModule {
    fallback() external {
        revert("PROBE_BROKEN");
    }
}

/// @notice VEX eth_call only: actual transparent proxy/admin CREATE
/// address relationship and recovery from reverting code, without broadcast.
contract ZoruAdminRuntimeProbe {
    address public immutable observedAdmin;

    constructor() {
        require(block.chainid == 6736, "VEX_ONLY");
        ZoruToken token = new ZoruToken(address(this));
        ZoruAdminAdapter adapter = new ZoruAdminAdapter(token);
        ZoruKeccakEngine engine = new ZoruKeccakEngine();
        address proxy = adapter.deployProxy(address(engine), abi.encodeCall(IZoruWorkEngine.valid, (bytes32(0), 1)));
        require(IZoruWorkEngine(proxy).valid(bytes32(uint256(1)), 2), "kernel proxy");
        adapter.upgrade(proxy, address(new RuntimeBrokenModule()), "");
        (bool broken,) = proxy.staticcall(abi.encodeCall(IZoruWorkEngine.valid, (bytes32(0), 1)));
        require(!broken, "broken module must revert");
        adapter.upgrade(proxy, address(engine), "");
        require(IZoruWorkEngine(proxy).valid(bytes32(uint256(1)), 2), "external recovery on VEX");
        observedAdmin = adapter.adminOf(proxy);
        require(observedAdmin == adapter.expectedProxyAdmin(proxy), "VEX CREATE nonce convention");
    }
}

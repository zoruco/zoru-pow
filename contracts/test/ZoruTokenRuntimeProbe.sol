// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";

contract RuntimeProbeIssuer {
    function mint(ZoruToken token, address recipient, uint256 amount) external {
        token.mint(recipient, amount);
    }
}

/// @notice Constructor-only VEX preflight simulation through eth_call. Never broadcast.
contract ZoruTokenRuntimeProbe {
    uint256 public immutable observedCap;

    constructor() {
        require(block.chainid == 6736, "VEX_ONLY");
        ZoruToken token = new ZoruToken(address(this));
        require(token.decimals() == 8 && token.totalSupply() == 0, "minimal ERC20 genesis");
        require(token.MAX_SUPPLY() == 21_000_000 * 1e8, "exact cap");
        RuntimeProbeIssuer issuer = new RuntimeProbeIssuer();
        token.setIssuer(address(issuer));
        issuer.mint(token, address(this), token.MAX_SUPPLY());
        (bool exceeded,) = address(issuer).call(abi.encodeCall(issuer.mint, (token, address(this), 1)));
        require(!exceeded, "cap bypass");
        token.transfer(address(0xA11CE), 1);
        token.setIssuer(address(0));
        token.setIssuer(address(issuer));
        require(token.lifetimeMinted() == token.MAX_SUPPLY(), "lifetime counter");
        observedCap = token.totalSupply();
    }
}

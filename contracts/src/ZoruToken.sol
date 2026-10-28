// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Non-proxy ERC-20. The ONLY issuance policy here is a lifetime cap.
/// @dev OWNER-MANAGED ISSUANCE POLICY. An owner-appointed issuer can allocate the entire
/// remaining cap. Fair mining, clocks and liabilities belong to the ledger.
contract ZoruToken is ERC20, Ownable2Step {
    uint256 public constant MAX_SUPPLY = 21_000_000 * 1e8;

    address public issuer;
    uint256 public lifetimeMinted;

    error NotIssuer();
    error CapExceeded();
    error InvalidIssuer();
    error RenounceDisabled();

    event IssuerUpdated(address indexed oldIssuer, address indexed newIssuer);

    constructor(address initialOwner) ERC20("ZORU", "ZORU") Ownable(initialOwner) {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Zero revokes issuance; another contract can be appointed at once.
    /// Never calls the old issuer, including when that issuer is broken.
    function setIssuer(address nextIssuer) external onlyOwner {
        if (nextIssuer != address(0) && nextIssuer.code.length == 0) revert InvalidIssuer();
        emit IssuerUpdated(issuer, nextIssuer);
        issuer = nextIssuer;
    }

    function mint(address recipient, uint256 amount) external {
        if (msg.sender != issuer) revert NotIssuer();
        if (amount > MAX_SUPPLY - lifetimeMinted) revert CapExceeded();
        lifetimeMinted += amount;
        _mint(recipient, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruKeccakEngine} from "../src/ZoruKeccakEngine.sol";
import {ZoruDrandBeacon} from "../src/ZoruDrandBeacon.sol";

contract SuiteProbeBrokenImplementation {
    fallback() external {
        revert();
    }
}

/// @notice Read-only creation eth_call ONLY, on VEX mainnet 6736. Exercises
/// permanent proxy creation, broken implementations, and same-address rollback.
contract ZoruSuiteRuntimeProbe {
    constructor() {
        require(block.chainid == 6736);
        ZoruToken token = new ZoruToken(address(this));
        ZoruAdminAdapter admin = new ZoruAdminAdapter(token);
        ZoruAdminAdapter.SuiteDeployment memory d;
        d.ledgerImplementation = address(new ZoruLedger());
        d.engineImplementation = address(new ZoruKeccakEngine());
        d.engineData = abi.encodeCall(ZoruKeccakEngine.initialize, ());
        d.beaconImplementation = address(new ZoruDrandBeacon());
        uint256 genesis = 1_727_521_075;
        d.launchTime = genesis + ((block.timestamp - genesis) / 3 + 1) * 3;
        d.beaconData = abi.encodeCall(ZoruDrandBeacon.initialize, (d.launchTime));
        d.initialTarget = type(uint256).max >> 16;
        (address l,,) = admin.deploySuite(d);
        token.setIssuer(l);
        bytes32 expected = _addresses(token, admin);

        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.engineImplementation = address(new ZoruKeccakEngine());
        admin.emergencyUpgrade(u);
        require(_addresses(token, admin) == expected);
        require(ZoruKeccakEngine(admin.engineProxy()).valid(bytes32(uint256(2)), 3));

        address broken = address(new SuiteProbeBrokenImplementation());
        u.ledgerImplementation = broken;
        u.engineImplementation = broken;
        u.beaconImplementation = broken;
        admin.emergencyUpgrade(u);
        require(admin.recoveryRequired());

        u.ledgerImplementation = d.ledgerImplementation;
        u.engineImplementation = d.engineImplementation;
        u.beaconImplementation = d.beaconImplementation;
        admin.emergencyUpgrade(u);
        require(!admin.recoveryRequired() && _addresses(token, admin) == expected);
        require(ZoruLedger(l).moduleGeneration() == 4);
        require(ZoruDrandBeacon(admin.beaconProxy()).launchTime() == d.launchTime);
        require(token.decimals() == 8 && token.totalSupply() == 0);
    }

    function _addresses(ZoruToken token, ZoruAdminAdapter admin) private view returns (bytes32) {
        ZoruLedger l = ZoruLedger(admin.ledgerProxy());
        return keccak256(
            abi.encode(
                address(token),
                address(l),
                admin.engineProxy(),
                admin.beaconProxy(),
                token.issuer(),
                address(l.engine()),
                address(l.beacon())
            )
        );
    }
}

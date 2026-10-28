// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {IZoruWorkEngine, IZoruBeaconSource} from "../src/IZoruMining.sol";

/// @dev Test mocks are stateless or constructor-configured. Real kernel/beacon
/// deployments use their actual initialize() calldata, tested separately.
library SuiteSupport {
    function mockSuite(ZoruToken token, address source, address work, uint256 start, uint256 target)
        internal
        returns (ZoruLedger ledger, ZoruAdminAdapter admin, address engine, address beacon)
    {
        admin = new ZoruAdminAdapter(token);
        ZoruAdminAdapter.SuiteDeployment memory d;
        d.ledgerImplementation = address(new ZoruLedger());
        d.engineImplementation = work;
        d.engineData = abi.encodeCall(IZoruWorkEngine.valid, (bytes32(0), 1));
        d.beaconImplementation = source;
        d.beaconData = abi.encodeCall(IZoruBeaconSource.releaseTime, (0));
        d.launchTime = start;
        d.initialTarget = target;
        (address l, address e, address b) = admin.deploySuite(d);
        ledger = ZoruLedger(l);
        engine = e;
        beacon = b;
        token.setIssuer(l);
    }

    function emergencyLedger(ZoruAdminAdapter admin, address implementation, bytes memory data) internal {
        ZoruAdminAdapter.SuiteUpgrade memory u;
        u.ledgerImplementation = implementation;
        u.ledgerData = data;
        admin.emergencyUpgrade(u);
    }
}

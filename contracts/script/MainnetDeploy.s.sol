// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ZoruToken} from "../src/ZoruToken.sol";
import {ZoruAdminAdapter} from "../src/ZoruAdminAdapter.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";
import {ZoruKeccakEngine} from "../src/ZoruKeccakEngine.sol";
import {ZoruDrandBeacon} from "../src/ZoruDrandBeacon.sol";

interface MainnetDeploymentVm {
    function envAddress(string calldata) external returns (address);
    function envUint(string calldata) external returns (uint256);
    function envString(string calldata) external returns (string memory);
    function startBroadcast(address) external;
    function stopBroadcast() external;
    function serializeAddress(string calldata, string calldata, address) external returns (string memory);
    function serializeUint(string calldata, string calldata, uint256) external returns (string memory);
    function serializeString(string calldata, string calldata, string calldata) external returns (string memory);
    function writeJson(string calldata, string calldata) external;
}

/// @notice Mainnet 6736 deployment using the authenticated drand beacon.
/// @dev This script prepares contracts; Foundry's wallet/signer owns actual broadcasting.
contract MainnetDeploy {
    MainnetDeploymentVm private constant vm = MainnetDeploymentVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external {
        require(block.chainid == 6736, "Mainnet chain 6736 required");
        address owner = vm.envAddress("ZORU_OWNER");
        require(owner != address(0), "Owner is required");
        uint256 delay = vm.envUint("ZORU_LAUNCH_DELAY");
        uint256 bits = vm.envUint("ZORU_TARGET_BITS");
        require(delay >= 3600 && delay <= 604800 && bits >= 16 && bits <= 40, "Invalid launch parameters");
        uint256 genesis = 1_727_521_075;
        uint256 launch = genesis + ((block.timestamp + delay - genesis + 2) / 3) * 3;

        vm.startBroadcast(owner);
        ZoruToken token = new ZoruToken(owner);
        ZoruAdminAdapter admin = new ZoruAdminAdapter(token);
        ZoruLedger ledgerImplementation = new ZoruLedger();
        ZoruKeccakEngine engineImplementation = new ZoruKeccakEngine();
        address beaconImplementation = address(new ZoruDrandBeacon());

        (address ledger, address engine, address beacon) = admin.deploySuite(ZoruAdminAdapter.SuiteDeployment({
            ledgerImplementation: address(ledgerImplementation),
            engineImplementation: address(engineImplementation),
            engineData: abi.encodeCall(ZoruKeccakEngine.initialize, ()),
            beaconImplementation: beaconImplementation,
            beaconData: abi.encodeCall(ZoruDrandBeacon.initialize, (launch)),
            launchTime: launch,
            initialTarget: type(uint256).max >> bits
        }));
        token.setIssuer(ledger);
        require(token.issuer() == ledger && token.owner() == owner, "Deployment wiring incomplete");
        vm.stopBroadcast();

        vm.serializeUint("deployment", "chainId", block.chainid);
        vm.serializeString("deployment", "mode", "mainnet");
        vm.serializeAddress("deployment", "owner", owner);
        vm.serializeAddress("deployment", "token", address(token));
        vm.serializeAddress("deployment", "admin", address(admin));
        vm.serializeAddress("deployment", "ledger", ledger);
        vm.serializeAddress("deployment", "engine", engine);
        vm.serializeAddress("deployment", "beacon", beacon);
        vm.serializeUint("deployment", "launchTime", launch);
        vm.serializeUint("deployment", "deploymentBlockNumber", block.number);
        string memory output = vm.serializeUint("deployment", "targetBits", bits);
        vm.writeJson(output, vm.envString("ZORU_DEPLOYMENT_FILE"));
    }
}

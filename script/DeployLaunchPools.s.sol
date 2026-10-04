// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {DammHook} from "../src/hooks/DammHook.sol";
import {LaunchPools} from "../src/launch/LaunchPools.sol";
import {LaunchVault} from "../src/launch/LaunchVault.sol";

/// Deploys LaunchPools and LaunchVault with CREATE2 (fixed addresses, no owner, nothing to configure):
///   1. LaunchPools(poolManager, dammHook) at salt "fathom.launch-pools.v1"
///   2. LaunchVault(launchPools) at salt "fathom.launch-vault.v1"
/// Build with the deploy profile, or the bytecode (and so the addresses) will differ:
///   FOUNDRY_PROFILE=deploy forge script script/DeployLaunchPools.s.sol \
///     --rpc-url $ROBINHOOD_RPC_URL --broadcast --account fathom-deployer
/// Without --rpc-url/--broadcast it only prints the predicted addresses. A rerun is safe: a contract
/// that already has code is reused.
contract DeployLaunchPools is Script {
    bytes32 constant SALT = keccak256("fathom.launch-pools.v1");
    bytes32 constant VAULT_SALT = keccak256("fathom.launch-vault.v1");

    function run() external returns (LaunchPools lp, LaunchVault vault) {
        string memory json = vm.readFile("deployments/robinhood.json");
        IPoolManager pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        DammHook hook = DammHook(vm.parseJsonAddress(json, ".dammHook"));
        if (address(hook).code.length != 0) require(hook.poolManager() == pm, "hook is on another PoolManager");

        bytes memory init = abi.encodePacked(type(LaunchPools).creationCode, abi.encode(pm, hook));
        address predicted = vm.computeCreate2Address(SALT, keccak256(init), CREATE2_FACTORY);
        bytes memory vinit = abi.encodePacked(type(LaunchVault).creationCode, abi.encode(predicted));
        address vpredicted = vm.computeCreate2Address(VAULT_SALT, keccak256(vinit), CREATE2_FACTORY);
        console2.log("launch pools", predicted);
        console2.log("launch vault", vpredicted);
        // The app is wired to these addresses ahead of time: refuse to deploy anywhere else.
        if (vm.keyExistsJson(json, ".launchPools")) {
            require(predicted == vm.parseJsonAddress(json, ".launchPools"), "launch pools bytecode changed: build with FOUNDRY_PROFILE=deploy");
        }
        if (vm.keyExistsJson(json, ".launchVault")) {
            require(vpredicted == vm.parseJsonAddress(json, ".launchVault"), "launch vault bytecode changed: build with FOUNDRY_PROFILE=deploy");
        }

        vm.startBroadcast();
        lp = predicted.code.length == 0 ? new LaunchPools{salt: SALT}(pm, hook) : LaunchPools(predicted);
        require(address(lp) == predicted, "unexpected launch pools address");
        vault = vpredicted.code.length == 0 ? new LaunchVault{salt: VAULT_SALT}(lp) : LaunchVault(payable(vpredicted));
        require(address(vault) == vpredicted, "unexpected launch vault address");
        vm.stopBroadcast();
    }
}

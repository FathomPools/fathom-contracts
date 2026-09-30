// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {RobinhoodAddresses as RH} from "./RobinhoodAddresses.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";
import {DlmmVaultFactory} from "../src/vaults/DlmmVaultFactory.sol";
import {DlmmVaultZap} from "../src/vaults/DlmmVaultZap.sol";

/// Deploys the vault zap with CREATE2 (fixed address). The zap has no owner, so any account can run
/// this; it only needs gas.
///   FOUNDRY_PROFILE=deploy forge script script/DeployZap.s.sol \
///     --rpc-url $ROBINHOOD_RPC_URL --broadcast   # + your signer flags
/// Reads the Router and the vault factory from deployments/robinhood.json.
contract DeployZap is Script {
    bytes32 constant SALT = keccak256("fathom.dlmm-vault-zap.v1");

    function run() external returns (DlmmVaultZap zap) {
        string memory json = vm.readFile("deployments/robinhood.json");
        IRouter router = IRouter(vm.parseJsonAddress(json, ".router"));
        DlmmVaultFactory factory = DlmmVaultFactory(vm.parseJsonAddress(json, ".dlmmVaultFactory"));
        require(address(factory).code.length != 0, "vault factory not deployed");

        bytes memory init = abi.encodePacked(type(DlmmVaultZap).creationCode, abi.encode(router, RH.WETH, factory));
        address predicted = vm.computeCreate2Address(SALT, keccak256(init), CREATE2_FACTORY);
        console2.log("vault zap", predicted);
        // The app is wired to this address ahead of time: refuse to deploy anywhere else.
        if (vm.keyExistsJson(json, ".dlmmVaultZap")) {
            require(predicted == vm.parseJsonAddress(json, ".dlmmVaultZap"), "zap bytecode changed: build with FOUNDRY_PROFILE=deploy");
        }

        vm.startBroadcast();
        zap = predicted.code.length == 0 ? new DlmmVaultZap{salt: SALT}(router, RH.WETH, factory) : DlmmVaultZap(payable(predicted));
        vm.stopBroadcast();
        require(address(zap) == predicted, "unexpected zap address");
    }
}

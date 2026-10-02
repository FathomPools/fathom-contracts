// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {RobinhoodAddresses as RH} from "./RobinhoodAddresses.sol";
import {DlmmFactory} from "../src/dlmm/DlmmFactory.sol";
import {DlmmLimitOrders} from "../src/periphery/DlmmLimitOrders.sol";

/// Deploys DlmmLimitOrders with CREATE2 (fixed address). It has no owner and needs no setup, so any
/// funded account can run it:
///   FOUNDRY_PROFILE=deploy forge script script/DeployLimitOrders.s.sol \
///     --rpc-url $ROBINHOOD_RPC_URL --broadcast --account fathom-deployer
/// A rerun is a no-op once the contract exists.
contract DeployLimitOrders is Script {
    bytes32 constant SALT = keccak256("fathom.limit-orders.v1");

    function run() external returns (DlmmLimitOrders orders) {
        string memory json = vm.readFile("deployments/robinhood.json");
        DlmmFactory dlmm = DlmmFactory(vm.parseJsonAddress(json, ".dlmmFactory"));

        bytes memory init = abi.encodePacked(type(DlmmLimitOrders).creationCode, abi.encode(dlmm, RH.WETH));
        address predicted = vm.computeCreate2Address(SALT, keccak256(init), CREATE2_FACTORY);
        console2.log("limit orders", predicted);
        // The app is wired to this address ahead of time: refuse to deploy anywhere else.
        if (vm.keyExistsJson(json, ".dlmmLimitOrders")) {
            require(
                predicted == vm.parseJsonAddress(json, ".dlmmLimitOrders"),
                "limit orders bytecode changed: build with FOUNDRY_PROFILE=deploy"
            );
        }

        vm.startBroadcast();
        orders = predicted.code.length == 0
            ? new DlmmLimitOrders{salt: SALT}(dlmm, RH.WETH)
            : DlmmLimitOrders(payable(predicted));
        vm.stopBroadcast();
        require(address(orders) == predicted, "unexpected limit orders address");
        require(orders.factory() == dlmm && orders.weth() == RH.WETH, "wrong wiring");
    }
}

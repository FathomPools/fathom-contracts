// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {RobinhoodAddresses as RH} from "./RobinhoodAddresses.sol";
import {ProtocolConfig} from "../src/core/ProtocolConfig.sol";
import {DlmmFactory} from "../src/dlmm/DlmmFactory.sol";
import {DlmmVaultFactory} from "../src/vaults/DlmmVaultFactory.sol";

/// Deploys the DLMM vault factory (CREATE2, so its address is fixed before broadcasting), names the
/// keeper, opens the WETH/USDG vault and tops the keeper up with gas money. Run as the protocol owner:
///   FOUNDRY_PROFILE=deploy KEEPER=<addr> forge script script/DeployVaults.s.sol \
///     --rpc-url $ROBINHOOD_RPC_URL --broadcast   # + your signer flags
/// Reads the core addresses from deployments/robinhood.json; prints the new addresses.
contract DeployVaults is Script {
    bytes32 constant SALT = keccak256("fathom.dlmm-vault-factory.v1");
    uint16 constant BIN_STEP = 10;
    uint24 constant HALF_WIDTH = 20; // 41 bins, +-2 % at a 10 bps bin step
    uint8 constant SHAPE = 0; // Spot
    uint256 constant KEEPER_GAS = 0.005 ether;

    function run() external returns (DlmmVaultFactory factory, address vault) {
        string memory json = vm.readFile("deployments/robinhood.json");
        ProtocolConfig config = ProtocolConfig(vm.parseJsonAddress(json, ".protocolConfig"));
        DlmmFactory dlmm = DlmmFactory(vm.parseJsonAddress(json, ".dlmmFactory"));
        address keeper = vm.envAddress("KEEPER");
        address pair = dlmm.getPair(RH.WETH, RH.USDG, BIN_STEP);
        require(pair != address(0), "no WETH/USDG pair");
        require(config.owner() == msg.sender, "run as the protocol owner");

        bytes memory init = abi.encodePacked(type(DlmmVaultFactory).creationCode, abi.encode(config, dlmm));
        address predicted = vm.computeCreate2Address(SALT, keccak256(init), CREATE2_FACTORY);
        console2.log("vault factory", predicted);
        // The app and the keeper are wired to this address ahead of time: refuse to deploy anywhere else.
        if (vm.keyExistsJson(json, ".dlmmVaultFactory")) {
            require(predicted == vm.parseJsonAddress(json, ".dlmmVaultFactory"), "factory bytecode changed: build with FOUNDRY_PROFILE=deploy");
        }

        vm.startBroadcast();
        factory = predicted.code.length == 0 ? new DlmmVaultFactory{salt: SALT}(config, dlmm) : DlmmVaultFactory(predicted);
        require(address(factory) == predicted, "unexpected factory address");
        if (factory.keeper() != keeper) factory.setKeeper(keeper);
        vault = factory.getVault(pair, HALF_WIDTH, SHAPE);
        if (vault == address(0)) vault = factory.createVault(pair, HALF_WIDTH, SHAPE);
        if (keeper.balance < KEEPER_GAS) payable(keeper).transfer(KEEPER_GAS - keeper.balance);
        vm.stopBroadcast();

        console2.log("keeper", keeper);
        console2.log("WETH/USDG pair", pair);
        console2.log("WETH/USDG vault", vault);
    }
}

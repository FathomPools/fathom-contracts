// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {ProtocolConfig} from "../core/ProtocolConfig.sol";
import {AssetRegistry} from "../core/AssetRegistry.sol";
import {DammHook} from "./DammHook.sol";
import {StockHook} from "./StockHook.sol";

/// CREATE2 salt mining + deployment of the Fathom hooks (address low bits = permission flags).
/// `deployer` is whoever executes `new X{salt:}`: the calling contract in tests, Foundry's
/// CREATE2 proxy (`CREATE2_PROXY`) inside a broadcasting script.
library HookDeployer {
    address internal constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// Both hooks share one permission set (see FathomHookBase.getHookPermissions).
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function mineDamm(address deployer, IPoolManager pm, ProtocolConfig cfg)
        internal
        view
        returns (address hook, bytes32 salt)
    {
        return HookMiner.find(deployer, FLAGS, type(DammHook).creationCode, abi.encode(pm, cfg));
    }

    function mineStock(address deployer, IPoolManager pm, ProtocolConfig cfg, AssetRegistry reg)
        internal
        view
        returns (address hook, bytes32 salt)
    {
        return HookMiner.find(deployer, FLAGS, type(StockHook).creationCode, abi.encode(pm, cfg, reg));
    }

    /// Mine + deploy. Pass `deployer = address(this)` from a test/contract, `CREATE2_PROXY` from a
    /// broadcasting script.
    function deployDamm(address deployer, IPoolManager pm, ProtocolConfig cfg) internal returns (DammHook hook) {
        (address expected, bytes32 salt) = mineDamm(deployer, pm, cfg);
        hook = new DammHook{salt: salt}(pm, cfg);
        require(address(hook) == expected, "HookDeployer: damm addr");
    }

    function deployStock(address deployer, IPoolManager pm, ProtocolConfig cfg, AssetRegistry reg)
        internal
        returns (StockHook hook)
    {
        (address expected, bytes32 salt) = mineStock(deployer, pm, cfg, reg);
        hook = new StockHook{salt: salt}(pm, cfg, reg);
        require(address(hook) == expected, "HookDeployer: stock addr");
    }
}

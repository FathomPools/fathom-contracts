// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {ProtocolConfig} from "../../src/core/ProtocolConfig.sol";
import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {DammHook} from "../../src/hooks/DammHook.sol";
import {StockHook} from "../../src/hooks/StockHook.sol";
import {HookDeployer} from "../../src/hooks/HookDeployer.sol";

/// Local v4 PoolManager + routers (Deployers), ProtocolConfig, AssetRegistry and both hooks.
abstract contract HooksBase is Deployers {
    // Wed 2023-11-15 15:00 UTC (NYSE open under the default DST session); Saturday same time.
    uint256 internal constant WED_OPEN = 1_700_060_400;
    uint256 internal constant SAT = 1_700_319_600;

    address internal owner = makeAddr("owner");
    address internal collector = makeAddr("collector");
    ProtocolConfig internal config;
    AssetRegistry internal registry;
    DammHook internal damm;
    StockHook internal stockHook;

    function _deployHooks() internal {
        vm.warp(WED_OPEN);
        deployFreshManagerAndRouters();
        config = new ProtocolConfig(owner, collector);
        registry = new AssetRegistry(owner);
        damm = HookDeployer.deployDamm(address(this), manager, config);
        stockHook = HookDeployer.deployStock(address(this), manager, config, registry);
    }

    /// v4 wraps hook reverts: WrappedError(hook, hookSelector, reason, HookCallFailed()).
    function _hookErr(address hook, bytes4 hookSelector, bytes4 err) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hook,
            hookSelector,
            abi.encodeWithSelector(err),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}

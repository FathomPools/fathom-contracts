// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DammHook} from "../../src/hooks/DammHook.sol";
import {FathomHookBase} from "../../src/hooks/FathomHookBase.sol";
import {HooksBase} from "./HooksBase.t.sol";

contract DammHookTest is HooksBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolId internal id;
    ModifyLiquidityParams internal WIDE = ModifyLiquidityParams(-6000, 6000, 1e21, 0);

    function setUp() public {
        _deployHooks();
        deployMintAndApprove2Currencies();
    }

    function _key(Currency c0, Currency c1) internal view returns (PoolKey memory) {
        return PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(damm)));
    }

    function _create(DammHook.PoolParams memory p) internal {
        key = _key(currency0, currency1);
        (id,) = damm.createPool(key, SQRT_PRICE_1_1, p);
        modifyLiquidityRouter.modifyLiquidity(key, WIDE, ZERO_BYTES);
    }

    function test_swapBothDirections_feeSplitToCollector() public {
        _create(DammHook.PoolParams(30, 0, 0, 0));
        (uint24 lp, uint24 total) = damm.currentFee(id);
        assertEq(total, 3000);
        assertEq(lp, 2400); // 80 % LP, 20 % protocol

        swap(key, true, -1e18, ZERO_BYTES); // exact-in 0→1
        assertEq(currency0.balanceOf(collector), 1e18 * 600 / 1e6);
        swap(key, false, -1e18, ZERO_BYTES); // exact-in 1→0
        assertEq(currency1.balanceOf(collector), 1e18 * 600 / 1e6);

        // exact-out 0→1: protocol fee charged on the input side on top of what the pool took
        uint256 before0 = currency0.balanceOf(collector);
        uint256 bal0 = currency0.balanceOfSelf();
        swap(key, true, 1e17, ZERO_BYTES);
        uint256 paid = bal0 - currency0.balanceOfSelf();
        uint256 fee = currency0.balanceOf(collector) - before0;
        assertApproxEqRel(fee, (paid - fee) * 600 / 1e6, 1e15);
        assertEq(currency1.balanceOf(collector), 1e18 * 600 / 1e6);
    }

    function test_snipeFeeDecaysAndVolSurchargeDecays() public {
        _create(DammHook.PoolParams(30, 5000, 1000, 10_000));
        (, uint24 total) = damm.currentFee(id);
        assertEq(total, 500_000);
        vm.warp(vm.getBlockTimestamp() + 500);
        (, total) = damm.currentFee(id);
        assertEq(total, 251_500); // 5000 - 4970 * 500/1000 = 2515 bps
        vm.warp(vm.getBlockTimestamp() + 500);
        (, total) = damm.currentFee(id);
        assertEq(total, 3000);

        // a big swap moves the tick → surcharge on the next swap, decays back to base
        swap(key, true, -50e18, ZERO_BYTES);
        (, total) = damm.currentFee(id);
        assertGt(total, 3000);
        assertLe(total, 50_000); // hard cap 500 bps outside the snipe window
        vm.warp(vm.getBlockTimestamp() + 600);
        (, total) = damm.currentFee(id);
        assertEq(total, 3000);
    }

    function test_pauseBlocksSwapAndAddNotRemove() public {
        _create(DammHook.PoolParams(30, 0, 0, 0));
        vm.prank(owner);
        config.setPaused(true);

        vm.expectRevert(_hookErr(address(damm), IHooks.beforeSwap.selector, FathomHookBase.Paused.selector));
        swap(key, true, -1e18, ZERO_BYTES);
        vm.expectRevert(_hookErr(address(damm), IHooks.beforeAddLiquidity.selector, FathomHookBase.Paused.selector));
        modifyLiquidityRouter.modifyLiquidity(key, WIDE, ZERO_BYTES);

        WIDE.liquidityDelta = -1e21;
        modifyLiquidityRouter.modifyLiquidity(key, WIDE, ZERO_BYTES); // withdrawals always work
    }

    function test_nativeEthPool() public {
        key = _key(CurrencyLibrary.ADDRESS_ZERO, currency1);
        (id,) = damm.createPool(key, SQRT_PRICE_1_1, DammHook.PoolParams(100, 0, 0, 0));
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(key, ModifyLiquidityParams(-600, 600, 1e21, 0), ZERO_BYTES);
        swapNativeInput(key, true, -1 ether, ZERO_BYTES, 1 ether);
        assertEq(collector.balance, 1 ether * 2000 / 1e6); // 100 bps * 20 %
        swap(key, false, -1 ether, ZERO_BYTES);
        assertEq(currency1.balanceOf(collector), 1 ether * 2000 / 1e6);
    }

    /// Input currency not yet held by the PoolManager → fee minted as a 6909 claim, then swept.
    function test_feeClaimFallbackAndSweep() public {
        key = _key(currency0, currency1);
        (id,) = damm.createPool(key, SQRT_PRICE_1_1, DammHook.PoolParams(30, 0, 0, 0));
        // single-sided currency1 liquidity below the price: PoolManager holds no currency0
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-6000, -60, 1e21, 0), ZERO_BYTES);
        assertEq(currency0.balanceOf(address(manager)), 0);
        swap(key, true, -1e18, ZERO_BYTES);
        assertEq(currency0.balanceOf(collector), 0);
        assertEq(manager.balanceOf(address(damm), currency0.toId()), 600e12);
        damm.sweep(currency0);
        assertEq(currency0.balanceOf(collector), 600e12);
    }

    function test_createGuards() public {
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(damm)));
        vm.expectRevert(FathomHookBase.NotDynamicFee.selector);
        damm.createPool(key, SQRT_PRICE_1_1, DammHook.PoolParams(30, 0, 0, 0));

        key = _key(currency0, currency1);
        vm.expectRevert(DammHook.BadParams.selector);
        damm.createPool(key, SQRT_PRICE_1_1, DammHook.PoolParams(101, 0, 0, 0));

        // direct initialize (bypassing createPool) is refused
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }
}

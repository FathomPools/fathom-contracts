// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary as StateView} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {StockHook} from "../../src/hooks/StockHook.sol";
import {MockAggregator} from "../utils/MockAggregator.sol";
import {HooksBase} from "./HooksBase.t.sol";

contract StockHookTest is HooksBase {
    MockERC20 internal stock;
    MockERC20 internal usdg;
    MockAggregator internal feed;
    PoolId internal id;
    bool internal stockIs0;

    function setUp() public {
        _deployHooks();
        stock = new MockERC20("NVIDIA", "NVDA", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        stock.mint(address(this), 1e30);
        usdg.mint(address(this), 1e30);
        stock.approve(address(swapRouter), type(uint256).max);
        usdg.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(modifyLiquidityRouter), type(uint256).max);
        usdg.approve(address(modifyLiquidityRouter), type(uint256).max);
        feed = new MockAggregator(8, 100e8);

        vm.startPrank(owner);
        registry.setAsset(
            address(stock),
            AssetRegistry.Asset(AssetRegistry.AssetClass.STOCK, address(feed), 1 days, 30, 150, 500, 200, 50, true)
        );
        registry.setQuote(address(usdg), address(0), 0, true);
        vm.stopPrank();

        stockIs0 = address(stock) < address(usdg);
        (Currency c0, Currency c1) = stockIs0
            ? (Currency.wrap(address(stock)), Currency.wrap(address(usdg)))
            : (Currency.wrap(address(usdg)), Currency.wrap(address(stock)));
        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(stockHook)));
        int24 tick;
        (id, tick) = stockHook.createPool(key, 0); // start at the oracle price
        int24 mid = tick / 60 * 60;
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(mid - 6000, mid + 6000, 4e17, 0), ZERO_BYTES);
    }

    function _sellStock(int256 amountIn) internal {
        swap(key, stockIs0, -amountIn, ZERO_BYTES);
    }

    function _buyStock(int256 usdgIn) internal {
        swap(key, !stockIs0, -usdgIn, ZERO_BYTES);
    }

    function _total() internal view returns (uint24 total, bool open, bool stale) {
        (,,, total, open, stale) = stockHook.oracleState(id);
    }

    function test_feeFollowsSessionAndStaleness() public {
        (uint160 oSqrt, uint256 priceE18,,,,) = stockHook.oracleState(id);
        (uint160 lo, uint160 hi) = stockHook.bandSqrtPrices(id);
        assertEq(priceE18, 100e18);
        assertTrue(lo < oSqrt && oSqrt < hi);

        (uint24 total, bool open, bool stale) = _total();
        assertEq(total, 3000);
        assertTrue(open && !stale);
        _sellStock(10e18);
        assertEq(stock.balanceOf(collector), 10e18 * 600 / 1e6);

        vm.warp(SAT);
        feed.set(100e8);
        (total, open, stale) = _total();
        assertEq(total, 15_000);
        assertTrue(!open && !stale);
        _buyStock(100e6);
        assertEq(usdg.balanceOf(collector), 100e6 * 3000 / 1e6);

        vm.warp(SAT + 1 days + 1);
        (total,, stale) = _total();
        assertEq(total, 50_000);
        assertTrue(stale);
        // stale: only swaps that move the pool toward the last oracle price
        vm.expectRevert(
            _hookErr(address(stockHook), IHooks.afterSwap.selector, StockHook.StaleAwayFromOracle.selector)
        );
        _sellStock(1e18);
    }

    function test_swapOutsideBandReverts() public {
        _sellStock(10e18); // in band
        vm.expectRevert(_hookErr(address(stockHook), IHooks.afterSwap.selector, StockHook.PriceOutOfBand.selector));
        _sellStock(1000e18); // ~5 % move vs a 2 % band
    }

    function test_towardBandAllowedAwayReverts() public {
        feed.set(110e8); // pool (~$100) is now ~9 % below oracle, outside the band
        vm.expectRevert(_hookErr(address(stockHook), IHooks.afterSwap.selector, StockHook.PriceOutOfBand.selector));
        _sellStock(1e18);
        _buyStock(1000e6); // moves toward the band, still outside it → allowed
        (uint160 sqrtP,,,) = _slot0();
        (uint160 lo, uint160 hi) = stockHook.bandSqrtPrices(id);
        assertTrue(sqrtP < lo || sqrtP > hi);
    }

    function test_onlyRegisteredPairs() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        (Currency c0, Currency c1) = address(other) < address(usdg)
            ? (Currency.wrap(address(other)), Currency.wrap(address(usdg)))
            : (Currency.wrap(address(usdg)), Currency.wrap(address(other)));
        vm.expectRevert(StockHook.NotRegisteredPair.selector);
        stockHook.createPool(PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(stockHook))), 0);
    }

    function _slot0() internal view returns (uint160, int24, uint24, uint24) {
        return StateView.getSlot0(manager, id);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {DammHook} from "../../src/hooks/DammHook.sol";
import {LaunchPools} from "../../src/launch/LaunchPools.sol";
import {HooksBase} from "../hooks/HooksBase.t.sol";

/// Local PoolManager + DammHook (HooksBase) with a LaunchPools on top, plus trading helpers.
abstract contract LaunchBase is HooksBase {
    using StateLibrary for IPoolManager;

    // 1e8 tokens per ETH: 1 token = 1e-8 ETH, so a 1e9 supply starts at a 10 ETH market cap.
    int24 internal constant START_TICK = 184_200;
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant SEED = 8e26;

    LaunchPools internal lp;
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _deployLaunch() internal {
        _deployHooks();
        lp = new LaunchPools(manager, damm);
    }

    function _fees() internal pure returns (DammHook.PoolParams memory) {
        return DammHook.PoolParams({baseFeeBps: 100, snipeStartFeeBps: 5000, snipeSeconds: 600, variableFeeControl: 0});
    }

    function _params() internal view returns (LaunchPools.LaunchParams memory) {
        return LaunchPools.LaunchParams({
            name: "Launch Test",
            symbol: "LT",
            supply: SUPPLY,
            seedAmount: SEED,
            startTick: START_TICK,
            creator: creator,
            fees: _fees()
        });
    }

    function _launch(LaunchPools.LaunchParams memory p) internal returns (address token, PoolId id, PoolKey memory key) {
        vm.prank(creator);
        (token, id,) = lp.launch(p);
        key = lp.poolKeyOf(token);
    }

    /// Exact-input ETH -> token through the swap router.
    function _buy(address who, PoolKey memory key, uint256 ethIn) internal returns (uint256 out) {
        vm.deal(who, who.balance + ethIn);
        vm.prank(who);
        BalanceDelta d = swapRouter.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        out = uint128(d.amount1());
    }

    /// Exact-input token -> ETH through the swap router.
    function _sell(address who, PoolKey memory key, uint256 tokensIn) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20(Currency.unwrap(key.currency1)).approve(address(swapRouter), tokensIn);
        BalanceDelta d = swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        out = uint128(d.amount0());
    }

    function _tick(PoolId id) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id);
    }

    function _positionLiquidity(PoolId id, int24 upper) internal view returns (uint128 liq) {
        (liq,,) = manager.getPositionInfo(id, address(lp), lp.TICK_LOWER(), upper, bytes32(0));
    }

    /// Protocol fee taken in ETH so far: paid out to the collector or held as the hook's 6909 claim.
    function _protocolEth() internal view returns (uint256) {
        return collector.balance + manager.balanceOf(address(damm), 0);
    }
}

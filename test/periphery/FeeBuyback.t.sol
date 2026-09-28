// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PeripheryBase} from "./PeripheryBase.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";
import {FeeCollector} from "../../src/periphery/FeeCollector.sol";
import {Buyback} from "../../src/periphery/Buyback.sol";
import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract PeriFeed {
    int256 public answer;

    constructor(int256 a) {
        answer = a;
    }

    function set(int256 a) external {
        answer = a;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

contract FeeBuybackTest is PeripheryBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    MockERC20 proto;
    PoolKey ethP;
    Buyback buyback;
    FeeCollector collector;
    AssetRegistry registry;
    PeriFeed feedA;
    address keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        proto = new MockERC20("DEEP", "DEEP", 18);
        proto.mint(address(this), 1e30);
        proto.approve(address(modifyLiquidityRouter), type(uint256).max);
        proto.approve(address(swapRouter), type(uint256).max);
        ethP = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(proto)), 3000, 60, IHooks(address(0)));
        manager.initialize(ethP, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1000 ether}(ethP, WIDE, ZERO_BYTES);

        registry = new AssetRegistry(address(this));
        feedA = new PeriFeed(1e8); // A = $1
        registry.setQuote(address(tokA), address(feedA), 1 days, true);
        registry.setQuote(address(0), address(new PeriFeed(1e8)), 1 days, true); // ETH = $1 (1:1 pool)

        buyback = new Buyback(manager, address(this), 5 ether);
        buyback.configure(ethP, "");
        collector = new FeeCollector(address(this), router, registry, address(buyback));

        IRouter.Hop[] memory hops = new IRouter.Hop[](1);
        hops[0] = v4Hop(ethA, address(tokA));
        collector.setRoute(address(tokA), hops, 10e18, true);
        tokA.mint(address(collector), 30e18); // protocol fees accrued
    }

    function test_convert_then_buyback_burns() public {
        vm.prank(keeper);
        uint256 ethOut = collector.convert(address(tokA), 0); // capped at 10e18
        assertEq(tokA.balanceOf(address(collector)), 20e18);
        assertEq(address(buyback).balance, ethOut);
        assertGt(ethOut, 9.8 ether);

        vm.deal(address(collector), 1 ether);
        collector.forwardEth();
        uint256 bal = address(buyback).balance;

        vm.roll(block.number + 1);
        vm.prank(keeper);
        uint256 burned = buyback.buyback();
        uint256 spent = 5 ether - 5 ether * 50 / 10_000;
        assertEq(address(buyback).balance, bal - 5 ether);
        assertEq(keeper.balance, 5 ether * 50 / 10_000);
        assertEq(proto.balanceOf(DEAD), burned);
        assertGt(burned, spent * 98 / 100);
        assertEq(buyback.totalEthSpent(), spent);

        vm.expectRevert(Buyback.OncePerBlock.selector);
        buyback.buyback();
    }

    function test_convert_oracleFloor_and_caps() public {
        vm.expectRevert(FeeCollector.OverCap.selector);
        collector.convert(address(tokA), 11e18);
        feedA.set(2e8); // A now "worth" 2 ETH -> 1:1 pool output far below the floor
        vm.expectRevert(IRouter.TooLittleReceived.selector);
        collector.convert(address(tokA), 5e18);
        vm.expectRevert(FeeCollector.HasRoute.selector);
        collector.sweep(address(tokA), address(this), 1);
        vm.prank(keeper);
        vm.expectRevert();
        collector.sweep(address(tokB), keeper, 1);
    }

    // ---------------------------------------------------------------- buyback price guard

    function _poolPrice() internal view returns (uint160 p) {
        (p,,,) = manager.getSlot0(ethP.toId());
    }

    /// Buy the protocol token with ETH (pushes its price up = sqrtPrice down).
    function _pump(uint256 ethIn) internal {
        swapRouter.swap{value: ethIn}(
            ethP,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// Sell the protocol token for ETH (sqrtPrice up).
    function _dump(uint256 tokIn) internal {
        swapRouter.swap(
            ethP,
            SwapParams({zeroForOne: false, amountSpecified: -int256(tokIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// (a / b)^2 in 1e18: the price ratio between two sqrtPriceX96 values.
    function _priceRatio(uint160 a, uint160 b) internal pure returns (uint256) {
        uint256 r = uint256(a) * 1e18 / b;
        return r * r / 1e18;
    }

    function test_buyback_setsReferenceOnConfigure() public view {
        assertEq(buyback.referenceSqrtPriceX96(), _poolPrice());
        assertEq(buyback.maxDeviationBps(), 500);
        assertEq(buyback.driftBpsPerHour(), 1000);
    }

    function test_buyback_revertsWhenFrontRunPumpBeyondDeviation() public {
        vm.deal(address(buyback), 5 ether);
        vm.roll(block.number + 1);
        _pump(80 ether); // front-run: token price up far beyond 5%
        assertLt(_priceRatio(_poolPrice(), buyback.referenceSqrtPriceX96()), 0.95e18);

        vm.expectPartialRevert(Buyback.PriceOutOfRange.selector);
        buyback.buyback();
    }

    function test_buyback_priceLimitCapsOwnImpact() public {
        Buyback big = new Buyback(manager, address(this), 500 ether);
        big.configure(ethP, "");
        vm.deal(address(big), 500 ether);
        uint160 ref = big.referenceSqrtPriceX96();
        vm.roll(block.number + 1);

        vm.prank(keeper);
        uint256 burned = big.buyback();
        assertGt(burned, 0);
        // The swap stopped at the 5% band instead of eating the whole 500 ETH budget.
        uint256 ratio = _priceRatio(_poolPrice(), ref);
        assertGe(ratio, 0.95e18 - 1e12, "pushed price past the band");
        uint256 spent = big.totalEthSpent();
        assertLt(spent, 100 ether);
        assertGt(address(big).balance, 400 ether, "unspent ETH should stay for later");
        // Reward is paid on what was actually spent (same rate as a full fill).
        assertApproxEqAbs(keeper.balance, spent * 50 / 9950, 1);
    }

    function test_buyback_referenceDriftsAtCappedRateThenResumes() public {
        vm.deal(address(buyback), 5 ether);
        _pump(80 ether); // genuine repricing, no buyback in flight
        uint160 cur = _poolPrice();
        uint160 ref0 = buyback.referenceSqrtPriceX96();
        vm.roll(block.number + 1);
        vm.expectPartialRevert(Buyback.PriceOutOfRange.selector);
        buyback.buyback();

        // Same timestamp as configure: no drift budget yet.
        buyback.poke();
        assertEq(buyback.referenceSqrtPriceX96(), ref0);

        // 30 min at 10%/h -> the reference may move at most 5% (price) toward the pool.
        // (Explicit clock: via-IR can cache block.timestamp across vm.warp calls.)
        uint256 t = block.timestamp + 30 minutes;
        vm.warp(t);
        buyback.poke();
        uint160 ref1 = buyback.referenceSqrtPriceX96();
        assertLt(ref1, ref0);
        assertApproxEqRel(_priceRatio(ref1, ref0), 0.95e18, 1e14);

        // Each update moves at most 5%, so the ~14% repricing is followed in two more steps.
        uint256 steps;
        while (buyback.referenceSqrtPriceX96() != cur) {
            t += 30 minutes;
            vm.warp(t);
            buyback.poke();
            ++steps;
            assertLe(steps, 2, "reference should catch up within 1.5 hours");
        }
        vm.roll(block.number + 1);
        assertGt(buyback.buyback(), 0);
    }

    function test_buyback_flashManipulationCannotMoveReferenceWithoutElapsedTime() public {
        vm.deal(address(buyback), 10 ether);
        vm.roll(block.number + 1);
        buyback.buyback(); // reference refreshed now
        uint160 ref = buyback.referenceSqrtPriceX96();

        // Same block: pump, poke, dump.
        uint256 before = proto.balanceOf(address(this));
        _pump(80 ether);
        buyback.poke();
        _dump(proto.balanceOf(address(this)) - before);
        assertEq(buyback.referenceSqrtPriceX96(), ref, "reference moved inside one timestamp");
    }

    function test_buyback_flashPokeAfterLongIdleIsBoundedByDeviation() public {
        uint160 ref = buyback.referenceSqrtPriceX96();
        vm.warp(1 days + 1); // lots of drift budget accumulated
        uint256 before = proto.balanceOf(address(this));
        _pump(80 ether);
        buyback.poke();
        _dump(proto.balanceOf(address(this)) - before);
        // One poke can move the reference by at most maxDeviationBps (5%).
        assertApproxEqRel(_priceRatio(buyback.referenceSqrtPriceX96(), ref), 0.95e18, 1e14);
    }

    function test_buyback_priceGuardAdmin() public {
        vm.prank(keeper);
        vm.expectRevert();
        buyback.setPriceGuard(300, 500);
        vm.expectRevert(Buyback.BadGuard.selector);
        buyback.setPriceGuard(0, 500);
        vm.expectRevert(Buyback.BadGuard.selector);
        buyback.setPriceGuard(2001, 500);
        buyback.setPriceGuard(300, 500);
        assertEq(buyback.maxDeviationBps(), 300);
        assertEq(buyback.driftBpsPerHour(), 500);

        _pump(80 ether);
        vm.prank(keeper);
        vm.expectRevert();
        buyback.resetReference();
        buyback.resetReference();
        assertEq(buyback.referenceSqrtPriceX96(), _poolPrice());

        Buyback fresh = new Buyback(manager, address(this), 1 ether);
        vm.expectRevert(Buyback.NotConfigured.selector);
        fresh.poke();
        PoolKey memory uninit = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(proto)), 500, 10, IHooks(address(0)));
        vm.expectRevert(Buyback.BadKey.selector);
        fresh.configure(uninit, "");
    }
}

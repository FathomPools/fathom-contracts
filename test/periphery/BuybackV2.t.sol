// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PeripheryBase} from "./PeripheryBase.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Buyback} from "../../src/periphery/Buyback.sol";
import {BuybackV2} from "../../src/periphery/BuybackV2.sol";

contract BuybackV2Test is PeripheryBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    MockERC20 proto;
    PoolKey ethP;
    BuybackV2 bb;
    address keeper = makeAddr("keeper");
    address tester = makeAddr("tester");

    event Received(address indexed from, uint256 amount);

    function setUp() public override {
        super.setUp();
        proto = new MockERC20("DEEP", "DEEP", 18);
        proto.mint(address(this), 1e30);
        proto.approve(address(modifyLiquidityRouter), type(uint256).max);
        proto.approve(address(swapRouter), type(uint256).max);
        ethP = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(proto)), 3000, 60, IHooks(address(0)));
        manager.initialize(ethP, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1000 ether}(ethP, WIDE, ZERO_BYTES);

        bb = new BuybackV2(manager, address(this), 5 ether);
        bb.configure(ethP, "");
    }

    // ---------------------------------------------------------------- helpers

    function _poolPrice() internal view returns (uint160 p) {
        (p,,,) = manager.getSlot0(ethP.toId());
    }

    /// Buy the protocol token with ETH (its price up = sqrtPrice down).
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

    // ---------------------------------------------------------------- the stale-reference fix

    function test_defaults() public view {
        assertEq(bb.referenceSqrtPriceX96(), _poolPrice());
        assertEq(bb.maxDeviationBps(), 1000);
        assertEq(bb.driftBpsPerHour(), 3000);
        assertEq(bb.token(), address(proto));
    }

    /// The mainnet incident: the token fell ~21% while nobody touched the reference for ~45 hours.
    /// v1 reverts until someone pokes it back in 10% steps; v2 buys at once.
    function test_tokenDropWithStaleReference_v1Stuck_v2Buys() public {
        Buyback v1 = new Buyback(manager, address(this), 5 ether);
        v1.configure(ethP, "");
        v1.setPriceGuard(1000, 3000);
        vm.deal(address(v1), 1 ether);
        vm.deal(address(bb), 1 ether);

        _dump(140e18);
        assertGt(_priceRatio(_poolPrice(), bb.referenceSqrtPriceX96()), 1.2e18, "token not >20% cheaper");
        vm.warp(block.timestamp + 45 hours);
        vm.roll(block.number + 1);

        vm.expectPartialRevert(Buyback.PriceOutOfRange.selector);
        v1.buyback();

        uint256 burned = bb.buyback();
        assertGt(burned, 0);
        assertEq(proto.balanceOf(DEAD), burned);
    }

    function test_cheaperTokenNeverBlocks_evenInTheConfigureTimestamp() public {
        vm.deal(address(bb), 1 ether);
        _dump(200e18); // far below the band, no time for the reference to follow
        assertGt(_priceRatio(_poolPrice(), bb.referenceSqrtPriceX96()), 1.3e18);
        vm.roll(block.number + 1);
        assertGt(bb.buyback(), 0);
    }

    function test_frontRunPumpBeyondBand_reverts_andRefundsCaller() public {
        vm.roll(block.number + 1);
        _pump(80 ether); // same timestamp: the reference cannot move, token is >10% above it
        assertLt(_priceRatio(_poolPrice(), bb.referenceSqrtPriceX96()), 0.9e18);

        vm.deal(tester, 0.01 ether);
        vm.prank(tester);
        vm.expectPartialRevert(BuybackV2.PriceAboveBand.selector);
        bb.buyback{value: 0.01 ether}();
        assertEq(tester.balance, 0.01 ether, "ETH must come back on a revert");
        assertEq(address(bb).balance, 0);
    }

    function test_genuinePumpAfterIdle_buysInOneCall() public {
        vm.deal(address(bb), 1 ether);
        _pump(80 ether); // ~14% repricing
        uint160 ref0 = bb.referenceSqrtPriceX96();
        uint256 t = block.timestamp + 1 hours; // drift budget: min(30%, 10%) = 10%
        vm.warp(t);
        vm.roll(block.number + 1);

        assertGt(bb.buyback(), 0);
        assertApproxEqRel(_priceRatio(bb.referenceSqrtPriceX96(), ref0), 0.9e18, 1e14, "reference caught up 10%");
    }

    function test_flashPumpAfterLongIdle_isBoundedByDriftPlusBand() public {
        vm.deal(address(bb), 1 ether);
        uint160 ref0 = bb.referenceSqrtPriceX96();
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1);

        _pump(300 ether); // well past one drift step + the band
        assertLt(_priceRatio(_poolPrice(), ref0), 0.81e18);
        vm.expectPartialRevert(BuybackV2.PriceAboveBand.selector);
        bb.buyback();
        // the revert rolled the drift back as well
        assertEq(bb.referenceSqrtPriceX96(), ref0);
    }

    function test_swapImpactPerCallIsCapped() public {
        BuybackV2 big = new BuybackV2(manager, address(this), 500 ether);
        big.configure(ethP, "");
        vm.deal(address(big), 500 ether);
        uint160 start = _poolPrice();
        vm.roll(block.number + 1);

        vm.prank(keeper);
        uint256 burned = big.buyback();
        assertGt(burned, 0);
        assertGe(_priceRatio(_poolPrice(), start), 0.9e18 - 1e12, "pushed the price past 10%");
        uint256 spent = big.totalEthSpent();
        assertLt(spent, 100 ether);
        assertGt(address(big).balance, 400 ether, "unspent ETH stays for later");
        assertApproxEqAbs(keeper.balance, spent * 50 / 9950, 1);
    }

    function test_pokeCannotMoveReferenceWithinOneTimestamp() public {
        vm.deal(address(bb), 1 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        bb.buyback(); // reference refreshed now
        uint160 ref = bb.referenceSqrtPriceX96();

        uint256 before = proto.balanceOf(address(this));
        _pump(80 ether);
        bb.poke();
        _dump(proto.balanceOf(address(this)) - before);
        assertEq(bb.referenceSqrtPriceX96(), ref, "reference moved inside one timestamp");
    }

    // ---------------------------------------------------------------- anyone, any size

    function testFuzz_anyoneCanBurnAnyAmountWithOwnEth(uint256 amount) public {
        amount = bound(amount, 1e6, 0.1 ether);
        vm.deal(tester, amount);
        vm.roll(block.number + 1);

        vm.expectEmit(true, false, false, true, address(bb));
        emit Received(tester, amount);
        vm.prank(tester);
        uint256 burned = bb.buyback{value: amount}();

        assertGt(burned, 0);
        assertEq(proto.balanceOf(DEAD), burned);
        uint256 spent = bb.totalEthSpent();
        assertEq(spent, amount - amount * 50 / 10_000);
        assertApproxEqAbs(tester.balance, spent * 50 / 9950, 1, "caller reward");
        assertLe(address(bb).balance, 2, "nothing left over but rounding");
    }

    function test_userEthAndFeeEthAreSpentTogether_capStillApplies() public {
        vm.deal(address(bb), 4.9 ether); // fees waiting
        vm.deal(tester, 1 ether);
        vm.roll(block.number + 1);
        vm.prank(tester);
        bb.buyback{value: 1 ether}();
        assertEq(bb.totalEthSpent(), 5 ether - 5 ether * 50 / 10_000);
        assertEq(address(bb).balance, 0.9 ether, "above maxEthPerCall stays for the next call");
    }

    function test_receiveRecordsSender() public {
        vm.deal(keeper, 1 ether);
        vm.expectEmit(true, false, false, true, address(bb));
        emit Received(keeper, 1 ether);
        vm.prank(keeper);
        (bool ok,) = address(bb).call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_nothingToSpend_and_oncePerBlock() public {
        vm.roll(block.number + 1);
        vm.expectRevert(BuybackV2.NothingToSpend.selector);
        bb.buyback();

        vm.deal(address(bb), 1 ether);
        bb.buyback();
        vm.deal(tester, 1 ether);
        vm.prank(tester);
        vm.expectRevert(BuybackV2.OncePerBlock.selector);
        bb.buyback{value: 1 ether}();
        assertEq(tester.balance, 1 ether);
    }

    // ---------------------------------------------------------------- admin

    function test_admin() public {
        vm.prank(keeper);
        vm.expectRevert();
        bb.setPriceGuard(300, 500);
        vm.expectRevert(BuybackV2.BadGuard.selector);
        bb.setPriceGuard(0, 500);
        vm.expectRevert(BuybackV2.BadGuard.selector);
        bb.setPriceGuard(2001, 500);
        bb.setPriceGuard(300, 500);
        assertEq(bb.maxDeviationBps(), 300);
        assertEq(bb.driftBpsPerHour(), 500);

        _pump(80 ether);
        vm.prank(keeper);
        vm.expectRevert();
        bb.resetReference();
        bb.resetReference();
        assertEq(bb.referenceSqrtPriceX96(), _poolPrice());

        vm.expectRevert(BuybackV2.AlreadyConfigured.selector);
        bb.configure(ethP, "");
        vm.expectRevert(BuybackV2.BadReward.selector);
        bb.setCallerRewardBps(501);

        BuybackV2 fresh = new BuybackV2(manager, address(this), 1 ether);
        vm.expectRevert(BuybackV2.NotConfigured.selector);
        fresh.poke();
        vm.expectRevert(BuybackV2.NotConfigured.selector);
        fresh.buyback();
        PoolKey memory uninit = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(proto)), 500, 10, IHooks(address(0)));
        vm.expectRevert(BuybackV2.BadKey.selector);
        fresh.configure(uninit, "");
    }
}

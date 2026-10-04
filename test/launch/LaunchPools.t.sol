// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {DammHook} from "../../src/hooks/DammHook.sol";
import {LaunchPools} from "../../src/launch/LaunchPools.sol";
import {LaunchToken} from "../../src/launch/LaunchToken.sol";
import {LaunchBase} from "./LaunchBase.t.sol";

contract LaunchPoolsTest is LaunchBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PIPS = 1e6;

    function setUp() public {
        _deployLaunch();
    }

    // ---------------------------------------------------------------- launch

    function test_launch_tokenPoolAndLockedPosition() public {
        LaunchPools.LaunchParams memory p = _params();
        (uint128 liq, uint256 seeded) = lp.preview(p);
        (address token, PoolId id, PoolKey memory key) = _launch(p);

        // token: fixed supply, all accounted for
        IERC20Metadata t = IERC20Metadata(token);
        assertEq(t.name(), "Launch Test");
        assertEq(t.symbol(), "LT");
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.balanceOf(address(manager)), seeded);
        assertEq(t.balanceOf(creator), SUPPLY - seeded);
        assertEq(t.balanceOf(address(lp)), 0);
        assertLe(seeded, SEED);
        assertLt(SEED - seeded, 1e9, "rounding dust only");

        // pool: native ETH / token on the DAMM hook, at the start tick, params stored by the hook
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), token);
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(key.tickSpacing, 60);
        assertEq(address(key.hooks), address(damm));
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(id));
        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(id);
        assertEq(tick, START_TICK);
        assertEq(sqrtP, TickMath.getSqrtPriceAtTick(START_TICK));
        (uint16 base, uint16 snipeStart, uint32 snipeSecs,, uint40 createdAt,,,) = damm.pools(id);
        assertEq(base, 100);
        assertEq(snipeStart, 5000);
        assertEq(snipeSecs, 600);
        assertEq(createdAt, block.timestamp);

        // position: held by LaunchPools, one-sided below the start price, not yet in range
        assertEq(_positionLiquidity(id, START_TICK), liq);
        assertEq(manager.getLiquidity(id), 0);
        LaunchPools.Launch memory l = lp.getLaunch(id);
        assertEq(l.token, token);
        assertEq(l.feeRecipient, creator);
        assertEq(l.startTick, START_TICK);
        assertEq(l.liquidity, liq);
        assertEq(l.launchedAt, block.timestamp);
        assertEq(lp.launchCount(), 1);
        (PoolId[] memory ids, LaunchPools.Launch[] memory ls) = lp.getLaunches(0, 10);
        assertEq(ids.length, 1);
        assertEq(PoolId.unwrap(ids[0]), PoolId.unwrap(id));
        assertEq(ls[0].token, token);
        assertEq(address(lp).balance, 0);
    }

    function test_launch_seedEqualsSupply_creatorGetsOnlyDust() public {
        LaunchPools.LaunchParams memory p = _params();
        p.seedAmount = SUPPLY;
        (, uint256 seeded) = lp.preview(p);
        (address token,,) = _launch(p);
        assertEq(IERC20(token).balanceOf(creator), SUPPLY - seeded);
        assertLt(SUPPLY - seeded, 1e9);
    }

    function test_launch_creatorCanBeAnotherAddress() public {
        LaunchPools.LaunchParams memory p = _params();
        p.creator = bob;
        vm.prank(alice);
        (address token, PoolId id,) = lp.launch(p);
        assertEq(lp.getLaunch(id).feeRecipient, bob);
        assertGt(IERC20(token).balanceOf(bob), 0);
        assertEq(IERC20(token).balanceOf(alice), 0);
    }

    function test_launch_twoLaunchesSameNameAreSeparate() public {
        (address t1, PoolId id1,) = _launch(_params());
        (address t2, PoolId id2,) = _launch(_params());
        assertTrue(t1 != t2);
        assertTrue(PoolId.unwrap(id1) != PoolId.unwrap(id2));
        assertEq(lp.launchCount(), 2);
        (PoolId[] memory ids,) = lp.getLaunches(1, 5);
        assertEq(ids.length, 1);
        assertEq(PoolId.unwrap(ids[0]), PoolId.unwrap(id2));
        (ids,) = lp.getLaunches(7, 5);
        assertEq(ids.length, 0);
    }

    /// The PoolManager takes any address as a currency, so whoever knows the next token address can
    /// initialize its pool first. The address depends on the block, so that only works inside the same
    /// block, and then the launch simply works again one block later.
    function test_launch_poolTakenFirst_revertsThenWorksNextBlock() public {
        LaunchPools.LaunchParams memory p = _params();
        bytes32 salt = keccak256(abi.encode(creator, uint256(0), vm.getBlockNumber()));
        bytes32 initHash =
            keccak256(abi.encodePacked(type(LaunchToken).creationCode, abi.encode(p.name, p.symbol, p.supply, address(lp))));
        address predicted = vm.computeCreate2Address(salt, initHash, address(lp));
        vm.prank(alice);
        damm.createPool(lp.poolKeyOf(predicted), SQRT_PRICE_1_1, p.fees); // nothing deployed there yet

        vm.prank(creator);
        vm.expectRevert(LaunchPools.LaunchPools__PoolTaken.selector);
        lp.launch(p);

        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(creator);
        (address token, PoolId id,) = lp.launch(p);
        assertTrue(token != predicted);
        assertEq(_tick(id), START_TICK);
    }

    function test_token_isPlainFixedSupplyErc20() public {
        (address token,,) = _launch(_params());
        bytes[4] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("mint(address,uint256)", creator, 1),
            abi.encodeWithSignature("burn(uint256)", 1),
            abi.encodeWithSignature("transferOwnership(address)", alice)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(creator);
            (bool ok,) = token.call(calls[i]);
            assertFalse(ok);
        }
        // no transfer fee, no exemptions: exact amounts between any holders, including the pool
        vm.prank(creator);
        IERC20(token).transfer(alice, 1e24);
        assertEq(IERC20(token).balanceOf(alice), 1e24);
        vm.prank(alice);
        IERC20(token).transfer(bob, 3e23);
        assertEq(IERC20(token).balanceOf(bob), 3e23);
        assertEq(IERC20(token).totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- trading through the anti-snipe window

    /// A buy at the start price pays the full snipe fee: 20 % of it to the protocol on the input,
    /// 80 % as the LP fee. Output matches the curve exactly.
    function test_buy_atLaunchPaysSnipeStartFee() public {
        (address token, PoolId id, PoolKey memory key) = _launch(_params());
        (uint24 lpPips, uint24 totalPips) = damm.currentFee(id);
        assertEq(totalPips, 500_000);
        assertEq(lpPips, 400_000);

        uint256 out = _buy(alice, key, 1 ether);
        uint128 liq = lp.getLaunch(id).liquidity;
        assertEq(out, _curveOut(liq, 1 ether, 500_000));
        assertEq(IERC20(token).balanceOf(alice), out);
        assertEq(_protocolEth(), 1 ether * 100_000 / PIPS);
        assertLt(_tick(id), START_TICK);
        assertEq(manager.getLiquidity(id), liq);
    }

    function test_snipeFeeDecaysToBase_buyerGetsMoreLater() public {
        (, PoolId id, PoolKey memory key) = _launch(_params());
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();

        uint256 out0 = _buy(alice, key, 1 ether);
        vm.revertToState(snap);
        vm.warp(t0 + 300);
        (, uint24 mid) = damm.currentFee(id);
        assertEq(mid, 255_000); // 5000 - 4900 * 300/600 = 2550 bps
        uint256 out1 = _buy(alice, key, 1 ether);
        vm.revertToState(snap);
        vm.warp(t0 + 600);
        (, uint24 end) = damm.currentFee(id);
        assertEq(end, 10_000); // base 100 bps
        uint256 out2 = _buy(alice, key, 1 ether);

        uint128 liq = lp.getLaunch(id).liquidity;
        assertEq(out0, _curveOut(liq, 1 ether, 500_000));
        assertEq(out1, _curveOut(liq, 1 ether, 255_000));
        assertEq(out2, _curveOut(liq, 1 ether, 10_000));
        assertLt(out0, out1);
        assertLt(out1, out2);
    }

    function test_volatilitySurchargeAfterBigBuy() public {
        LaunchPools.LaunchParams memory p = _params();
        p.fees.variableFeeControl = 10_000;
        (, PoolId id, PoolKey memory key) = _launch(p);
        vm.warp(vm.getBlockTimestamp() + 600);
        (, uint24 total) = damm.currentFee(id);
        assertEq(total, 10_000);
        _buy(alice, key, 5 ether);
        (, total) = damm.currentFee(id);
        assertGt(total, 10_000);
        assertLe(total, 50_000); // 500 bps cap outside the snipe window
        vm.warp(vm.getBlockTimestamp() + 600);
        (, total) = damm.currentFee(id);
        assertEq(total, 10_000);
    }

    // ---------------------------------------------------------------- fees of the launch position

    function test_feesAccrueToLaunchPosition_anyoneCollectsToCreator() public {
        (address token, PoolId id, PoolKey memory key) = _launch(_params());
        vm.warp(vm.getBlockTimestamp() + 600); // base fee 100 bps, no surcharge (vfc 0)
        _buy(alice, key, 2 ether);
        uint256 got = IERC20(token).balanceOf(alice);
        _sell(alice, key, got / 2);

        (uint256 f0, uint256 f1) = lp.pendingFees(id);
        // LP share: 80 % of 100 bps on the input after the protocol's 20 bps
        assertApproxEqRel(f0, (2 ether - 2 ether * 2000 / PIPS) * 8000 / PIPS, 1e12);
        assertApproxEqRel(f1, (got / 2 - (got / 2) * 2000 / PIPS) * 8000 / PIPS, 1e12);

        uint256 e0 = creator.balance;
        uint256 b0 = IERC20(token).balanceOf(creator);
        vm.prank(bob); // anyone can trigger, the creator is paid
        (uint256 a0, uint256 a1) = lp.collectFees(id);
        assertEq(a0, f0);
        assertEq(a1, f1);
        assertEq(creator.balance - e0, f0);
        assertEq(IERC20(token).balanceOf(creator) - b0, f1);
        assertEq(bob.balance, 0);

        (f0, f1) = lp.pendingFees(id);
        assertEq(f0 + f1, 0);
        (a0, a1) = lp.collectFees(id);
        assertEq(a0 + a1, 0);
        assertEq(_positionLiquidity(id, START_TICK), lp.getLaunch(id).liquidity, "liquidity untouched");
    }

    /// A sniper in the launch block pays 50 %: 10 % to the protocol, 40 % (of the rest) to the creator.
    function test_sniperFeeAccruesToLaunchPosition() public {
        (, PoolId id, PoolKey memory key) = _launch(_params());
        _buy(alice, key, 5 ether);
        (uint256 f0, uint256 f1) = lp.pendingFees(id);
        assertApproxEqAbs(f0, 4.5 ether * 400_000 / PIPS, 1);
        assertEq(f1, 0);
        assertEq(_protocolEth(), 0.5 ether);
        lp.collectFees(id);
        assertApproxEqAbs(creator.balance, 1.8 ether, 1);
    }

    function test_setFeeRecipient_onlyCurrentRecipient() public {
        (, PoolId id, PoolKey memory key) = _launch(_params());
        vm.prank(alice);
        vm.expectRevert(LaunchPools.LaunchPools__NotFeeRecipient.selector);
        lp.setFeeRecipient(id, alice);
        vm.prank(creator);
        vm.expectRevert(LaunchPools.LaunchPools__ZeroAddress.selector);
        lp.setFeeRecipient(id, address(0));
        vm.expectRevert(LaunchPools.LaunchPools__UnknownLaunch.selector);
        lp.setFeeRecipient(PoolId.wrap(bytes32(uint256(1))), alice);

        vm.prank(creator);
        lp.setFeeRecipient(id, bob);
        assertEq(lp.getLaunch(id).feeRecipient, bob);
        vm.prank(creator);
        vm.expectRevert(LaunchPools.LaunchPools__NotFeeRecipient.selector);
        lp.setFeeRecipient(id, creator);

        _buy(alice, key, 1 ether);
        uint256 c0 = creator.balance;
        (uint256 a0,) = lp.collectFees(id);
        assertGt(a0, 0);
        assertEq(bob.balance, a0);
        assertEq(creator.balance, c0);
    }

    function test_collect_unknownLaunchReverts() public {
        vm.expectRevert(LaunchPools.LaunchPools__UnknownLaunch.selector);
        lp.collectFees(PoolId.wrap(bytes32(uint256(7))));
        (uint256 f0, uint256 f1) = lp.pendingFees(PoolId.wrap(bytes32(uint256(7))));
        assertEq(f0 + f1, 0);
    }

    /// Pausing blocks new launches (the hook gates adding liquidity) but never fee collection, and the
    /// launch position cannot be touched by anyone else.
    function test_pause_blocksLaunchNotCollect_positionLocked() public {
        (, PoolId id, PoolKey memory key) = _launch(_params());
        _buy(alice, key, 1 ether);
        uint128 liq = lp.getLaunch(id).liquidity;

        vm.prank(owner);
        config.setPaused(true);
        LaunchPools.LaunchParams memory p = _params();
        vm.prank(creator);
        vm.expectRevert();
        lp.launch(p);
        (uint256 a0,) = lp.collectFees(id);
        assertGt(a0, 0);

        // Removing liquidity through the PoolManager only ever touches the caller's own positions.
        vm.prank(owner);
        config.setPaused(false);
        ModifyLiquidityParams memory rm = ModifyLiquidityParams(lp.TICK_LOWER(), START_TICK, -int256(uint256(liq)), 0);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(key, rm, "");
        assertEq(_positionLiquidity(id, START_TICK), liq);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(LaunchPools.LaunchPools__NotPoolManager.selector);
        lp.unlockCallback(abi.encode(false, ""));
    }

    // ---------------------------------------------------------------- buy at launch

    /// ETH sent with `launch` is the pool's first swap; the LP share of its fee comes straight back.
    function test_launchWithBuy_paysBackLpShare() public {
        LaunchPools.LaunchParams memory p = _params();
        (uint128 liq, uint256 seeded) = lp.preview(p);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (address token, PoolId id, uint256 bought) = lp.launch{value: 1 ether}(p);

        uint256 proto = 1 ether * 100_000 / PIPS;
        assertEq(bought, _curveOut(liq, 1 ether, 500_000));
        uint256 lpFee = (1 ether - proto) - (1 ether - proto) * 600_000 / PIPS; // 40 % LP fee on the rest

        assertEq(IERC20(token).balanceOf(alice), bought);
        assertApproxEqAbs(alice.balance, lpFee, 1, "LP share of the fee paid back");
        assertEq(_protocolEth(), proto);
        assertEq(IERC20(token).balanceOf(creator), SUPPLY - seeded);
        assertEq(IERC20(token).balanceOf(address(manager)), seeded - bought);
        assertEq(address(lp).balance, 0);
        assertEq(IERC20(token).balanceOf(address(lp)), 0);
        (uint256 f0, uint256 f1) = lp.pendingFees(id);
        assertEq(f0 + f1, 0);
        assertLt(_tick(id), START_TICK);
    }

    /// The launch buy gets exactly what the first swap after launch would, but keeps the LP share.
    function test_launchWithBuy_sameTokensAsFirstSwap_lpShareBack() public {
        LaunchPools.LaunchParams memory p = _params();
        uint256 snap = vm.snapshotState();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (,, uint256 viaLaunch) = lp.launch{value: 1 ether}(p);
        uint256 cost = 1 ether - alice.balance;
        vm.revertToState(snap);
        (,, PoolKey memory key) = _launch(p);
        uint256 viaSwap = _buy(alice, key, 1 ether);
        assertEq(viaLaunch, viaSwap, "same tokens");
        assertLt(cost, 0.65 ether, "but the LP share came back");
    }

    function test_creatorDump_boundedByEthInPool() public {
        (address token, PoolId id, PoolKey memory key) = _launch(_params());
        _buy(alice, key, 1 ether);
        uint256 poolEth = address(manager).balance;
        uint256 dump = IERC20(token).balanceOf(creator);
        uint256 out = _sell(creator, key, dump);
        assertLe(out, poolEth);
        assertGe(_tick(id), START_TICK, "price back at or above the start");
    }

    // ---------------------------------------------------------------- param checks

    function test_preview_rejectsBadParams() public {
        LaunchPools.LaunchParams memory p;

        p = _params();
        p.name = "";
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadName.selector);
        p.name = "0123456789012345678901234567890123456789012345678901234567890123x"; // 65 bytes
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadName.selector);
        p = _params();
        p.symbol = "";
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadName.selector);
        p.symbol = "SEVENTEEN_CHARS_X";
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadName.selector);

        p = _params();
        p.supply = 0;
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadSupply.selector);
        p.supply = 1e33 + 1;
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadSupply.selector);

        p = _params();
        p.seedAmount = 0;
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadSeed.selector);
        p.seedAmount = SUPPLY + 1;
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadSeed.selector);
        p = _params();
        p.seedAmount = 1;
        p.startTick = 800_040; // seed too small for any liquidity at this price
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadSeed.selector);
        p = _params();
        p.supply = 1e33;
        p.seedAmount = 1e33;
        p.startTick = -120_000; // more liquidity than one tick can hold
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadSeed.selector);

        p = _params();
        p.creator = address(0);
        _expectPreviewRevert(p, LaunchPools.LaunchPools__ZeroAddress.selector);

        p = _params();
        p.startTick = START_TICK + 1;
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadTick.selector);
        p.startTick = -887_220;
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadTick.selector);
        p.startTick = 887_280;
        _expectPreviewRevert(p, LaunchPools.LaunchPools__BadTick.selector);

        DammHook.PoolParams[6] memory bad = [
            DammHook.PoolParams(100, 5000, 0, 0), // no anti-snipe window
            DammHook.PoolParams(100, 100, 600, 0), // start fee not above base
            DammHook.PoolParams(4, 5000, 600, 0), // base below 5 bps
            DammHook.PoolParams(101, 5000, 600, 0), // base above 100 bps
            DammHook.PoolParams(100, 5001, 600, 0), // start above 5000 bps
            DammHook.PoolParams(100, 5000, 3601, 0) // window above 1 h
        ];
        for (uint256 i; i < bad.length; ++i) {
            p = _params();
            p.fees = bad[i];
            _expectPreviewRevert(p, LaunchPools.LaunchPools__BadFees.selector);
        }

        // the extremes that are allowed
        p = _params();
        p.startTick = 887_220;
        p.seedAmount = SUPPLY;
        p.supply = SUPPLY;
        lp.preview(p);
        p.startTick = -887_160; // the narrowest range: a tiny seed already fills a tick's liquidity cap
        p.supply = 1e18;
        p.seedAmount = 1e9;
        lp.preview(p);
    }

    function test_launch_revertsOnBadParams() public {
        LaunchPools.LaunchParams memory p = _params();
        p.fees.snipeSeconds = 0;
        vm.expectRevert(LaunchPools.LaunchPools__BadFees.selector);
        lp.launch(p);
        assertEq(lp.launchCount(), 0);
    }

    /// Tokens out of a buy of `ethIn` from the start price at fee `totalPips` (20 % protocol share on the
    /// input first, the rest as the LP fee), straight from the pool math (SqrtPriceMath).
    function _curveOut(uint128 liq, uint256 ethIn, uint256 totalPips) internal pure returns (uint256) {
        uint256 protoPips = totalPips * 2000 / 10_000;
        uint256 lessFee = (ethIn - ethIn * protoPips / PIPS) * (PIPS - (totalPips - protoPips)) / PIPS;
        uint160 start = TickMath.getSqrtPriceAtTick(START_TICK);
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(start, liq, lessFee, true);
        return SqrtPriceMath.getAmount1Delta(next, start, liq, false);
    }

    function _expectPreviewRevert(LaunchPools.LaunchParams memory p, bytes4 err) internal {
        vm.expectRevert(err);
        lp.preview(p);
    }

    // ---------------------------------------------------------------- fuzz

    /// Any valid launch with any first buy: supply is conserved, the buy never takes more than the seed,
    /// ETH is fully accounted for and nothing stays in LaunchPools.
    function testFuzz_launchAndBuy_conservesSupplyAndEth(uint256 supply, uint256 seed, int256 tickSteps, uint256 buyEth)
        public
    {
        supply = bound(supply, 1e18, 1e32);
        seed = bound(seed, 1e18, supply);
        int24 tick = int24(bound(tickSteps, -1000, 6666)) * 60; // -60_000 .. 399_960
        buyEth = bound(buyEth, 0, 1000 ether);
        LaunchPools.LaunchParams memory p = _params();
        p.supply = supply;
        p.seedAmount = seed;
        p.startTick = tick;
        (, uint256 seeded) = lp.preview(p);

        vm.deal(alice, buyEth);
        vm.prank(alice);
        (address token, PoolId id, uint256 bought) = lp.launch{value: buyEth}(p);
        IERC20 t = IERC20(token);
        assertLe(seeded, seed);
        assertLe(bought, seeded);
        assertEq(t.balanceOf(alice), bought);
        assertEq(t.balanceOf(creator), supply - seeded);
        assertEq(t.balanceOf(address(manager)) + t.balanceOf(alice) + t.balanceOf(creator), supply);
        assertEq(t.balanceOf(address(lp)), 0);
        assertEq(address(lp).balance, 0);
        // what alice spent sits in the pool, apart from the protocol share
        assertEq(buyEth - alice.balance, address(manager).balance + collector.balance);
        assertLe(_tick(id), tick);
        if (buyEth == 0) assertEq(bought, 0);
    }

    /// Buying and selling straight back never returns more ETH than was paid, at any point of the window.
    function testFuzz_roundTripNeverProfits(uint256 ethIn, uint256 wait) public {
        (address token,, PoolKey memory key) = _launch(_params());
        ethIn = bound(ethIn, 1e9, 200 ether);
        vm.warp(vm.getBlockTimestamp() + bound(wait, 0, 1200));
        uint256 out = _buy(alice, key, ethIn);
        vm.assume(out > 0);
        uint256 back = _sell(alice, key, out);
        assertLt(back, ethIn);
        assertEq(IERC20(token).balanceOf(alice), 0);
    }
}

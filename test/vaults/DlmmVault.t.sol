// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProtocolConfig} from "../../src/core/ProtocolConfig.sol";
import {DlmmFactory} from "../../src/dlmm/DlmmFactory.sol";
import {DlmmPair} from "../../src/dlmm/DlmmPair.sol";
import {DlmmVault} from "../../src/vaults/DlmmVault.sol";
import {DlmmVaultFactory} from "../../src/vaults/DlmmVaultFactory.sol";
import {BinMath} from "../../src/libraries/BinMath.sol";
import {DlmmMockERC20} from "../dlmm/DlmmMockERC20.sol";

contract DlmmVaultTest is Test {
    uint24 constant CENTER = 1 << 23;
    uint16 constant BIN_STEP = 10;
    uint24 constant H = 20;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address collector = makeAddr("collector");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address trader = makeAddr("trader");

    ProtocolConfig config;
    DlmmFactory dlmm;
    DlmmVaultFactory factory;
    DlmmMockERC20 tX; // 18 decimals (WETH-like)
    DlmmMockERC20 tY; // 6 decimals (USDG-like)
    DlmmPair pair;
    DlmmVault vault;

    // ~2000 Y per X in raw units: 2000e6 / 1e18 = 2e-9 => id = CENTER + ln(2e-9)/ln(1.001)
    uint24 ACTIVE;

    function setUp() public {
        config = new ProtocolConfig(owner, collector);
        dlmm = new DlmmFactory(config);
        factory = new DlmmVaultFactory(config, dlmm);
        tX = new DlmmMockERC20("WETH", 18);
        tY = new DlmmMockERC20("USDG", 6);
        ACTIVE = CENTER - 20_040; // (1.001)^-20040 ~= 2.0e-9
        pair = DlmmPair(dlmm.createPair(address(tX), address(tY), BIN_STEP, ACTIVE));

        vm.startPrank(owner);
        factory.setKeeper(keeper);
        vault = DlmmVault(factory.createVault(address(pair), H, 0));
        vm.stopPrank();

        address[3] memory users = [alice, bob, trader];
        for (uint256 i; i < 3; ++i) {
            tX.mint(users[i], 1_000_000e18);
            tY.mint(users[i], 1_000_000_000e6);
            vm.startPrank(users[i]);
            tX.approve(address(vault), type(uint256).max);
            tY.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------ helpers

    function _deposit(address who, uint256 x, uint256 y) internal returns (uint256 shares, uint256 ax, uint256 ay) {
        uint24 a = pair.getActiveId();
        vm.prank(who);
        return vault.deposit(x, y, 0, who, a, 0, block.timestamp);
    }

    function _withdrawAll(address who) internal returns (uint256 x, uint256 y) {
        uint256 s = vault.balanceOf(who);
        vm.prank(who);
        return vault.withdraw(s, who, 0, 0, block.timestamp);
    }

    function _swap(bool swapForY, uint256 amountIn) internal returns (uint256 out) {
        vm.startPrank(trader);
        (swapForY ? tX : tY).transfer(address(pair), amountIn);
        out = pair.swap(swapForY, trader);
        vm.stopPrank();
    }

    /// Value in Y raw units at the current active price.
    function _value(uint256 x, uint256 y) internal view returns (uint256) {
        return BinMath.getLiquidity(x, y, pair.getPriceFromId(pair.getActiveId()));
    }

    function _rebalance() internal {
        uint24 a = pair.getActiveId();
        vm.prank(keeper);
        vault.rebalance(a, 0);
    }

    // ------------------------------------------------------------------ factory

    function test_factory() public {
        assertEq(factory.allVaultsLength(), 1);
        assertTrue(factory.isVault(address(vault)));
        assertEq(factory.getVault(address(pair), H, 0), address(vault));
        assertEq(vault.name(), "Fathom Vault WETH-USDG");
        assertEq(vault.symbol(), "fvWETH-USDG");
        assertEq(vault.decimals(), 6);
        assertEq(vault.halfWidth(), H);
        assertEq(vault.lowerId(), ACTIVE - H);
        assertEq(vault.upperId(), ACTIVE + H);

        vm.expectRevert(DlmmVaultFactory.DlmmVaultFactory__NotOwner.selector);
        factory.createVault(address(pair), 10, 1);
        vm.expectRevert(DlmmVaultFactory.DlmmVaultFactory__NotOwner.selector);
        factory.setKeeper(alice);
        vm.startPrank(owner);
        vm.expectRevert(DlmmVaultFactory.DlmmVaultFactory__VaultExists.selector);
        factory.createVault(address(pair), H, 0);
        vm.expectRevert(DlmmVaultFactory.DlmmVaultFactory__UnknownPair.selector);
        factory.createVault(alice, H, 0);
        vm.expectRevert(DlmmVault.DlmmVault__InvalidParams.selector);
        factory.createVault(address(pair), 51, 0);
        vm.expectRevert(DlmmVault.DlmmVault__InvalidParams.selector);
        factory.createVault(address(pair), 10, 3);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ deposits

    function test_firstDeposit_spot() public {
        (uint256 shares, uint256 ax, uint256 ay) = _deposit(alice, 10e18, 20_000e6);
        assertEq(ax, 10e18);
        assertEq(ay, 20_000e6);
        // value in Y at the active price (~40k USDG, 6 decimals), minus the locked minimum
        uint256 v = _value(10e18, 20_000e6);
        assertEq(shares, v - vault.MIN_SHARES());
        assertEq(vault.balanceOf(address(0xdEaD)), vault.MIN_SHARES());
        assertApproxEqRel(shares, 40_000e6, 0.01e18);

        (uint24 lower, uint256[] memory bx, uint256[] memory by) = vault.getBins();
        assertEq(lower, ACTIVE - H);
        assertEq(bx.length, 2 * H + 1);
        // Spot: equal X per bin above the active bin, equal Y per bin below, half of each in the active bin.
        assertEq(bx[0], 0);
        assertEq(by[2 * H], 0);
        assertApproxEqRel(bx[H + 1], bx[2 * H], 1e12);
        assertApproxEqRel(by[0], by[H - 1], 1e12);
        assertApproxEqRel(bx[H] * 2, bx[H + 1], 1e15);
        assertApproxEqRel(by[H] * 2, by[H - 1], 1e15);

        (uint256 tx_, uint256 ty) = vault.getTotalAmounts();
        assertApproxEqAbs(tx_, 10e18, 1);
        assertApproxEqAbs(ty, 20_000e6, 1);
        // everything but rounding dust is in the bins
        assertLt(tX.balanceOf(address(vault)), 1e6);
        assertLt(tY.balanceOf(address(vault)), 100);
    }

    function test_secondDeposit_isExactSlice() public {
        _deposit(alice, 10e18, 20_000e6);
        (uint256 tx0, uint256 ty0) = vault.getTotalAmounts();
        uint256 s0 = vault.totalSupply();

        (uint256 shares, uint256 ax, uint256 ay) = _deposit(bob, 5e18, 100_000e6); // Y is surplus
        // X is the binding side: half the vault's X => half its supply
        assertApproxEqRel(shares, s0 / 2, 1e12);
        assertApproxEqAbs(ax, 5e18, 1);
        assertApproxEqRel(ay, ty0 / 2, 1e12);

        (uint256 tx1, uint256 ty1) = vault.getTotalAmounts();
        // per-share amounts unchanged (bins rounding only)
        assertApproxEqRel(tx1 * 1e18 / vault.totalSupply(), tx0 * 1e18 / s0, 1e12);
        assertApproxEqRel(ty1 * 1e18 / vault.totalSupply(), ty0 * 1e18 / s0, 1e12);

        // Bob can leave right away with what he put in (minus dust).
        (uint256 wx, uint256 wy) = _withdrawAll(bob);
        assertApproxEqRel(wx, ax, 1e12);
        assertApproxEqRel(wy, ay, 1e12);
        assertLe(wx, ax);
        assertLe(wy, ay);
    }

    function test_deposit_guards() public {
        uint24 a = pair.getActiveId();
        vm.startPrank(alice);
        vm.expectRevert(DlmmVault.DlmmVault__Expired.selector);
        vault.deposit(1e18, 1e6, 0, alice, a, 0, block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(DlmmVault.DlmmVault__ActiveIdSlippage.selector, a));
        vault.deposit(1e18, 1e6, 0, alice, a + 3, 2, block.timestamp);
        vm.expectRevert(DlmmVault.DlmmVault__ZeroAmount.selector);
        vault.deposit(0, 0, 0, alice, a, 0, block.timestamp);
        vm.expectRevert(DlmmVault.DlmmVault__ZeroAddress.selector);
        vault.deposit(1e18, 1e6, 0, address(0), a, 0, block.timestamp);
        vm.stopPrank();

        _deposit(alice, 10e18, 20_000e6);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(1e18, 2_000e6, type(uint256).max, bob, a, 0, block.timestamp);

        vm.prank(owner);
        config.setPaused(true);
        vm.prank(bob);
        vm.expectRevert(DlmmVault.DlmmVault__Paused.selector);
        vault.deposit(1e18, 2_000e6, 0, bob, a, 0, block.timestamp);
    }

    function test_deposit_oneSided() public {
        // Only Y: the range still opens around the active bin, Y below it.
        (uint256 shares,,) = _deposit(alice, 0, 50_000e6);
        assertEq(shares, 50_000e6 - vault.MIN_SHARES());
        (, uint256[] memory bx, uint256[] memory by) = vault.getBins();
        for (uint256 i; i <= 2 * H; ++i) assertEq(bx[i], 0);
        assertGt(by[0], 0);
        assertGt(by[H], 0);
        assertEq(by[H + 1], 0);

        // A later deposit only takes Y too.
        (, uint256 ax, uint256 ay) = _deposit(bob, 3e18, 1_000e6);
        assertEq(ax, 0);
        assertApproxEqAbs(ay, 1_000e6, 1);
    }

    function test_tinyDeposit_skipsDustBins() public {
        _deposit(alice, 10e18, 20_000e6);
        // 1e9 wei of X over ~21 bins mints dust pair shares per bin: must not revert.
        (uint256 shares,,) = _deposit(bob, 1e9, 1e6);
        assertGt(shares, 0);
        (uint256 wx, uint256 wy) = _withdrawAll(bob);
        assertLe(wx, 1e9);
        assertLe(wy, 1e6);
    }

    // ------------------------------------------------------------------ price manipulation

    /// A deposit made while the price is pushed around is still an exact slice: once the price comes
    /// back, the first holder's claim is intact and the depositor only kept what fees they paid for.
    function test_depositAtManipulatedPrice_doesNotDilute() public {
        _deposit(alice, 100e18, 200_000e6);
        (uint256 ax0, uint256 ay0) = vault.previewWithdraw(vault.balanceOf(alice));

        // attacker pushes the price up 12 bins through the vault's X
        uint256 got = _swap(false, 100_000e6);
        assertGt(pair.getActiveId(), ACTIVE + 5);
        // bob deposits at the moved price
        _deposit(bob, 20e18, 40_000e6);
        // attacker sells everything back
        _swap(true, got);

        (uint256 ax1, uint256 ay1) = vault.previewWithdraw(vault.balanceOf(alice));
        // Alice is worth at least what she was (she earned the round trip's fees).
        assertGe(_value(ax1, ay1), _value(ax0, ay0));
    }

    // ------------------------------------------------------------------ withdrawals

    function test_withdraw_proRata_and_whilePaused() public {
        _deposit(alice, 10e18, 20_000e6);
        _deposit(bob, 10e18, 20_000e6);
        uint256 half = vault.balanceOf(alice) / 2;
        (uint256 ex, uint256 ey) = vault.previewWithdraw(half);

        vm.prank(owner);
        config.setPaused(true);

        vm.prank(alice);
        (uint256 wx, uint256 wy) = vault.withdraw(half, alice, ex, ey, block.timestamp);
        assertEq(wx, ex);
        assertEq(wy, ey);
        assertApproxEqRel(wx, 5e18, 1e12);
        assertApproxEqRel(wy, 10_000e6, 1e12);

        vm.startPrank(alice);
        uint256 rest = vault.balanceOf(alice);
        vm.expectRevert();
        vault.withdraw(rest, alice, 6e18, 0, block.timestamp);
        vm.expectRevert(DlmmVault.DlmmVault__Expired.selector);
        vault.withdraw(rest, alice, 0, 0, block.timestamp - 1);
        vm.expectRevert();
        vault.withdraw(rest + 1, alice, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_feesAccrueToHolders() public {
        _deposit(alice, 50e18, 100_000e6);
        uint256 v0;
        {
            (uint256 x, uint256 y) = vault.getTotalAmounts();
            v0 = _value(x, y);
        }
        // many round trips inside the range
        for (uint256 i; i < 10; ++i) {
            uint256 got = _swap(false, 20_000e6);
            _swap(true, got);
        }
        (uint256 x1, uint256 y1) = vault.getTotalAmounts();
        assertGt(_value(x1, y1), v0);
        (uint256 wx, uint256 wy) = _withdrawAll(alice);
        assertGt(_value(wx, wy), v0 * 999 / 1000);
    }

    // ------------------------------------------------------------------ rebalance

    function test_rebalance_followsPrice_withoutSwapping() public {
        _deposit(alice, 50e18, 100_000e6);
        uint24 a0 = pair.getActiveId();

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DlmmVault.DlmmVault__NotNeeded.selector, a0));
        vault.rebalance(a0, 0);

        // push the price up 15 bins: more than halfWidth / 2 = 10 from the centre
        _swap(false, 80_000e6);
        uint24 a1 = pair.getActiveId();
        assertGt(a1, a0 + H / 2);
        assertTrue(vault.needsRebalance());

        vm.prank(alice);
        vm.expectRevert(DlmmVault.DlmmVault__NotKeeper.selector);
        vault.rebalance(a1, 0);

        (uint256 tx0, uint256 ty0) = vault.getTotalAmounts();
        _rebalance();
        assertEq(vault.lowerId(), a1 - H);
        assertEq(vault.upperId(), a1 + H);
        assertEq(vault.rebalanceCount(), 1);
        assertFalse(vault.needsRebalance());

        // No swap: the vault still owns the same tokens (the active bin's composition fee aside).
        (uint256 tx1, uint256 ty1) = vault.getTotalAmounts();
        assertApproxEqRel(tx1, tx0, 1e12);
        assertApproxEqRel(ty1, ty0, 1e12);
        assertLe(tx1, tx0);
        assertLe(ty1, ty0);
        // and it is laid out around the new active bin: X above, Y below
        (uint24 lower, uint256[] memory bx, uint256[] memory by) = vault.getBins();
        assertEq(lower, a1 - H);
        assertGt(bx[2 * H], 0);
        assertGt(by[0], 0);

        // cooldown
        _swap(true, 60e18);
        uint24 a2 = pair.getActiveId();
        assertTrue(vault.needsRebalance());
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DlmmVault.DlmmVault__TooSoon.selector, block.timestamp + 5 minutes));
        vault.rebalance(a2, 0);
        vm.warp(block.timestamp + 5 minutes);
        // owner may rebalance too
        vm.prank(owner);
        vault.rebalance(a2, 0);
        assertEq(vault.lowerId(), a2 - H);
    }

    function test_rebalance_guards() public {
        _deposit(alice, 50e18, 100_000e6);
        _swap(false, 80_000e6);
        vm.warp(block.timestamp + 10 minutes);
        uint24 a = pair.getActiveId();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DlmmVault.DlmmVault__ActiveIdSlippage.selector, a));
        vault.rebalance(a - 3, 2);

        vm.prank(owner);
        config.setPaused(true);
        vm.prank(keeper);
        vm.expectRevert(DlmmVault.DlmmVault__Paused.selector);
        vault.rebalance(a, 0);
    }

    /// Price walks out of the whole range: the vault holds only Y, and the rebalance lays that Y out
    /// just below the new price (a bid that follows the market) instead of selling it.
    function test_rebalance_outOfRange_oneSided() public {
        _deposit(alice, 10e18, 20_000e6);
        // someone else's liquidity far above lets the price leave the vault's range
        vm.startPrank(bob);
        uint256[] memory ids = new uint256[](10);
        uint256[] memory dx = new uint256[](10);
        uint256[] memory dy = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            ids[i] = ACTIVE + H + 5 + i;
            dx[i] = 1e17;
        }
        tX.transfer(address(pair), 100e18);
        pair.mint(bob, ids, dx, dy);
        vm.stopPrank();

        _swap(false, 60_000e6);
        uint24 a = pair.getActiveId();
        assertGt(a, ACTIVE + H);
        (uint256 tx0, uint256 ty0) = vault.getTotalAmounts();
        assertLt(tx0, 1e12); // all X sold on the way up
        vm.warp(block.timestamp + 10 minutes);
        _rebalance();
        (uint24 lower, uint256[] memory bx, uint256[] memory by) = vault.getBins();
        assertEq(lower, a - H);
        for (uint256 i = H + 1; i <= 2 * H; ++i) assertEq(bx[i], 0);
        // the active bin holds bob's X, so the Y-only vault skips it instead of paying to swap in
        assertEq(by[H], 0);
        assertGt(by[H - 1], 0);
        (, uint256 ty1) = vault.getTotalAmounts();
        assertApproxEqRel(ty1, ty0, 1e12);
    }

    // ------------------------------------------------------------------ shapes

    function test_shapes() public {
        vm.startPrank(owner);
        DlmmVault curve = DlmmVault(factory.createVault(address(pair), 10, 1));
        DlmmVault bidask = DlmmVault(factory.createVault(address(pair), 10, 2));
        vm.stopPrank();
        uint24 a = pair.getActiveId();
        vm.startPrank(alice);
        tX.approve(address(curve), type(uint256).max);
        tY.approve(address(curve), type(uint256).max);
        tX.approve(address(bidask), type(uint256).max);
        tY.approve(address(bidask), type(uint256).max);
        curve.deposit(10e18, 20_000e6, 0, alice, a, 0, block.timestamp);
        bidask.deposit(10e18, 20_000e6, 0, alice, a, 0, block.timestamp);
        vm.stopPrank();

        (, uint256[] memory cx, uint256[] memory cy) = curve.getBins();
        (, uint256[] memory kx, uint256[] memory ky) = bidask.getBins();
        // curve: the bins next to the active bin hold the most, the edges the least
        assertGt(cx[11], cx[20]);
        assertGt(cy[9], cy[0]);
        assertApproxEqRel(cx[11] * 1, cx[20] * 10, 0.01e18); // weights 10 vs 1
        // bid-ask: the reverse
        assertGt(kx[20], kx[11]);
        assertGt(ky[0], ky[9]);
    }

    // ------------------------------------------------------------------ inflation guard

    function test_inflationAttack_bounded() public {
        // attacker opens the vault with a dust deposit, then donates to inflate the share price
        vm.prank(alice);
        uint24 a = pair.getActiveId();
        vm.prank(alice);
        vault.deposit(0, 2000, 0, alice, a, 0, block.timestamp);
        vm.prank(alice);
        tY.transfer(address(vault), 10_000e6);
        // the victim's minShares check turns a bad fill into a revert
        (uint256 expected,,) = vault.previewDeposit(0, 5_000e6);
        vm.prank(bob);
        vault.deposit(0, 5_000e6, expected, bob, a, 0, block.timestamp);
        (, uint256 wy) = _withdrawAll(bob);
        // the donation mostly went to the locked shares' holders, not the attacker: bob loses < 0.1 %
        assertGt(wy, 4_995e6);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_depositWithdraw_neverProfits(uint96 x, uint96 y, uint96 swapIn, bool dir) public {
        _deposit(alice, 30e18, 60_000e6);
        uint256 bx = bound(uint256(x), 1e12, 50e18);
        uint256 by = bound(uint256(y), 1e3, 100_000e6);
        uint256 si = bound(uint256(swapIn), 0, dir ? 10e18 : 20_000e6);
        if (si > (dir ? 1e15 : 1e6)) _swap(dir, si);
        uint256 x0 = tX.balanceOf(bob);
        uint256 y0 = tY.balanceOf(bob);
        uint24 a = pair.getActiveId();
        vm.prank(bob);
        try vault.deposit(bx, by, 0, bob, a, 0, block.timestamp) returns (uint256, uint256, uint256) {
            _withdrawAll(bob);
        } catch {
            return;
        }
        // an immediate round trip never returns more than was put in
        assertLe(tX.balanceOf(bob), x0);
        assertLe(tY.balanceOf(bob), y0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ProtocolConfig} from "../../src/core/ProtocolConfig.sol";
import {DlmmFactory} from "../../src/dlmm/DlmmFactory.sol";
import {DlmmPair} from "../../src/dlmm/DlmmPair.sol";
import {Router} from "../../src/periphery/Router.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";
import {DlmmVault} from "../../src/vaults/DlmmVault.sol";
import {DlmmVaultFactory} from "../../src/vaults/DlmmVaultFactory.sol";
import {DlmmVaultZap} from "../../src/vaults/DlmmVaultZap.sol";
import {BinMath} from "../../src/libraries/BinMath.sol";
import {DlmmMockERC20} from "../dlmm/DlmmMockERC20.sol";

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract DlmmVaultZapTest is Test {
    uint24 constant CENTER = 1 << 23;
    uint24 constant ACTIVE = CENTER - 20_040; // ~2000 USDG per WETH
    uint24 constant H = 20;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address lp = makeAddr("lp");

    ProtocolConfig config;
    DlmmFactory dlmm;
    DlmmVaultFactory factory;
    MockWETH weth;
    DlmmMockERC20 usdg;
    DlmmPair pair; // the vault's pair
    DlmmPair market; // a second WETH/USDG pair (bin step 25) the zap swaps through
    Router router;
    DlmmVault vault;
    DlmmVaultZap zap;

    function setUp() public {
        config = new ProtocolConfig(owner, makeAddr("collector"));
        dlmm = new DlmmFactory(config);
        factory = new DlmmVaultFactory(config, dlmm);
        weth = new MockWETH();
        usdg = new DlmmMockERC20("USDG", 6);
        pair = DlmmPair(dlmm.createPair(address(weth), address(usdg), 10, ACTIVE));
        // same price on a 25 bps grid: (1.0025)^n ~ (1.001)^-20040
        market = DlmmPair(dlmm.createPair(address(weth), address(usdg), 25, CENTER - 8022));
        router = new Router(IPoolManager(address(1)), address(weth));
        vm.startPrank(owner);
        factory.setKeeper(keeper);
        vault = DlmmVault(factory.createVault(address(pair), H, 0));
        vm.stopPrank();
        zap = new DlmmVaultZap(IRouter(address(router)), address(weth), factory);

        address[3] memory users = [alice, bob, lp];
        for (uint256 i; i < 3; ++i) {
            vm.deal(users[i], 1_000 ether);
            vm.prank(users[i]);
            weth.deposit{value: 500 ether}();
            usdg.mint(users[i], 10_000_000e6);
        }
        // deep liquidity in the market pair, and a first deposit that opens the vault
        _seedMarket();
        vm.startPrank(lp);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.deposit(50e18, 100_000e6, 0, lp, pair.getActiveId(), 0, block.timestamp);
        vm.stopPrank();
    }

    function _seedMarket() internal {
        uint256 n = 41;
        uint24 a = market.getActiveId();
        uint256[] memory ids = new uint256[](n);
        uint256[] memory dx = new uint256[](n);
        uint256[] memory dy = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = a - 20 + i;
            if (i >= 20) dx[i] = uint256(1e18) / 21;
            if (i <= 20) dy[i] = uint256(1e18) / 21;
        }
        vm.startPrank(lp);
        weth.transfer(address(market), 200e18);
        usdg.transfer(address(market), 400_000e6);
        market.mint(lp, ids, dx, dy);
        vm.stopPrank();
    }

    function _hop(bool wethIn) internal view returns (IRouter.Hop[] memory hops) {
        hops = new IRouter.Hop[](1);
        hops[0] = IRouter.Hop({kind: 1, data: abi.encode(address(market), wethIn)});
    }

    /// The split the app computes: swap s of A so that (A - s) : out(s) matches the vault's mix.
    function _split(bool wethIn, uint256 amountIn) internal returns (uint256 s, uint256 out) {
        (uint256 tx_, uint256 ty) = vault.getTotalAmounts();
        (uint256 tT, uint256 tO) = wethIn ? (tx_, ty) : (ty, tx_);
        // First guess from the rate for all of amountIn, then once more from the rate at that size.
        uint256 q = router.quoteExactIn(_hop(wethIn), amountIn);
        s = amountIn * tO * amountIn / (tO * amountIn + tT * q);
        out = router.quoteExactIn(_hop(wethIn), s);
        s = amountIn * tO * s / (tO * s + tT * out);
        out = router.quoteExactIn(_hop(wethIn), s);
    }

    function _params(address tokenIn, uint256 amountIn, uint256 swapAmount, uint256 minSwapOut, uint256 minShares)
        internal
        view
        returns (DlmmVaultZap.ZapInParams memory p)
    {
        bool wethIn = tokenIn != address(usdg);
        p = DlmmVaultZap.ZapInParams({
            vault: address(vault),
            tokenIn: tokenIn,
            amountIn: amountIn,
            swapAmount: swapAmount,
            hops: _hop(wethIn),
            minSwapOut: minSwapOut,
            minShares: minShares,
            activeIdDesired: pair.getActiveId(),
            idSlippage: 2,
            to: alice,
            deadline: block.timestamp
        });
    }

    function _value(uint256 x, uint256 y) internal view returns (uint256) {
        return BinMath.getLiquidity(x, y, pair.getPriceFromId(pair.getActiveId()));
    }

    // ------------------------------------------------------------------ zap in

    function test_zapIn_usdgOnly() public {
        uint256 amountIn = 10_000e6;
        (uint256 s, uint256 out) = _split(false, amountIn);
        (uint256 exp,,) = vault.previewDeposit(out, amountIn - s);
        uint256 u0 = usdg.balanceOf(alice);
        DlmmVaultZap.ZapInParams memory p = _params(address(usdg), amountIn, s, out * 99 / 100, exp * 99 / 100);
        vm.startPrank(alice);
        usdg.approve(address(zap), amountIn);
        uint256 shares = zap.zapIn(p);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), shares);
        assertApproxEqRel(shares, exp, 0.001e18);
        // nearly everything went in: the refund is dust
        uint256 spent = u0 - usdg.balanceOf(alice);
        assertGt(spent, amountIn * 9995 / 10_000);
        assertLe(spent, amountIn);
        // the zap keeps nothing
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(weth.balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
        // the shares are worth what was paid, minus the swap fee (bin step 25: ~0.2 % on ~half)
        (uint256 wx, uint256 wy) = vault.previewWithdraw(shares);
        assertGt(_value(wx, wy), spent * 997 / 1000);
    }

    function test_zapIn_nativeEth_refundsInEth() public {
        uint256 amountIn = 5 ether;
        (uint256 s, uint256 out) = _split(true, amountIn);
        (uint256 exp,,) = vault.previewDeposit(amountIn - s, out);
        uint256 e0 = alice.balance;
        uint256 w0 = weth.balanceOf(alice);
        DlmmVaultZap.ZapInParams memory p = _params(address(0), amountIn, s, out * 99 / 100, exp * 99 / 100);
        vm.prank(alice);
        uint256 shares = zap.zapIn{value: amountIn}(p);
        assertApproxEqRel(shares, exp, 0.001e18);
        assertEq(vault.balanceOf(alice), shares);
        // WETH untouched, any unused ETH came back as ETH
        assertEq(weth.balanceOf(alice), w0);
        assertGt(e0 - alice.balance, amountIn * 999 / 1000);
        assertEq(address(zap).balance, 0);
        assertEq(weth.balanceOf(address(zap)), 0);
    }

    function test_zapIn_guards() public {
        uint256 amountIn = 1_000e6;
        (uint256 s, uint256 out) = _split(false, amountIn);
        vm.startPrank(alice);
        usdg.approve(address(zap), type(uint256).max);

        DlmmVaultZap.ZapInParams memory p = _params(address(usdg), amountIn, s, out * 2, 0);
        vm.expectRevert();
        zap.zapIn(p); // minSwapOut above the quote

        p = _params(address(usdg), amountIn, s, 0, type(uint256).max);
        vm.expectRevert();
        zap.zapIn(p); // minShares

        p = _params(address(usdg), amountIn, amountIn + 1, 0, 0);
        vm.expectRevert(DlmmVaultZap.DlmmVaultZap__BadSplit.selector);
        zap.zapIn(p);

        p = _params(address(usdg), amountIn, s, 0, 0);
        p.vault = address(pair);
        vm.expectRevert(DlmmVaultZap.DlmmVaultZap__UnknownVault.selector);
        zap.zapIn(p);

        p = _params(address(usdg), amountIn, s, 0, 0);
        p.hops = _hop(true); // route WETH -> USDG for a USDG input
        vm.expectRevert(DlmmVaultZap.DlmmVaultZap__BadRoute.selector);
        zap.zapIn(p);

        p = _params(address(0), 1 ether, 0, 0, 0);
        vm.expectRevert(DlmmVaultZap.DlmmVaultZap__ValueMismatch.selector);
        zap.zapIn{value: 2 ether}(p);

        p = _params(address(usdg), amountIn, s, 0, 0);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(DlmmVaultZap.DlmmVaultZap__Expired.selector);
        zap.zapIn(p);
        vm.stopPrank();

        DlmmMockERC20 other = new DlmmMockERC20("X", 18);
        p = _params(address(other), 1e18, 0, 0, 0);
        vm.expectRevert(DlmmVaultZap.DlmmVaultZap__BadToken.selector);
        zap.zapIn(p);
    }

    // ------------------------------------------------------------------ zap out

    function test_zapOut_toUsdg_and_toEth() public {
        // alice gets shares the normal way
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        (uint256 shares,,) = vault.deposit(10e18, 20_000e6, 0, alice, pair.getActiveId(), 0, block.timestamp);
        vault.approve(address(zap), type(uint256).max);
        vm.stopPrank();

        // half out as USDG
        uint256 half = shares / 2;
        (uint256 x, uint256 y) = vault.previewWithdraw(half);
        uint256 expUsdg = y + router.quoteExactIn(_hop(true), x);
        uint256 u0 = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 got = zap.zapOut(
            DlmmVaultZap.ZapOutParams({
                vault: address(vault),
                shares: half,
                tokenOut: address(usdg),
                hops: _hop(true),
                minOut: expUsdg * 99 / 100,
                to: alice,
                deadline: block.timestamp
            })
        );
        assertEq(usdg.balanceOf(alice) - u0, got);
        assertApproxEqRel(got, expUsdg, 0.001e18);

        // the rest out as native ETH
        uint256 rest = vault.balanceOf(alice);
        (x, y) = vault.previewWithdraw(rest);
        uint256 expEth = x + router.quoteExactIn(_hop(false), y);
        uint256 e0 = alice.balance;
        vm.prank(alice);
        got = zap.zapOut(
            DlmmVaultZap.ZapOutParams({
                vault: address(vault),
                shares: rest,
                tokenOut: address(0),
                hops: _hop(false),
                minOut: expEth * 99 / 100,
                to: alice,
                deadline: block.timestamp
            })
        );
        assertEq(alice.balance - e0, got);
        assertApproxEqRel(got, expEth, 0.001e18);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(weth.balanceOf(address(zap)), 0);
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(vault.balanceOf(address(zap)), 0);
    }

    function test_zapOut_minOut() public {
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        (uint256 shares,,) = vault.deposit(1e18, 2_000e6, 0, alice, pair.getActiveId(), 0, block.timestamp);
        vault.approve(address(zap), shares);
        DlmmVaultZap.ZapOutParams memory p = DlmmVaultZap.ZapOutParams({
            vault: address(vault),
            shares: shares,
            tokenOut: address(usdg),
            hops: _hop(true),
            minOut: 100_000e6,
            to: alice,
            deadline: block.timestamp
        });
        vm.expectRevert();
        zap.zapOut(p);
        vm.stopPrank();
    }

    /// A zap cannot take anyone else's shares or tokens: it only pulls from msg.sender.
    function test_zap_onlyPullsFromCaller() public {
        vm.startPrank(alice);
        usdg.approve(address(zap), type(uint256).max);
        vault.approve(address(zap), type(uint256).max);
        vm.stopPrank();
        // bob tries to spend alice's approvals: the zap pulls from bob, who approved nothing
        DlmmVaultZap.ZapInParams memory p = _params(address(usdg), 1_000e6, 0, 0, 0);
        vm.prank(bob);
        vm.expectRevert();
        zap.zapIn(p);
        DlmmVaultZap.ZapOutParams memory q = DlmmVaultZap.ZapOutParams({
            vault: address(vault),
            shares: vault.balanceOf(lp),
            tokenOut: address(usdg),
            hops: _hop(true),
            minOut: 0,
            to: bob,
            deadline: block.timestamp
        });
        vm.prank(bob);
        vm.expectRevert();
        zap.zapOut(q);
    }

    // ------------------------------------------------------------------ fuzz

    /// Any size, either token: the caller ends up with shares, the zap with nothing, and the refund is
    /// only what the vault's mix could not take.
    function testFuzz_zapIn_leavesNothing(uint96 amt, bool wethIn) public {
        uint256 amountIn = wethIn ? bound(uint256(amt), 1e15, 20e18) : bound(uint256(amt), 1e6, 40_000e6);
        (uint256 s, uint256 out) = _split(wethIn, amountIn);
        if (s == 0 || out == 0) return;
        address tokenIn = wethIn ? address(weth) : address(usdg);
        DlmmVaultZap.ZapInParams memory p = _params(tokenIn, amountIn, s, 0, 1);
        uint256 b0 = ERC20(tokenIn).balanceOf(alice);
        vm.startPrank(alice);
        ERC20(tokenIn).approve(address(zap), amountIn);
        uint256 shares = zap.zapIn(p);
        vm.stopPrank();
        assertGt(shares, 0);
        assertLe(b0 - ERC20(tokenIn).balanceOf(alice), amountIn);
        assertEq(weth.balanceOf(address(zap)), 0);
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
    }
}

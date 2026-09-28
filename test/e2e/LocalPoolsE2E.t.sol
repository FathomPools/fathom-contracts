// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {RobinhoodAddresses as RH} from "../../script/RobinhoodAddresses.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";
import {StockHook} from "../../src/hooks/StockHook.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// End-to-end check of the seeded v4 pools of a real Deploy + Seed run on a mainnet fork, through
/// the real v4 PositionManager + Permit2 (same action encoding as web/src/lib/v4.ts) and our Router:
/// DAMM ETH/USDG and the STOCK NVDA/USDG pool. Skipped unless E2E_RPC_URL is set (see LocalDeployE2E).
contract LocalPoolsE2ETest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 constant SPACING = 60;
    uint8 constant MINT_POSITION = 0x02;
    uint8 constant BURN_POSITION = 0x03;
    uint8 constant SETTLE_PAIR = 0x0d;
    uint8 constant TAKE_PAIR = 0x11;
    uint8 constant SWEEP = 0x14;

    IPoolManager pm = IPoolManager(RH.POOL_MANAGER);
    IPositionManager posm = IPositionManager(RH.POSITION_MANAGER);
    IAllowanceTransfer permit2 = IAllowanceTransfer(RH.PERMIT2);
    IRouter router;
    address damm;
    StockHook stock;

    address lp = makeAddr("e2e-v4-lp");
    address trader = makeAddr("e2e-v4-trader");

    function setUp() public {
        string memory rpc = vm.envOr("E2E_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        string memory json = vm.readFile("deployments/local.json");
        router = IRouter(vm.parseJsonAddress(json, ".router"));
        damm = vm.parseJsonAddress(json, ".dammHook");
        stock = StockHook(vm.parseJsonAddress(json, ".stockHook"));
        vm.deal(lp, 100 ether);
        vm.deal(trader, 10 ether);
    }

    // ---------------------------------------------------------------- helpers

    function _key(address a, address b, address hook) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(hook));
    }

    function _price(PoolKey memory key) internal view returns (uint160 p, int24 tick) {
        (p, tick,,) = pm.getSlot0(key.toId());
    }

    function _permit(address token, address owner_) internal {
        vm.startPrank(owner_);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(posm), type(uint160).max, uint48(block.timestamp + 1 days));
        vm.stopPrank();
    }

    /// MINT_POSITION + SETTLE_PAIR (+ SWEEP of leftover native ETH), as the web app encodes it.
    function _mint(PoolKey memory key, int24 lower, int24 upper, uint256 max0, uint256 max1)
        internal
        returns (uint256 tokenId, uint128 liquidity)
    {
        (uint160 p,) = _price(key);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            p, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), max0 * 99 / 100, max1 * 99 / 100
        );
        bool native = key.currency0.isAddressZero();
        bytes memory actions = native
            ? abi.encodePacked(MINT_POSITION, SETTLE_PAIR, SWEEP)
            : abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory params = new bytes[](native ? 3 : 2);
        params[0] = abi.encode(key, lower, upper, uint256(liquidity), uint128(max0), uint128(max1), lp, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        if (native) params[2] = abi.encode(key.currency0, lp);

        tokenId = posm.nextTokenId();
        vm.prank(lp);
        posm.modifyLiquidities{value: native ? max0 : 0}(abi.encode(actions, params), block.timestamp + 60);
        assertEq(posm.getPositionLiquidity(tokenId), liquidity);
    }

    /// BURN_POSITION with slippage mins + TAKE_PAIR to the LP.
    function _burn(PoolKey memory key, uint256 tokenId, uint256 min0, uint256 min1) internal {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(min0), uint128(min1), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, lp);
        vm.prank(lp);
        posm.modifyLiquidities(abi.encode(abi.encodePacked(BURN_POSITION, TAKE_PAIR), params), block.timestamp + 60);
    }

    function _hop(PoolKey memory key, bool zeroForOne) internal pure returns (IRouter.Hop[] memory hops) {
        hops = new IRouter.Hop[](1);
        hops[0] = IRouter.Hop({kind: 0, data: abi.encode(key, zeroForOne, bytes(""))});
    }

    function _ethUsd8() internal view returns (uint256) {
        (, int256 a,,,) = IAggregatorV3(RH.ETH_USD).latestRoundData();
        return uint256(a);
    }

    // ---------------------------------------------------------------- DAMM ETH/USDG

    function test_e2e_dammEthUsdg() public {
        PoolKey memory key = _key(address(0), RH.USDG, damm);
        (, int24 tick) = _price(key);
        int24 lower = (tick / SPACING - 100) * SPACING;
        int24 upper = (tick / SPACING + 100) * SPACING;

        deal(RH.USDG, lp, 100_000e6);
        _permit(RH.USDG, lp);
        uint256 usdg0 = IERC20(RH.USDG).balanceOf(lp);
        (uint256 tokenId,) = _mint(key, lower, upper, 10 ether, 40_000e6);
        assertGt(usdg0 - IERC20(RH.USDG).balanceOf(lp), 0, "no USDG deposited");

        // ETH -> USDG through the Router at roughly the Chainlink price (seeded from it).
        uint256 before = IERC20(RH.USDG).balanceOf(trader);
        vm.prank(trader);
        uint256 out = router.swapExactIn{value: 0.1 ether}(_hop(key, true), 0.1 ether, 1, trader, block.timestamp + 60);
        assertEq(IERC20(RH.USDG).balanceOf(trader) - before, out);
        uint256 fair = _ethUsd8() * 0.1 ether / 1e20; // USDG raw for 0.1 ETH
        assertApproxEqRel(out, fair, 0.03e18, "DAMM price far from Chainlink");

        vm.prank(trader);
        vm.expectRevert(IRouter.TooLittleReceived.selector);
        router.swapExactIn{value: 0.1 ether}(_hop(key, true), 0.1 ether, fair * 2, trader, block.timestamp + 60);

        // USDG -> ETH back.
        vm.startPrank(trader);
        IERC20(RH.USDG).approve(address(router), out);
        uint256 ethBack = router.swapExactIn(_hop(key, false), out, 1, trader, block.timestamp + 60);
        vm.stopPrank();
        assertGt(ethBack, 0.09 ether);

        // Guarded withdrawal: mins far above what the position holds must revert; sane ones pass.
        vm.expectRevert();
        _burn(key, tokenId, 1_000 ether, 0);
        uint256 e0 = lp.balance;
        uint256 u0 = IERC20(RH.USDG).balanceOf(lp);
        _burn(key, tokenId, 1, 1);
        assertGt(lp.balance - e0, 0);
        assertGt(IERC20(RH.USDG).balanceOf(lp) - u0, 0);
    }

    // ---------------------------------------------------------------- STOCK NVDA/USDG

    function test_e2e_stockNvdaUsdg() public {
        RH.StockQuote[] memory s = RH.stocks();
        address nvda = s[0].token;
        assertEq(keccak256(bytes(s[0].symbol)), keccak256("NVDA"));
        PoolKey memory key = _key(nvda, RH.USDG, address(stock));
        PoolId id = key.toId();
        (uint160 oracleSqrt,,,, bool open, bool stale) = stock.oracleState(id);
        emit log_named_string("NVDA market", stale ? "stale oracle" : open ? "open" : "closed");

        (uint160 p, int24 tick) = _price(key);
        assertApproxEqRel(uint256(p), uint256(oracleSqrt), 0.01e18, "pool not seeded at the oracle price");
        int24 lower = (tick / SPACING - 50) * SPACING;
        int24 upper = (tick / SPACING + 50) * SPACING;

        deal(nvda, lp, 1_000e18);
        deal(RH.USDG, lp, 500_000e6);
        _permit(nvda, lp);
        _permit(RH.USDG, lp);
        (bool nvdaIs0) = key.currency0 == Currency.wrap(nvda);
        (uint256 max0, uint256 max1) = nvdaIs0 ? (uint256(500e18), uint256(250_000e6)) : (uint256(250_000e6), uint256(500e18));
        (uint256 tokenId,) = _mint(key, lower, upper, max0, max1);

        // Small USDG -> NVDA buy through the Router stays inside the oracle band.
        deal(RH.USDG, trader, 10_000e6);
        vm.startPrank(trader);
        IERC20(RH.USDG).approve(address(router), type(uint256).max);
        bool zeroForOne = !nvdaIs0; // USDG in
        if (stale) {
            // Stale oracle: only swaps that move the pool toward the oracle are allowed.
            vm.expectRevert();
            router.swapExactIn(_hop(key, zeroForOne), 100e6, 1, trader, block.timestamp + 60);
        } else {
            uint256 got = router.swapExactIn(_hop(key, zeroForOne), 100e6, 1, trader, block.timestamp + 60);
            assertGt(got, 0);
            assertEq(IERC20(nvda).balanceOf(trader), got);
            // A buy big enough to leave the band reverts in the hook.
            vm.expectRevert();
            router.swapExactIn(_hop(key, zeroForOne), 9_000e6, 1, trader, block.timestamp + 60);
        }
        vm.stopPrank();

        _burn(key, tokenId, 1, 1);
        assertEq(posm.getPositionLiquidity(tokenId), 0);
    }
}

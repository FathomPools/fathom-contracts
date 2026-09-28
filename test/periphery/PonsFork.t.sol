// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Router} from "../../src/periphery/Router.sol";
import {Buyback} from "../../src/periphery/Buyback.sol";
import {PonsAdapter} from "../../src/periphery/PonsAdapter.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";
import {IPonsCurve, IPonsFactory} from "../../src/interfaces/IPonsCurve.sol";
import {RobinhoodAddresses as RH} from "../../script/RobinhoodAddresses.sol";

contract CurveOfHarness {
    function curveOf(address f, address t) external view returns (address) {
        return PonsAdapter.curveOf(f, t);
    }
}

/// Live Pons on Robinhood Chain 4663: curve buy/sell (pre-graduation) and the memeHook v4 pool
/// (post-graduation) through the Router, plus a Buyback on the memeHook pool.
contract PonsForkTest is Test {
    string constant RPC = "https://rpc.mainnet.chain.robinhood.com";
    uint256 constant FORK_BLOCK = 71_377_700;
    address constant GRADUATED = 0x1da81Ca017949efbe07972776580D04592Ba9b63;
    address constant LIVE_TOKEN = 0x1c8A97736ef55D5077BF0258dD525260F518871b; // on-curve at FORK_BLOCK

    Router router;
    address user = makeAddr("ponsUser");

    function setUp() public {
        // PONS_FORK_RPC (e.g. an archive endpoint) overrides the public RPC, which can drop old-state reads.
        try vm.createSelectFork(vm.envOr("PONS_FORK_RPC", string(RPC)), FORK_BLOCK) returns (uint256) {}
        catch {
            vm.skip(true);
        }
        router = new Router(IPoolManager(RH.POOL_MANAGER), RH.WETH);
        vm.deal(user, 10 ether);
    }

    receive() external payable {}

    function _one(IRouter.Hop memory h) internal pure returns (IRouter.Hop[] memory hops) {
        hops = new IRouter.Hop[](1);
        hops[0] = h;
    }

    function _memeKey(address token) internal view returns (PoolKey memory) {
        address hook = IPonsFactory(RH.PONS_FACTORY).memeHook();
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 200, IHooks(hook));
    }

    function test_curve_buy_sell_matchesQuote() public {
        address curve = new CurveOfHarness().curveOf(RH.PONS_FACTORY, LIVE_TOKEN);
        assertTrue(curve != address(0));
        assertFalse(IPonsCurve(curve).graduated());

        IRouter.Hop[] memory buy = _one(IRouter.Hop(2, abi.encode(curve, true)));
        uint256 q = router.quoteExactIn(buy, 0.01 ether);
        vm.prank(user);
        uint256 got = router.swapExactIn{value: 0.01 ether}(buy, 0.01 ether, q, user, block.timestamp);
        assertEq(got, q, "buy quote exact");
        assertEq(IERC20(LIVE_TOKEN).balanceOf(user), got);

        IRouter.Hop[] memory sell = _one(IRouter.Hop(2, abi.encode(curve, false)));
        uint256 qs = router.quoteExactIn(sell, got);
        vm.startPrank(user);
        IERC20(LIVE_TOKEN).approve(address(router), got);
        uint256 before = user.balance;
        uint256 eth = router.swapExactIn(sell, got, 0, user, block.timestamp);
        vm.stopPrank();
        assertEq(user.balance - before, eth);
        assertApproxEqRel(eth, qs, 0.001e18, "sell quote");
    }

    function test_graduated_curve_reverts_and_v4_hop_works() public {
        address curve = new CurveOfHarness().curveOf(RH.PONS_FACTORY, GRADUATED);
        assertTrue(IPonsCurve(curve).graduated());
        vm.prank(user);
        vm.expectRevert(IRouter.PonsGraduated.selector);
        router.swapExactIn{value: 0.01 ether}(
            _one(IRouter.Hop(2, abi.encode(curve, true))), 0.01 ether, 0, user, block.timestamp
        );

        IRouter.Hop[] memory hops = _one(IRouter.Hop(0, abi.encode(_memeKey(GRADUATED), true, bytes(""))));
        uint256 q = router.quoteExactIn(hops, 0.01 ether);
        vm.prank(user);
        uint256 got = router.swapExactIn{value: 0.01 ether}(hops, 0.01 ether, q, user, block.timestamp);
        assertEq(got, q);
        assertGt(got, 0);
        assertEq(IERC20(GRADUATED).balanceOf(user), got);
    }

    /// Two hops as the web app encodes them (web/src/lib/route.ts): a graduated token sold into its
    /// memeHook pool for native ETH, then that ETH spent on another token's live curve.
    function test_two_hops_v4_then_curve() public {
        // Build everything (external reads) before the prank so it applies to the swap itself.
        address curve = PonsAdapter.curveOf(RH.PONS_FACTORY, LIVE_TOKEN);
        IRouter.Hop[] memory buyGrad = _one(IRouter.Hop(0, abi.encode(_memeKey(GRADUATED), true, bytes(""))));
        vm.prank(user);
        uint256 grad = router.swapExactIn{value: 0.02 ether}(buyGrad, 0.02 ether, 1, user, block.timestamp);
        assertEq(IERC20(GRADUATED).balanceOf(user), grad);

        IRouter.Hop[] memory hops = new IRouter.Hop[](2);
        hops[0] = IRouter.Hop(0, abi.encode(_memeKey(GRADUATED), false, bytes(""))); // GRADUATED -> ETH
        hops[1] = IRouter.Hop(2, abi.encode(curve, true)); // ETH -> LIVE_TOKEN on the curve
        uint256 q = router.quoteExactIn(hops, grad);
        assertGt(q, 0);

        vm.startPrank(user);
        IERC20(GRADUATED).approve(address(router), grad);
        uint256 got = router.swapExactIn(hops, grad, q * 99 / 100, user, block.timestamp);
        vm.stopPrank();
        assertApproxEqRel(got, q, 0.001e18, "2-hop quote");
        assertEq(IERC20(LIVE_TOKEN).balanceOf(user), got);
        assertEq(IERC20(GRADUATED).balanceOf(user), 0);
    }

    function test_buyback_on_memeHook_pool() public {
        Buyback b = new Buyback(IPoolManager(RH.POOL_MANAGER), address(this), 0.05 ether);
        b.configure(_memeKey(GRADUATED), "");
        vm.deal(address(b), 0.2 ether);
        uint256 dead0 = IERC20(GRADUATED).balanceOf(b.DEAD());
        uint256 burned = b.buyback();
        assertGt(burned, 0);
        assertEq(IERC20(GRADUATED).balanceOf(b.DEAD()) - dead0, burned);
        assertEq(address(b).balance, 0.15 ether);
        assertEq(b.totalEthSpent(), 0.05 ether - 0.05 ether * 50 / 10_000);
    }
}

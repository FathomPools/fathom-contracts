// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PeripheryBase} from "./PeripheryBase.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";

contract RouterTest is PeripheryBase {
    function _one(IRouter.Hop memory h) internal pure returns (IRouter.Hop[] memory hops) {
        hops = new IRouter.Hop[](1);
        hops[0] = h;
    }

    function test_v4_nativeIn_erc20Out_matchesQuote() public {
        IRouter.Hop[] memory hops = _one(v4Hop(ethA, address(0)));
        uint256 q = router.quoteExactIn(hops, 1 ether);
        uint256 before = tokA.balanceOf(user);
        vm.expectEmit(true, true, false, true, address(router));
        emit IRouter.Swapped(user, user, address(0), address(tokA), 1 ether, q);
        vm.prank(user);
        uint256 out = router.swapExactIn{value: 1 ether}(hops, 1 ether, q, user, block.timestamp);
        assertEq(out, q);
        assertGt(out, 0.99 ether);
        assertEq(tokA.balanceOf(user) - before, out);
        assertEq(address(router).balance, 0);
    }

    function test_v4_erc20In_nativeOut() public {
        IRouter.Hop[] memory hops = _one(v4Hop(ethA, address(tokA)));
        uint256 before = user.balance;
        vm.prank(user);
        uint256 out = router.swapExactIn(hops, 1e18, 0.99 ether, user, block.timestamp);
        assertEq(user.balance - before, out);
    }

    function test_multihop_v4_v4() public {
        IRouter.Hop[] memory hops = new IRouter.Hop[](2);
        hops[0] = v4Hop(ethA, address(0));
        hops[1] = v4Hop(ab, address(tokA));
        uint256 q = router.quoteExactIn(hops, 2 ether);
        uint256 before = tokB.balanceOf(user);
        vm.prank(user);
        uint256 out = router.swapExactIn{value: 2 ether}(hops, 2 ether, q, user, block.timestamp);
        assertEq(out, q);
        assertEq(tokB.balanceOf(user) - before, out);
        assertEq(tokA.balanceOf(address(router)), 0);
    }

    /// A -> B (v4) -> WETH (DLMM) -> ETH (unwrap)
    function test_v4_dlmm_unwrap() public {
        IRouter.Hop[] memory hops = new IRouter.Hop[](3);
        hops[0] = v4Hop(ab, address(tokA));
        hops[1] = dlmmHop(address(dlmm), true);
        hops[2] = wethHop();
        (address tin, address tout) = router.routeTokens(hops);
        assertEq(tin, address(tokA));
        assertEq(tout, address(0));
        uint256 q = router.quoteExactIn(hops, 10e18);
        uint256 before = user.balance;
        vm.prank(user);
        uint256 out = router.swapExactIn(hops, 10e18, q, user, block.timestamp);
        assertEq(out, q);
        assertApproxEqRel(out, 5 ether, 0.02e18);
        assertEq(user.balance - before, out);
    }

    /// Native ETH in, DLMM pair wants WETH: auto-wrap.
    function test_dlmm_autoWrapNativeIn() public {
        IRouter.Hop[] memory hops = _one(dlmmHop(address(dlmm), false)); // WETH (Y) in, B out
        vm.prank(user);
        uint256 out = router.swapExactIn{value: 1 ether}(hops, 1 ether, 2e18, user, block.timestamp);
        assertEq(out, 2e18);
    }

    function test_guards() public {
        IRouter.Hop[] memory hops = _one(v4Hop(ethA, address(0)));
        vm.startPrank(user);
        vm.expectRevert(IRouter.Expired.selector);
        router.swapExactIn{value: 1 ether}(hops, 1 ether, 0, user, block.timestamp - 1);
        vm.expectRevert(IRouter.TooLittleReceived.selector);
        router.swapExactIn{value: 1 ether}(hops, 1 ether, 1 ether, user, block.timestamp);
        vm.expectRevert(IRouter.ValueMismatch.selector);
        router.swapExactIn{value: 0.5 ether}(hops, 1 ether, 0, user, block.timestamp);

        IRouter.Hop[] memory four = new IRouter.Hop[](4);
        four[0] = v4Hop(ethA, address(0));
        four[1] = v4Hop(ab, address(tokA));
        four[2] = v4Hop(ab, address(tokB));
        four[3] = v4Hop(ab, address(tokA));
        vm.expectRevert(IRouter.BadRoute.selector);
        router.swapExactIn{value: 1 ether}(four, 1 ether, 0, user, block.timestamp);

        IRouter.Hop[] memory broken = new IRouter.Hop[](2);
        broken[0] = v4Hop(ethA, address(0)); // -> A
        broken[1] = dlmmHop(address(dlmm), true); // wants B
        vm.expectRevert(IRouter.BadRoute.selector);
        router.swapExactIn{value: 1 ether}(broken, 1 ether, 0, user, block.timestamp);
        vm.stopPrank();
    }
}

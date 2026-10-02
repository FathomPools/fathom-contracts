// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DlmmFactory} from "../../src/dlmm/DlmmFactory.sol";
import {DlmmPair} from "../../src/dlmm/DlmmPair.sol";
import {DlmmLimitOrders} from "../../src/periphery/DlmmLimitOrders.sol";
import {BinMath} from "../../src/libraries/BinMath.sol";
import {RobinhoodAddresses as RH} from "../../script/RobinhoodAddresses.sol";

/// Robinhood Chain 4663 (latest block): a native-ETH sell order and a USDG buy order on the live
/// WETH/USDG pair (bin step 10), filled by real swaps, executed and claimed. The test adds its own
/// liquidity around the price first, so it does not depend on how deep the live pair is that day.
contract DlmmLimitOrdersForkTest is Test {
    string constant RPC = "https://rpc.mainnet.chain.robinhood.com";
    DlmmFactory constant DLMM = DlmmFactory(0x4B104E75B478B28492873e5Fb2BB0190166d296F);

    DlmmLimitOrders orders;
    DlmmPair pair;
    address maker = makeAddr("maker");
    address trader = makeAddr("trader");
    address lp = makeAddr("lp");

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(RPC));
        try this.fork(rpc) {}
        catch {
            vm.skip(true);
        }
        orders = new DlmmLimitOrders(DLMM, RH.WETH);
        pair = DlmmPair(DLMM.getPair(RH.WETH, RH.USDG, 10));
        require(pair.tokenX() == RH.WETH, "X is WETH");
        vm.deal(maker, 10 ether);
        vm.deal(trader, 10 ether);
        deal(RH.USDG, maker, 100_000e6);
        deal(RH.USDG, trader, 100_000e6);
        vm.prank(maker);
        IERC20(RH.USDG).approve(address(orders), type(uint256).max);
        _seed(20, 0.02 ether, 50e6);
    }

    /// `xPerBin` WETH in each of the `k` bins above the price, `yPerBin` USDG in each of the `k` below.
    function _seed(uint24 k, uint256 xPerBin, uint256 yPerBin) internal {
        uint24 active = pair.getActiveId();
        uint256 n = uint256(k) * 2;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory dx = new uint256[](n);
        uint256[] memory dy = new uint256[](n);
        for (uint256 i; i < k; ++i) {
            ids[i] = active - k + i;
            dy[i] = 1e18 / k;
            ids[k + i] = active + 1 + i;
            dx[k + i] = 1e18 / k;
        }
        vm.deal(lp, xPerBin * k);
        deal(RH.USDG, lp, yPerBin * k);
        vm.startPrank(lp);
        (bool ok,) = RH.WETH.call{value: xPerBin * k}(abi.encodeWithSignature("deposit()"));
        require(ok, "wrap");
        IERC20(RH.WETH).transfer(address(pair), xPerBin * k);
        IERC20(RH.USDG).transfer(address(pair), yPerBin * k);
        pair.mint(lp, ids, dx, dy);
        vm.stopPrank();
    }

    function fork(string memory rpc) external {
        vm.createSelectFork(rpc);
    }

    function _swapUsdgIn(uint256 amount) internal {
        vm.startPrank(trader);
        IERC20(RH.USDG).transfer(address(pair), amount);
        pair.swap(false, trader);
        vm.stopPrank();
    }

    function _swapWethIn(uint256 amount) internal {
        vm.startPrank(trader);
        (bool ok,) = RH.WETH.call{value: amount}(abi.encodeWithSignature("deposit()"));
        require(ok, "wrap");
        IERC20(RH.WETH).transfer(address(pair), amount);
        pair.swap(true, trader);
        vm.stopPrank();
    }

    function test_sellEthAbove_fillExecuteClaim() public {
        uint24 active = pair.getActiveId();
        uint24 id = active + 3;
        vm.prank(maker);
        orders.place{value: 0.002 ether}(address(pair), id, true, 0.002 ether, maker, block.timestamp);

        // push the price through the order bin with USDG, a bit at a time
        for (uint256 i; i < 40 && pair.getActiveId() <= id; ++i) {
            _swapUsdgIn(20e6);
        }
        assertGt(pair.getActiveId(), id, "price crossed the order bin");
        assertEq(orders.readyBooks().length, 1);

        address[] memory pairs = new address[](1);
        uint24[] memory ids = new uint24[](1);
        (pairs[0], ids[0]) = (address(pair), id);
        assertEq(orders.executeMany(pairs, ids), 1);

        uint256 u0 = IERC20(RH.USDG).balanceOf(maker);
        vm.prank(maker);
        (uint256 x, uint256 y) = orders.claim(address(pair), id, 0, maker, true);
        assertEq(x, 0);
        assertEq(IERC20(RH.USDG).balanceOf(maker) - u0, y);
        uint256 atPrice = BinMath.getLiquidity(0.002 ether, 0, pair.getPriceFromId(id));
        assertGe(y, atPrice, "sold at the limit price or better");
        emit log_named_uint("USDG received for 0.002 ETH", y);
    }

    function test_buyEthBelow_claimAsEth() public {
        uint24 active = pair.getActiveId();
        uint24 id = active - 3;
        vm.prank(maker);
        orders.place(address(pair), id, false, 5e6, maker, block.timestamp);

        for (uint256 i; i < 40 && pair.getActiveId() >= id; ++i) {
            _swapWethIn(0.01 ether);
        }
        assertLt(pair.getActiveId(), id, "price crossed the order bin");

        uint256 e0 = maker.balance;
        vm.prank(maker);
        (uint256 x, uint256 y) = orders.claim(address(pair), id, 0, maker, true); // executes, unwraps
        assertEq(y, 0);
        assertEq(maker.balance - e0, x);
        assertGe(BinMath.getLiquidity(x, 0, pair.getPriceFromId(id)), 5e6, "bought at the limit price or better");
        emit log_named_uint("ETH received for 5 USDG (wei)", x);
    }
}

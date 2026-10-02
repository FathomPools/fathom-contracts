// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProtocolConfig} from "../../src/core/ProtocolConfig.sol";
import {DlmmFactory} from "../../src/dlmm/DlmmFactory.sol";
import {DlmmPair} from "../../src/dlmm/DlmmPair.sol";
import {DlmmLimitOrders} from "../../src/periphery/DlmmLimitOrders.sol";
import {BinMath} from "../../src/libraries/BinMath.sol";
import {DlmmMockERC20} from "../dlmm/DlmmMockERC20.sol";

contract LimitOrdersWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth");
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DlmmLimitOrdersTest is Test {
    uint24 constant CENTER = 1 << 23;
    uint16 constant BIN_STEP = 10;
    uint24 constant ACTIVE = CENTER - 20_040; // ~2000 Y per X in raw units (18 / 6 decimals)
    uint256 constant SEED = 30; // background bins on each side

    address owner = makeAddr("owner");
    address collector = makeAddr("collector");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    address keeper = makeAddr("keeper");

    ProtocolConfig config;
    DlmmFactory dlmm;
    DlmmLimitOrders orders;
    LimitOrdersWETH tX; // WETH, 18 decimals
    DlmmMockERC20 tY; // USDG-like, 6 decimals
    DlmmPair pair;

    function setUp() public {
        config = new ProtocolConfig(owner, collector);
        dlmm = new DlmmFactory(config);
        tX = new LimitOrdersWETH();
        tY = new DlmmMockERC20("USDG", 6);
        pair = DlmmPair(dlmm.createPair(address(tX), address(tY), BIN_STEP, ACTIVE));
        orders = new DlmmLimitOrders(dlmm, address(tX));
        vm.deal(address(tX), 10_000 ether); // back the WETH minted below

        address[4] memory users = [alice, bob, lp, trader];
        for (uint256 i; i < 4; ++i) {
            tX.mint(users[i], 1_000e18);
            tY.mint(users[i], 10_000_000e6);
            vm.deal(users[i], 100 ether);
            vm.startPrank(users[i]);
            tX.approve(address(orders), type(uint256).max);
            tY.approve(address(orders), type(uint256).max);
            vm.stopPrank();
        }
        // Background liquidity: 1 X per bin above, 2000 Y per bin below, both in the active bin,
        // skipping `ACTIVE + 1`, `ACTIVE + 2`, `ACTIVE - 1` and `ACTIVE - 2` so tests can own them.
        _seed(ACTIVE - uint24(SEED), ACTIVE + uint24(SEED), 1e18, 2_000e6);
    }

    // ------------------------------------------------------------------ helpers

    function _seed(uint24 lo, uint24 hi, uint256 xPerBin, uint256 yPerBin) internal {
        uint256 n = uint256(hi - lo) + 1;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory dx = new uint256[](n);
        uint256[] memory dy = new uint256[](n);
        uint256 nx;
        uint256 ny;
        for (uint256 i; i < n; ++i) {
            uint24 id = lo + uint24(i);
            ids[i] = id;
            if (_reserved(id)) continue;
            if (id >= ACTIVE) ++nx;
            if (id <= ACTIVE) ++ny;
        }
        for (uint256 i; i < n; ++i) {
            uint24 id = uint24(ids[i]);
            if (_reserved(id)) continue;
            if (id >= ACTIVE) dx[i] = 1e18 / nx;
            if (id <= ACTIVE) dy[i] = 1e18 / ny;
        }
        vm.startPrank(lp);
        tX.transfer(address(pair), xPerBin * nx);
        tY.transfer(address(pair), yPerBin * ny);
        // a bin with nothing in it would mint zero shares and revert: leave the reserved ones out
        (uint256[] memory i2, uint256[] memory x2, uint256[] memory y2) = _compact(ids, dx, dy);
        pair.mint(lp, i2, x2, y2);
        vm.stopPrank();
    }

    function _reserved(uint24 id) internal pure returns (bool) {
        return id == ACTIVE + 1 || id == ACTIVE + 2 || id == ACTIVE - 1 || id == ACTIVE - 2;
    }

    function _compact(uint256[] memory ids, uint256[] memory dx, uint256[] memory dy)
        internal
        pure
        returns (uint256[] memory i2, uint256[] memory x2, uint256[] memory y2)
    {
        uint256 m;
        for (uint256 i; i < ids.length; ++i) {
            if (dx[i] != 0 || dy[i] != 0) ++m;
        }
        i2 = new uint256[](m);
        x2 = new uint256[](m);
        y2 = new uint256[](m);
        uint256 j;
        for (uint256 i; i < ids.length; ++i) {
            if (dx[i] == 0 && dy[i] == 0) continue;
            (i2[j], x2[j], y2[j]) = (ids[i], dx[i], dy[i]);
            ++j;
        }
    }

    function _place(address who, uint24 id, bool sellX, uint256 amount) internal returns (uint256 epoch, uint256 shares) {
        vm.prank(who);
        return orders.place(address(pair), id, sellX, amount, who, block.timestamp);
    }

    function _swap(bool swapForY, uint256 amountIn) internal returns (uint256 out) {
        vm.startPrank(trader);
        (swapForY ? ERC20(address(tX)) : ERC20(address(tY))).transfer(address(pair), amountIn);
        out = pair.swap(swapForY, trader);
        vm.stopPrank();
    }

    /// Y value of `x` at bin `id`'s price.
    function _atBin(uint256 x, uint24 id) internal view returns (uint256) {
        return BinMath.getLiquidity(x, 0, pair.getPriceFromId(id));
    }

    // ------------------------------------------------------------------ sell X (ask)

    function test_sellX_fillsAtBinPriceAndEarnsFees() public {
        uint24 id = ACTIVE + 2;
        (uint256 epoch,) = _place(alice, id, true, 1e18);
        assertEq(epoch, 0);
        assertEq(orders.openBooks().length, 1);
        assertEq(orders.readyBooks().length, 0);

        _swap(false, 20_000e6); // Y in: the price walks up through the order bin
        assertGt(pair.getActiveId(), id);
        assertEq(orders.readyBooks().length, 1);

        vm.prank(keeper);
        orders.execute(address(pair), id);
        assertEq(orders.openBooks().length, 0);
        assertEq(orders.currentEpoch(address(pair), id), 1);

        uint256 y0 = tY.balanceOf(alice);
        vm.prank(alice);
        (uint256 ax, uint256 ay) = orders.claim(address(pair), id, 0, alice, false);
        assertEq(ax, 0);
        assertEq(tY.balanceOf(alice) - y0, ay);
        uint256 atPrice = _atBin(1e18, id);
        assertGt(ay, atPrice, "fills at the bin price plus fees");
        assertLt(ay, atPrice * 1005 / 1000, "fees stay a fraction of a percent");
    }

    // ------------------------------------------------------------------ buy X (bid)

    function test_buyX_fillsBelow() public {
        uint24 id = ACTIVE - 2;
        uint256 yIn = 2_000e6;
        _place(bob, id, false, yIn);
        _swap(true, 10e18); // X in: the price walks down
        assertLt(pair.getActiveId(), id);

        uint256 x0 = tX.balanceOf(bob);
        vm.prank(bob);
        (uint256 bx, uint256 by) = orders.claim(address(pair), id, 0, bob, false); // claim executes it
        assertEq(by, 0);
        assertEq(tX.balanceOf(bob) - x0, bx);
        // bought X at the bin price: X value at that price is at least what was paid
        assertGe(_atBin(bx, id), yIn);
    }

    // ------------------------------------------------------------------ batching

    function test_twoOwners_shareProRata() public {
        uint24 id = ACTIVE + 2;
        (, uint256 sa) = _place(alice, id, true, 3e18);
        (, uint256 sb) = _place(bob, id, true, 1e18);
        assertApproxEqRel(sa, sb * 3, 1e12);

        _swap(false, 40_000e6);
        orders.execute(address(pair), id);
        DlmmLimitOrders.Batch memory b = orders.getBatch(address(pair), id, 0);
        assertTrue(b.executed);

        vm.prank(alice);
        (, uint256 ya) = orders.claim(address(pair), id, 0, alice, false);
        vm.prank(bob);
        (, uint256 yb) = orders.claim(address(pair), id, 0, bob, false);
        assertApproxEqRel(ya, yb * 3, 1e12);
        assertLe(ya + yb, b.amountY);
        assertLe(b.amountY - (ya + yb), 2, "only rounding dust stays");
    }

    function test_claimTwice_reverts() public {
        uint24 id = ACTIVE + 2;
        _place(alice, id, true, 1e18);
        _swap(false, 20_000e6);
        vm.startPrank(alice);
        orders.claim(address(pair), id, 0, alice, false);
        vm.expectRevert(DlmmLimitOrders.DlmmLimitOrders__NoOrder.selector);
        orders.claim(address(pair), id, 0, alice, false);
        vm.stopPrank();
    }

    function test_newEpochAfterExecution() public {
        uint24 id = ACTIVE + 2;
        _place(alice, id, true, 1e18);
        _swap(false, 20_000e6);
        orders.execute(address(pair), id);
        // price back down below the bin: a new sell order opens epoch 1
        _swap(true, 15e18);
        assertLt(pair.getActiveId(), id);
        (uint256 epoch,) = _place(bob, id, true, 1e18);
        assertEq(epoch, 1);

        vm.prank(alice);
        (uint256 ax, uint256 ay) = orders.claim(address(pair), id, 0, alice, false);
        assertEq(ax, 0);
        assertGt(ay, 0);
        // bob's order is untouched X
        (uint256 s, bool sellX, bool executed, bool filled, uint256 bx, uint256 by) =
            orders.orderInfo(address(pair), id, 1, bob);
        assertGt(s, 0);
        assertTrue(sellX);
        assertFalse(executed);
        assertFalse(filled);
        assertApproxEqAbs(bx, 1e18, 1);
        assertEq(by, 0);
    }

    function test_oppositeSidePlacement_settlesCrossedBatch() public {
        uint24 id = ACTIVE + 2;
        _place(alice, id, true, 1e18);
        _swap(false, 20_000e6); // filled, nobody executed
        assertGt(pair.getActiveId(), id);
        // the bin is now below the price: a buy order there settles alice's batch first
        (uint256 epoch,) = _place(bob, id, false, 1_000e6);
        assertEq(epoch, 1);
        assertTrue(orders.getBatch(address(pair), id, 0).executed);
        assertFalse(orders.getBatch(address(pair), id, 1).sellX);

        vm.prank(alice);
        (uint256 ax, uint256 ay) = orders.claim(address(pair), id, 0, alice, false);
        assertEq(ax, 0);
        assertGt(ay, _atBin(1e18, id));
    }

    // ------------------------------------------------------------------ cancel

    function test_cancelUnfilled_returnsDeposit() public {
        uint24 id = ACTIVE + 2;
        _place(alice, id, true, 1e18);
        uint256 x0 = tX.balanceOf(alice);
        vm.prank(alice);
        (uint256 cx, uint256 cy) = orders.cancel(address(pair), id, 0, alice, false);
        assertApproxEqAbs(cx, 1e18, 1);
        assertEq(cy, 0);
        assertEq(tX.balanceOf(alice) - x0, cx);
        assertEq(orders.openBooks().length, 0);
    }

    function test_cancelPartial_returnsMix() public {
        uint24 id = ACTIVE + 1; // nothing else between the active bin and the order
        _place(alice, id, true, 1e18);
        _swap(false, 3_000e6); // the active bin's X, then about half the order bin
        assertEq(pair.getActiveId(), id);
        (,,, bool filled, uint256 ix, uint256 iy) = orders.orderInfo(address(pair), id, 0, alice);
        assertFalse(filled);
        assertGt(ix, 0);
        assertGt(iy, 0);

        vm.prank(alice);
        (uint256 cx, uint256 cy) = orders.cancel(address(pair), id, 0, alice, false);
        assertEq(cx, ix);
        assertEq(cy, iy);
        vm.expectRevert(DlmmLimitOrders.DlmmLimitOrders__NotFilled.selector);
        orders.execute(address(pair), id);
    }

    function test_roundTripWithoutExecution_isBackToX() public {
        uint24 id = ACTIVE + 2;
        _place(alice, id, true, 1e18);
        _swap(false, 20_000e6);
        _swap(true, 15e18); // back down before anyone executed
        assertLt(pair.getActiveId(), id);
        vm.prank(alice);
        (uint256 cx, uint256 cy) = orders.cancel(address(pair), id, 0, alice, false);
        assertEq(cy, 0);
        assertGt(cx, 1e18, "round trip leaves the X plus both legs' fees");
    }

    function test_cancelAfterExecution_reverts() public {
        uint24 id = ACTIVE + 2;
        _place(alice, id, true, 1e18);
        _swap(false, 20_000e6);
        orders.execute(address(pair), id);
        vm.prank(alice);
        vm.expectRevert(DlmmLimitOrders.DlmmLimitOrders__AlreadyExecuted.selector);
        orders.cancel(address(pair), id, 0, alice, false);
    }

    // ------------------------------------------------------------------ guards

    function test_wrongSide_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(DlmmLimitOrders.DlmmLimitOrders__WrongSide.selector, ACTIVE));
        orders.place(address(pair), ACTIVE, true, 1e18, alice, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(DlmmLimitOrders.DlmmLimitOrders__WrongSide.selector, ACTIVE));
        orders.place(address(pair), ACTIVE - 2, true, 1e18, alice, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(DlmmLimitOrders.DlmmLimitOrders__WrongSide.selector, ACTIVE));
        orders.place(address(pair), ACTIVE + 2, false, 1_000e6, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_unknownPair_reverts() public {
        vm.prank(alice);
        vm.expectRevert(DlmmLimitOrders.DlmmLimitOrders__UnknownPair.selector);
        orders.place(address(tY), ACTIVE + 2, true, 1e18, alice, block.timestamp);
    }

    function test_expired_reverts() public {
        vm.prank(alice);
        vm.expectRevert(DlmmLimitOrders.DlmmLimitOrders__Expired.selector);
        orders.place(address(pair), ACTIVE + 2, true, 1e18, alice, block.timestamp - 1);
    }

    function test_unfilled_cannotExecuteOrClaim() public {
        uint24 id = ACTIVE + 2;
        _place(alice, id, true, 1e18);
        vm.expectRevert(DlmmLimitOrders.DlmmLimitOrders__NotFilled.selector);
        orders.execute(address(pair), id);
        vm.prank(alice);
        vm.expectRevert(DlmmLimitOrders.DlmmLimitOrders__NotFilled.selector);
        orders.claim(address(pair), id, 0, alice, false);
    }

    function test_paused_placeBlocked_exitsWork() public {
        uint24 id = ACTIVE + 2;
        _place(alice, id, true, 1e18);
        _place(bob, ACTIVE - 2, false, 1_000e6);
        _swap(false, 20_000e6);
        vm.prank(owner);
        config.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(DlmmPair.DlmmPair__Paused.selector);
        orders.place(address(pair), ACTIVE + 20, true, 1e18, alice, block.timestamp);

        vm.prank(alice);
        orders.claim(address(pair), id, 0, alice, false);
        vm.prank(bob);
        orders.cancel(address(pair), ACTIVE - 2, 0, bob, false);
    }

    // ------------------------------------------------------------------ native ETH

    function test_nativeEth_inAndOut() public {
        uint24 id = ACTIVE - 2; // buy WETH with Y, take it out as ETH
        _place(bob, id, false, 1_000e6);
        _swap(true, 10e18);

        uint256 e0 = bob.balance;
        vm.prank(bob);
        (uint256 bx,) = orders.claim(address(pair), id, 0, bob, true);
        assertGt(bx, 0);
        assertEq(bob.balance - e0, bx);

        // sell ETH above the price
        uint24 up = pair.getActiveId() + 3;
        vm.prank(alice);
        (, uint256 s) = orders.place{value: 0.5 ether}(address(pair), up, true, 0.5 ether, alice, block.timestamp);
        assertGt(s, 0);
        // the bin also holds other LPs' liquidity (and swap dust): its value comes back pro rata
        (,,,, uint256 ix, uint256 iy) = orders.orderInfo(address(pair), up, 0, alice);
        assertApproxEqRel(_atBin(ix, up) + iy, _atBin(0.5 ether, up), 1e9);
    }

    function test_nativeEth_wrongTokenOrValue_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(DlmmLimitOrders.DlmmLimitOrders__BadToken.selector);
        orders.place{value: 1 ether}(address(pair), ACTIVE - 2, false, 1 ether, alice, block.timestamp);
        vm.expectRevert(DlmmLimitOrders.DlmmLimitOrders__ValueMismatch.selector);
        orders.place{value: 1 ether}(address(pair), ACTIVE + 2, true, 2 ether, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_strayEthRejected() public {
        vm.prank(alice);
        (bool ok,) = address(orders).call{value: 1}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ keeper

    function test_executeMany_onlyFilled() public {
        _place(alice, ACTIVE + 2, true, 1e18);
        _place(alice, ACTIVE + 25, true, 1e18); // far away, stays open
        _place(bob, ACTIVE - 2, false, 1_000e6);
        _swap(false, 20_000e6);

        // the price went up: only the crossed ask is filled, the bid below still holds Y
        DlmmLimitOrders.Book[] memory ready = orders.readyBooks();
        assertEq(ready.length, 1);
        assertEq(ready[0].id, ACTIVE + 2);
        address[] memory pairs = new address[](3);
        uint24[] memory ids = new uint24[](3);
        (pairs[0], ids[0]) = (address(pair), ACTIVE + 2);
        (pairs[1], ids[1]) = (address(pair), ACTIVE + 25);
        (pairs[2], ids[2]) = (address(pair), ACTIVE - 2);
        vm.prank(keeper);
        uint256 done = orders.executeMany(pairs, ids);
        assertEq(done, 1);
        assertEq(orders.openBooks().length, 2);
        assertEq(orders.readyBooks().length, 0);
    }

    function test_ordersOf_listsEachOrderOnce() public {
        uint24 id = ACTIVE + 2;
        _place(alice, id, true, 1e18);
        _place(alice, id, true, 1e18);
        _place(alice, ACTIVE - 2, false, 1_000e6);
        DlmmLimitOrders.OrderRef[] memory list = orders.ordersOf(alice);
        assertEq(list.length, 2);
        assertEq(list[0].id, id);
        assertEq(list[1].id, ACTIVE - 2);
    }

    // ------------------------------------------------------------------ fuzz

    /// Any mix of order sizes in one bin: claims never exceed what the batch received, and every
    /// owner can always get out (claim after a fill, cancel otherwise).
    function testFuzz_claimsNeverExceedBatch(uint96 a, uint96 b, uint96 swapIn, bool sellSide) public {
        uint256 amtA = bound(a, 1e12, 5e18);
        uint256 amtB = bound(b, 1e12, 5e18);
        uint24 id = sellSide ? ACTIVE + 2 : ACTIVE - 2;
        if (!sellSide) {
            amtA = amtA / 1e9 + 1e6; // Y side, 6 decimals
            amtB = amtB / 1e9 + 1e6;
        }
        _place(alice, id, sellSide, amtA);
        _place(bob, id, sellSide, amtB);
        if (sellSide) _swap(false, bound(swapIn, 1e6, 40_000e6));
        else _swap(true, bound(swapIn, 1e12, 20e18));

        (,,, bool filled,,) = orders.orderInfo(address(pair), id, 0, alice);
        address[2] memory who = [alice, bob];
        uint256 outX;
        uint256 outY;
        for (uint256 i; i < 2; ++i) {
            vm.prank(who[i]);
            (uint256 x, uint256 y) = filled
                ? orders.claim(address(pair), id, 0, who[i], false)
                : orders.cancel(address(pair), id, 0, who[i], false);
            outX += x;
            outY += y;
        }
        // everyone is out: only rounding dust can stay behind
        assertLe(tX.balanceOf(address(orders)), 2);
        assertLe(tY.balanceOf(address(orders)), 2);
        if (filled) {
            DlmmLimitOrders.Batch memory bt = orders.getBatch(address(pair), id, 0);
            assertLe(outX, bt.amountX);
            assertLe(outY, bt.amountY);
        }
        assertEq(orders.openBooks().length, 0);
    }
}

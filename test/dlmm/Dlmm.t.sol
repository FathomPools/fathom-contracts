// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProtocolConfig} from "../../src/core/ProtocolConfig.sol";
import {DlmmFactory} from "../../src/dlmm/DlmmFactory.sol";
import {DlmmPair} from "../../src/dlmm/DlmmPair.sol";
import {DlmmPositionNFT} from "../../src/dlmm/DlmmPositionNFT.sol";
import {DlmmMockERC20} from "./DlmmMockERC20.sol";

contract DlmmTest is Test {
    uint24 constant CENTER = 1 << 23;
    uint16 constant BIN_STEP = 25;

    address owner = makeAddr("owner");
    address collector = makeAddr("collector");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    ProtocolConfig config;
    DlmmFactory factory;
    DlmmPositionNFT nft;
    DlmmMockERC20 tX;
    DlmmMockERC20 tY;
    DlmmPair pair;

    function setUp() public {
        config = new ProtocolConfig(owner, collector);
        factory = new DlmmFactory(config);
        nft = new DlmmPositionNFT(factory);
        tX = new DlmmMockERC20("X", 18);
        tY = new DlmmMockERC20("Y", 18);
        pair = DlmmPair(factory.createPair(address(tX), address(tY), BIN_STEP, CENTER));

        tX.mint(lp, 1e30);
        tY.mint(lp, 1e30);
        tX.mint(trader, 1e30);
        tY.mint(trader, 1e30);
        vm.startPrank(lp);
        tX.approve(address(nft), type(uint256).max);
        tY.approve(address(nft), type(uint256).max);
        vm.stopPrank();
    }

    // 11 bins [CENTER-5, CENTER+5]: Y spread over lower 6 bins, X over upper 6 bins.
    function _dist() internal pure returns (uint256[] memory ids, uint256[] memory dx, uint256[] memory dy) {
        ids = new uint256[](11);
        dx = new uint256[](11);
        dy = new uint256[](11);
        for (uint256 i; i < 11; ++i) {
            ids[i] = CENTER - 5 + i;
            if (i >= 5) dx[i] = uint256(1e18) / 6;
            if (i <= 5) dy[i] = uint256(1e18) / 6;
        }
    }

    function _addLiquidity(uint256 amount) internal returns (uint256[] memory ids, uint256[] memory shares) {
        uint256[] memory dx;
        uint256[] memory dy;
        (ids, dx, dy) = _dist();
        vm.startPrank(lp);
        tX.transfer(address(pair), amount);
        tY.transfer(address(pair), amount);
        (,, shares) = pair.mint(lp, ids, dx, dy);
        vm.stopPrank();
    }

    function _swap(bool swapForY, uint128 amountIn) internal returns (uint256 out) {
        vm.startPrank(trader);
        (swapForY ? tX : tY).transfer(address(pair), amountIn);
        out = pair.swap(swapForY, trader);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ factory

    function test_createPair() public {
        assertEq(factory.getPair(address(tX), address(tY), BIN_STEP), address(pair));
        assertEq(factory.getPair(address(tY), address(tX), BIN_STEP), address(pair));
        assertEq(factory.allPairsLength(), 1);
        assertTrue(factory.isPair(address(pair)));
        assertEq(pair.getActiveId(), CENTER);
        assertEq(pair.getPriceFromId(CENTER), 1 << 128);
        // (1.0025)^1 in 128.128
        assertApproxEqRel(pair.getPriceFromId(CENTER + 1), (uint256(1 << 128) * 10025) / 10000, 1e6);
        assertApproxEqRel(pair.getPriceFromId(CENTER - 400), uint256(1 << 128) * 3683 / 10000, 0.001e18);

        vm.expectRevert(DlmmFactory.DlmmFactory__PairExists.selector);
        factory.createPair(address(tY), address(tX), BIN_STEP, CENTER);
        vm.expectRevert(abi.encodeWithSelector(DlmmFactory.DlmmFactory__BinStepNotAllowed.selector, uint16(7)));
        factory.createPair(address(tX), address(tY), 7, CENTER);

        vm.prank(owner);
        config.setPaused(true);
        vm.expectRevert(DlmmFactory.DlmmFactory__Paused.selector);
        factory.createPair(address(tX), address(tY), 10, CENTER);
    }

    // ------------------------------------------------------------------ liquidity + swaps

    function test_mintAndBurn() public {
        (uint256[] memory ids, uint256[] memory shares) = _addLiquidity(1000e18);
        (uint128 rx, uint128 ry) = pair.getReserves();
        assertApproxEqAbs(rx, 1000e18, 1e6);
        assertApproxEqAbs(ry, 1000e18, 1e6);
        (uint128 bx, uint128 by) = pair.getBin(CENTER);
        assertGt(bx, 0);
        assertGt(by, 0);
        assertEq(pair.balanceOf(lp, CENTER + 3), shares[8]);
        assertEq(pair.totalSupply(CENTER + 3), shares[8]);

        uint256 bx0 = tX.balanceOf(lp);
        vm.prank(lp);
        (uint256 ax, uint256 ay) = pair.burn(lp, lp, ids, shares);
        assertEq(ax, rx);
        assertEq(ay, ry);
        assertEq(tX.balanceOf(lp) - bx0, ax);
        (rx, ry) = pair.getReserves();
        assertEq(rx + ry, 0);
    }

    function test_swapXForY_multiBin() public {
        _addLiquidity(1000e18);
        uint128 amountIn = 400e18;
        (uint128 left, uint128 quoteOut, uint128 fee) = pair.getSwapOut(amountIn, true);
        assertEq(left, 0);

        uint256 before = tY.balanceOf(trader);
        uint256 out = _swap(true, amountIn);
        assertEq(out, quoteOut);
        assertEq(tY.balanceOf(trader) - before, out);
        assertLt(pair.getActiveId(), CENTER - 1); // walked at least 2 bins down
        assertGt(out, 390e18);
        assertLt(out, 400e18);
        // protocol share (20 %) of the fee went to the collector in X
        assertApproxEqAbs(tX.balanceOf(collector), uint256(fee) * 2000 / 10_000, 10);
        assertGt(tX.balanceOf(collector), 0);
        // tracked reserves match balances
        (uint128 rx, uint128 ry) = pair.getReserves();
        assertEq(rx, tX.balanceOf(address(pair)));
        assertEq(ry, tY.balanceOf(address(pair)));
    }

    function test_swapYForX_multiBin() public {
        _addLiquidity(1000e18);
        uint128 amountIn = 400e18;
        (uint128 left, uint128 quoteOut, uint128 fee) = pair.getSwapOut(amountIn, false);
        assertEq(left, 0);

        uint256 out = _swap(false, amountIn);
        assertEq(out, quoteOut);
        assertGt(pair.getActiveId(), CENTER + 1);
        assertGt(out, 385e18);
        assertLt(out, 400e18);
        assertApproxEqAbs(tY.balanceOf(collector), uint256(fee) * 2000 / 10_000, 10);

        // swap back: quote still matches and volatility raised the fee rate
        (,, uint24 va,,) = pair.getVolatilityState();
        assertGt(va, 0);
        (, uint128 backQuote,) = pair.getSwapOut(100e18, true);
        assertEq(_swap(true, 100e18), backQuote);
    }

    function test_swapOutOfLiquidity() public {
        _addLiquidity(10e18);
        (uint128 left,,) = pair.getSwapOut(1000e18, true);
        assertGt(left, 0);
        vm.startPrank(trader);
        tX.transfer(address(pair), 1000e18);
        vm.expectRevert(DlmmPair.DlmmPair__OutOfLiquidity.selector);
        pair.swap(true, trader);
        vm.stopPrank();
    }

    function test_pauseBlocksSwapAndMintNotBurn() public {
        (uint256[] memory ids, uint256[] memory shares) = _addLiquidity(1000e18);
        vm.prank(owner);
        config.setPaused(true);

        vm.startPrank(trader);
        tX.transfer(address(pair), 1e18);
        vm.expectRevert(DlmmPair.DlmmPair__Paused.selector);
        pair.swap(true, trader);
        vm.stopPrank();

        (, uint256[] memory dx, uint256[] memory dy) = _dist();
        vm.expectRevert(DlmmPair.DlmmPair__Paused.selector);
        pair.mint(lp, ids, dx, dy);

        vm.prank(lp);
        (uint256 ax, uint256 ay) = pair.burn(lp, lp, ids, shares);
        assertGt(ax, 0);
        assertGt(ay, 0);
    }

    function test_burnRequiresApproval() public {
        (uint256[] memory ids, uint256[] memory shares) = _addLiquidity(100e18);
        vm.prank(trader);
        vm.expectRevert(DlmmPair.DlmmPair__NotApproved.selector);
        pair.burn(lp, trader, ids, shares);

        vm.prank(lp);
        pair.approveForAll(trader, true);
        vm.prank(trader);
        pair.burn(lp, trader, ids, shares);
        assertEq(pair.balanceOf(lp, CENTER), 0);
    }


    // ------------------------------------------------------------------ composition fee (active bin)

    function _activeOnly(uint256 xShare, uint256 yShare)
        internal
        pure
        returns (uint256[] memory ids, uint256[] memory dx, uint256[] memory dy)
    {
        ids = new uint256[](1);
        dx = new uint256[](1);
        dy = new uint256[](1);
        ids[0] = CENTER;
        dx[0] = xShare;
        dy[0] = yShare;
    }

    /// Single-sided X into the active bin then an immediate burn used to be a fee-free X->Y swap.
    function test_compositionFeeMakesActiveBinRoundTripNoCheaperThanSwap() public {
        _addLiquidity(1000e18);
        address atk = makeAddr("atk");
        tX.mint(atk, 10e18);
        (uint256[] memory ids, uint256[] memory dx, uint256[] memory dy) = _activeOnly(1e18, 0);

        vm.startPrank(atk);
        tX.transfer(address(pair), 10e18);
        (,, uint256[] memory shares) = pair.mint(atk, ids, dx, dy);
        (uint256 outX, uint256 outY) = pair.burn(atk, atk, ids, shares);
        vm.stopPrank();

        assertGt(outY, 0);
        (, uint128 viaSwap,) = pair.getSwapOut(uint128(10e18 - outX), true);
        assertLe(outY, viaSwap, "round trip beat a real swap");
        // Value in Y at the 1:1 center price went down by at least the swap fee on the swapped part.
        uint256 feeRate = pair.getFeeRate(0);
        assertLe(outX + outY, 10e18 - (10e18 - outX) * feeRate / 1e18);
    }

    function test_compositionFeeSendsProtocolShareAndLeavesRestInBin() public {
        _addLiquidity(1000e18);
        vm.prank(owner);
        config.setProtocolFeeShareBps(2000);
        (uint128 bx0,) = pair.getBin(CENTER);
        uint256 collector0 = tX.balanceOf(collector);

        (uint256[] memory ids, uint256[] memory dx, uint256[] memory dy) = _activeOnly(1e18, 0);
        vm.startPrank(lp);
        tX.transfer(address(pair), 10e18);
        vm.expectEmit(true, false, false, false, address(pair));
        emit DlmmPair.CompositionFees(lp, CENTER, 0, 0, 0, 0);
        (uint256 addedX,,) = pair.mint(lp, ids, dx, dy);
        vm.stopPrank();

        uint256 toCollector = tX.balanceOf(collector) - collector0;
        assertGt(toCollector, 0, "protocol share not paid");
        (uint128 bx1,) = pair.getBin(CENTER);
        assertEq(bx1 - bx0 + toCollector, addedX, "bin + collector != deposit");
        (uint128 rx,) = pair.getReserves();
        assertEq(tX.balanceOf(address(pair)), rx, "tracked reserves out of sync");
    }

    function test_noCompositionFeeWhenDepositMatchesBinComposition() public {
        _addLiquidity(1000e18);
        (uint128 bx, uint128 by) = pair.getBin(CENTER);
        // Same X:Y ratio as the active bin -> nothing is swapped, nothing is charged.
        uint256 x = uint256(bx) / 10;
        uint256 y = uint256(by) / 10;
        (uint256[] memory ids, uint256[] memory dx, uint256[] memory dy) = _activeOnly(1e18, 1e18);
        vm.startPrank(lp);
        tX.transfer(address(pair), x);
        tY.transfer(address(pair), y);
        vm.recordLogs();
        (,, uint256[] memory shares) = pair.mint(lp, ids, dx, dy);
        (uint256 ox, uint256 oy) = pair.burn(lp, lp, ids, shares);
        vm.stopPrank();
        assertApproxEqAbs(ox, x, 2);
        assertApproxEqAbs(oy, y, 2);
    }

    function test_noCompositionFeeOutsideActiveBin() public {
        _addLiquidity(1000e18);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory dx = new uint256[](1);
        uint256[] memory dy = new uint256[](1);
        ids[0] = CENTER + 2;
        dx[0] = 1e18;
        vm.startPrank(lp);
        tX.transfer(address(pair), 10e18);
        (,, uint256[] memory shares) = pair.mint(lp, ids, dx, dy);
        (uint256 ox, uint256 oy) = pair.burn(lp, lp, ids, shares);
        vm.stopPrank();
        assertApproxEqAbs(ox, 10e18, 2);
        assertEq(oy, 0);
    }


    function testFuzz_activeBinRoundTripNeverBeatsSwap(uint96 amtX, uint96 amtY, bool preSwap) public {
        _addLiquidity(1000e18);
        if (preSwap) _swap(true, 3e18); // non-trivial active-bin composition + volatility
        uint256 x = bound(uint256(amtX), 0, 50e18);
        uint256 y = bound(uint256(amtY), 0, 50e18);
        vm.assume(x + y > 1e9);
        uint24 active = pair.getActiveId();
        uint256[] memory ids = new uint256[](1);
        uint256[] memory dx = new uint256[](1);
        uint256[] memory dy = new uint256[](1);
        ids[0] = active;
        dx[0] = 1e18;
        dy[0] = 1e18;

        address atk = makeAddr("fuzz-atk");
        tX.mint(atk, x);
        tY.mint(atk, y);
        vm.startPrank(atk);
        if (x != 0) tX.transfer(address(pair), x);
        if (y != 0) tY.transfer(address(pair), y);
        try pair.mint(atk, ids, dx, dy) returns (uint256, uint256, uint256[] memory shares) {
            (uint256 ox, uint256 oy) = pair.burn(atk, atk, ids, shares);
            vm.stopPrank();
            // Whatever came back beyond the deposit of one token was bought with the other:
            // it must never be more than a real swap of the same input would give.
            if (oy > y) {
                (, uint128 q,) = pair.getSwapOut(uint128(x - ox), true);
                assertLe(oy - y, uint256(q) + 2);
            } else if (ox > x) {
                (, uint128 q,) = pair.getSwapOut(uint128(y - oy), false);
                assertLe(ox - x, uint256(q) + 2);
            }
        } catch {
            vm.stopPrank(); // zero-share dust deposits may revert; that is fine
        }
        (uint128 rx, uint128 ry) = pair.getReserves();
        assertEq(tX.balanceOf(address(pair)), rx);
        assertEq(tY.balanceOf(address(pair)), ry);
    }

    // ------------------------------------------------------------------ position NFT

    function test_nftRoundTripCapturesFees() public {
        (, uint256[] memory dx, uint256[] memory dy) = _dist();
        vm.prank(lp);
        (uint256 tokenId, uint256 addedX, uint256 addedY) =
            nft.mint(address(pair), CENTER - 5, CENTER + 5, 1000e18, 1000e18, dx, dy, lp, _guard(CENTER, 0));
        assertEq(nft.ownerOf(tokenId), lp);
        assertApproxEqAbs(addedX, 1000e18, 1e6);
        assertApproxEqAbs(addedY, 1000e18, 1e6);
        // leftover dust refunded to the lp, nothing stuck in the NFT contract
        assertEq(tX.balanceOf(address(nft)), 0);

        // round-trip swap generates fees for the position
        _swap(true, 300e18);
        _swap(false, 300e18);

        address recv = makeAddr("recv");
        vm.prank(lp);
        (uint256 hx, uint256 hy) = nft.decrease(tokenId, 5000, recv, 0, 0, block.timestamp);
        assertGt(hx, 0);
        assertGt(hy, 0);

        vm.prank(trader);
        vm.expectRevert();
        nft.decrease(tokenId, 5000, trader, 0, 0, block.timestamp);

        vm.prank(lp);
        (uint256 rx, uint256 ry) = nft.burn(tokenId, recv, 0, 0, block.timestamp);
        vm.expectRevert();
        nft.ownerOf(tokenId);

        // Value (at bin-0 price 1:1) grew by the LP share of the fees.
        assertGt(hx + hy + rx + ry, addedX + addedY);
        (uint128 px, uint128 py) = pair.getReserves();
        assertLe(px + py, 10); // only rounding dust left
    }

    function _guard(uint24 activeIdDesired, uint24 idSlippage) internal view returns (DlmmPositionNFT.DepositGuard memory) {
        return DlmmPositionNFT.DepositGuard({
            activeIdDesired: activeIdDesired,
            idSlippage: idSlippage,
            amountXMin: 0,
            amountYMin: 0,
            deadline: block.timestamp
        });
    }

    function _mintNft() internal returns (uint256 tokenId, uint256 addedX, uint256 addedY) {
        (, uint256[] memory dx, uint256[] memory dy) = _dist();
        vm.prank(lp);
        (tokenId, addedX, addedY) =
            nft.mint(address(pair), CENTER - 5, CENTER + 5, 1000e18, 1000e18, dx, dy, lp, _guard(CENTER, 0));
    }

    // ------------------------------------------------------------------ position NFT slippage guards

    function test_nftMintRevertsAfterDeadline() public {
        (, uint256[] memory dx, uint256[] memory dy) = _dist();
        DlmmPositionNFT.DepositGuard memory g = _guard(CENTER, 0);
        g.deadline = block.timestamp - 1;
        vm.prank(lp);
        vm.expectRevert(DlmmPositionNFT.DlmmPositionNFT__Expired.selector);
        nft.mint(address(pair), CENTER - 5, CENTER + 5, 1000e18, 1000e18, dx, dy, lp, g);
    }

    function test_nftMintRevertsWhenActiveBinMovedBeyondSlippage() public {
        _addLiquidity(1000e18);
        _swap(true, 400e18); // front-run: pushes the active bin down
        uint24 moved = pair.getActiveId();
        assertLt(moved, CENTER - 1);

        (, uint256[] memory dx, uint256[] memory dy) = _dist();
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(DlmmPositionNFT.DlmmPositionNFT__ActiveIdSlippage.selector, moved));
        nft.mint(address(pair), CENTER - 5, CENTER + 5, 1000e18, 1000e18, dx, dy, lp, _guard(CENTER, 1));
    }

    function test_nftMintAcceptsActiveBinWithinSlippage() public {
        (, uint256[] memory dx, uint256[] memory dy) = _dist();
        vm.prank(lp);
        (uint256 tokenId,,) =
            nft.mint(address(pair), CENTER - 5, CENTER + 5, 1000e18, 1000e18, dx, dy, lp, _guard(CENTER + 3, 3));
        assertEq(nft.ownerOf(tokenId), lp);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(DlmmPositionNFT.DlmmPositionNFT__ActiveIdSlippage.selector, CENTER));
        nft.mint(address(pair), CENTER - 5, CENTER + 5, 1000e18, 1000e18, dx, dy, lp, _guard(CENTER - 4, 3));
    }

    function test_nftMintRevertsBelowMinAmounts() public {
        (, uint256[] memory dx, uint256[] memory dy) = _dist();
        DlmmPositionNFT.DepositGuard memory g = _guard(CENTER, 0);
        g.amountXMin = 1000e18 + 1; // more than can possibly be added
        vm.prank(lp);
        vm.expectPartialRevert(DlmmPositionNFT.DlmmPositionNFT__AmountSlippage.selector);
        nft.mint(address(pair), CENTER - 5, CENTER + 5, 1000e18, 1000e18, dx, dy, lp, g);

        g.amountXMin = 999e18;
        g.amountYMin = 999e18;
        vm.prank(lp);
        (, uint256 ax, uint256 ay) = nft.mint(address(pair), CENTER - 5, CENTER + 5, 1000e18, 1000e18, dx, dy, lp, g);
        assertGe(ax, 999e18);
        assertGe(ay, 999e18);
    }

    function test_nftIncreaseEnforcesGuard() public {
        (uint256 tokenId,,) = _mintNft();
        (, uint256[] memory dx, uint256[] memory dy) = _dist();

        DlmmPositionNFT.DepositGuard memory g = _guard(CENTER, 0);
        g.deadline = block.timestamp - 1;
        vm.prank(lp);
        vm.expectRevert(DlmmPositionNFT.DlmmPositionNFT__Expired.selector);
        nft.increase(tokenId, 100e18, 100e18, dx, dy, g);

        g = _guard(CENTER + 5, 2);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(DlmmPositionNFT.DlmmPositionNFT__ActiveIdSlippage.selector, CENTER));
        nft.increase(tokenId, 100e18, 100e18, dx, dy, g);

        g = _guard(CENTER, 0);
        g.amountYMin = 100e18 + 1;
        vm.prank(lp);
        vm.expectPartialRevert(DlmmPositionNFT.DlmmPositionNFT__AmountSlippage.selector);
        nft.increase(tokenId, 100e18, 100e18, dx, dy, g);

        g.amountYMin = 99e18;
        vm.prank(lp);
        (uint256 ax, uint256 ay) = nft.increase(tokenId, 100e18, 100e18, dx, dy, g);
        assertApproxEqAbs(ax, 100e18, 1e6);
        assertApproxEqAbs(ay, 100e18, 1e6);
    }

    function test_nftDecreaseAndBurnEnforceMinsAndDeadline() public {
        (uint256 tokenId, uint256 addedX, uint256 addedY) = _mintNft();

        vm.prank(lp);
        vm.expectRevert(DlmmPositionNFT.DlmmPositionNFT__Expired.selector);
        nft.decrease(tokenId, 5000, lp, 0, 0, block.timestamp - 1);

        // Asking for more than half the deposit back from a 50% decrease must fail.
        vm.prank(lp);
        vm.expectPartialRevert(DlmmPositionNFT.DlmmPositionNFT__AmountSlippage.selector);
        nft.decrease(tokenId, 5000, lp, addedX / 2 + 1e18, 0, block.timestamp);

        vm.prank(lp);
        (uint256 hx, uint256 hy) = nft.decrease(tokenId, 5000, lp, addedX / 2 - 1e6, addedY / 2 - 1e6, block.timestamp);
        assertApproxEqAbs(hx, addedX / 2, 1e6);
        assertApproxEqAbs(hy, addedY / 2, 1e6);

        vm.prank(lp);
        vm.expectRevert(DlmmPositionNFT.DlmmPositionNFT__Expired.selector);
        nft.burn(tokenId, lp, 0, 0, block.timestamp - 1);

        vm.prank(lp);
        vm.expectPartialRevert(DlmmPositionNFT.DlmmPositionNFT__AmountSlippage.selector);
        nft.burn(tokenId, lp, 0, addedY, block.timestamp);

        vm.prank(lp);
        (uint256 rx, uint256 ry) = nft.burn(tokenId, lp, addedX / 2 - 1e6, addedY / 2 - 1e6, block.timestamp);
        assertApproxEqAbs(rx, addedX - hx, 1e6);
        assertApproxEqAbs(ry, addedY - hy, 1e6);
    }

    // Sandwich: attacker moves the price right before a withdrawal. Min amounts make it revert.
    function test_nftWithdrawalSandwichIsBlockedByMins() public {
        (uint256 tokenId, uint256 addedX, uint256 addedY) = _mintNft();
        _swap(true, 400e18); // attacker dumps X, drains Y from the LP's bins

        vm.prank(lp);
        vm.expectPartialRevert(DlmmPositionNFT.DlmmPositionNFT__AmountSlippage.selector);
        nft.burn(tokenId, lp, addedX * 99 / 100, addedY * 99 / 100, block.timestamp);
    }
}

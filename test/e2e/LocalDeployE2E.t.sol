// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RobinhoodAddresses as RH} from "../../script/RobinhoodAddresses.sol";
import {DlmmFactory} from "../../src/dlmm/DlmmFactory.sol";
import {DlmmPair} from "../../src/dlmm/DlmmPair.sol";
import {DlmmPositionNFT} from "../../src/dlmm/DlmmPositionNFT.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";

interface IWETH {
    function deposit() external payable;
}

/// End-to-end check of a real Deploy + Seed run (deployments/local.json) on a mainnet fork:
/// DLMM liquidity with slippage guards on the seeded WETH/USDG pair, a Router swap through it,
/// and a guarded withdrawal. Skipped unless E2E_RPC_URL points at the forked chain, e.g.
///   anvil --fork-url $ROBINHOOD_RPC_URL --chain-id 31337 --port 8547
///   forge script script/Deploy.s.sol ... && forge script script/Seed.s.sol ...
///   E2E_RPC_URL=http://127.0.0.1:8547 forge test --match-path test/e2e/LocalDeployE2E.t.sol
contract LocalDeployE2ETest is Test {
    uint16 constant BIN_STEP = 10;
    uint24 constant SPAN = 5;

    DlmmFactory factory;
    DlmmPositionNFT nft;
    IRouter router;
    DlmmPair pair;
    address lp = makeAddr("e2e-lp");
    address trader = makeAddr("e2e-trader");

    function setUp() public {
        string memory rpc = vm.envOr("E2E_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        string memory json = vm.readFile("deployments/local.json");
        factory = DlmmFactory(vm.parseJsonAddress(json, ".dlmmFactory"));
        nft = DlmmPositionNFT(vm.parseJsonAddress(json, ".dlmmPositionNft"));
        router = IRouter(vm.parseJsonAddress(json, ".router"));
        pair = DlmmPair(factory.getPair(RH.WETH, RH.USDG, BIN_STEP));
        assertTrue(address(pair) != address(0), "Seed did not create DLMM WETH/USDG");

        vm.deal(lp, 100 ether);
        vm.deal(trader, 10 ether);
        vm.prank(lp);
        IWETH(RH.WETH).deposit{value: 50 ether}();
        deal(RH.USDG, lp, 500_000e6);
        vm.startPrank(lp);
        IERC20(RH.WETH).approve(address(nft), type(uint256).max);
        IERC20(RH.USDG).approve(address(nft), type(uint256).max);
        vm.stopPrank();
    }

    function _plan(uint256 wethAmt, uint256 usdgAmt)
        internal
        view
        returns (uint24 lower, uint24 upper, uint256 ax, uint256 ay, uint256[] memory dx, uint256[] memory dy)
    {
        uint24 active = pair.getActiveId();
        bool wethIsX = pair.tokenX() == RH.WETH;
        (ax, ay) = wethIsX ? (wethAmt, usdgAmt) : (usdgAmt, wethAmt);
        lower = active - SPAN;
        upper = active + SPAN;
        uint256 n = upper - lower + 1;
        dx = new uint256[](n);
        dy = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint24 id = lower + uint24(i);
            if (id >= active) dx[i] = uint256(1e18) / (SPAN + 1);
            if (id <= active) dy[i] = uint256(1e18) / (SPAN + 1);
        }
    }

    function _guard(uint24 desired, uint24 slip, uint256 minX, uint256 minY)
        internal
        view
        returns (DlmmPositionNFT.DepositGuard memory)
    {
        return DlmmPositionNFT.DepositGuard(desired, slip, minX, minY, block.timestamp + 1200);
    }

    function test_e2e_dlmmLiquiditySwapWithdraw() public {
        uint24 active = pair.getActiveId();
        (uint24 lower, uint24 upper, uint256 ax, uint256 ay, uint256[] memory dx, uint256[] memory dy) =
            _plan(10 ether, 40_000e6);

        // Stale view of the active bin (front-run) -> guarded deposit reverts.
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(DlmmPositionNFT.DlmmPositionNFT__ActiveIdSlippage.selector, active));
        nft.mint(address(pair), lower, upper, ax, ay, dx, dy, lp, _guard(active + 10, 2, 0, 0));

        // Guarded deposit at the live bin with 0.5% mins.
        vm.prank(lp);
        (uint256 id, uint256 addedX, uint256 addedY) =
            nft.mint(address(pair), lower, upper, ax, ay, dx, dy, lp, _guard(active, 2, ax * 995 / 1000, ay * 995 / 1000));
        assertEq(nft.ownerOf(id), lp);
        assertGe(addedX, ax * 995 / 1000);
        assertGe(addedY, ay * 995 / 1000);

        // Router: 0.5 ETH -> USDG through the DLMM pair (ETH is wrapped automatically).
        bool swapForY = pair.tokenX() == RH.WETH;
        IRouter.Hop[] memory hops = new IRouter.Hop[](1);
        hops[0] = IRouter.Hop({kind: 1, data: abi.encode(address(pair), swapForY)});

        vm.prank(trader);
        vm.expectRevert(IRouter.TooLittleReceived.selector);
        router.swapExactIn{value: 0.5 ether}(hops, 0.5 ether, type(uint128).max, trader, block.timestamp + 60);

        vm.prank(trader);
        vm.expectRevert(IRouter.Expired.selector);
        router.swapExactIn{value: 0.5 ether}(hops, 0.5 ether, 0, trader, block.timestamp - 1);

        uint256 before = IERC20(RH.USDG).balanceOf(trader);
        vm.prank(trader);
        uint256 out = router.swapExactIn{value: 0.5 ether}(hops, 0.5 ether, 1, trader, block.timestamp + 60);
        assertEq(IERC20(RH.USDG).balanceOf(trader) - before, out);
        // Sanity vs the pair's seed price: 0.5 ETH is worth at least $500 of USDG on this pool.
        assertGt(out, 500e6);

        // Guarded withdrawal: simulate for exact amounts, then burn with 0.5% mins.
        uint256 snap = vm.snapshotState();
        vm.prank(lp);
        (uint256 ex, uint256 ey) = nft.burn(id, lp, 0, 0, block.timestamp + 60);
        vm.revertToState(snap);

        vm.prank(lp);
        vm.expectPartialRevert(DlmmPositionNFT.DlmmPositionNFT__AmountSlippage.selector);
        nft.burn(id, lp, ex + ex / 100, ey, block.timestamp + 60);

        vm.prank(lp);
        (uint256 rx, uint256 ry) = nft.burn(id, lp, ex * 995 / 1000, ey * 995 / 1000, block.timestamp + 60);
        assertEq(rx, ex);
        assertEq(ry, ey);
    }
}

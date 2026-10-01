// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";
import {DlmmFactory} from "../../src/dlmm/DlmmFactory.sol";
import {FeeCollector} from "../../src/periphery/FeeCollector.sol";
import {Buyback} from "../../src/periphery/Buyback.sol";
import {BuybackV2} from "../../src/periphery/BuybackV2.sol";
import {RobinhoodAddresses as RH} from "../../script/RobinhoodAddresses.sol";

/// Robinhood Chain 4663 (latest block, or FORK_BLOCK): replays the whole fee -> buyback path through
/// BuybackV2, the way DeployBuybackV2 wires it (the owner calls are repeated, so it also runs on a
/// block before the deployment). Written on 2026-10-01, when the v1 Buyback was stuck on a stale
/// reference ($FATHOM ~21% cheaper) and the FeeCollector held WETH fees with no route.
contract BuybackV2ForkTest is Test {
    string constant RPC = "https://rpc.mainnet.chain.robinhood.com";

    FeeCollector constant FC = FeeCollector(payable(0x51F34Ca37DD144a7709ee81c21AC7e850BC3A453));
    Buyback constant V1 = Buyback(payable(0x8b3d718843fd9167a52BDed64554131e39b4042F));
    DlmmFactory constant DLMM = DlmmFactory(0x4B104E75B478B28492873e5Fb2BB0190166d296F);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    BuybackV2 bb;
    address owner;
    address fathom;
    address tester = makeAddr("tester");

    function setUp() public {
        // FORK_RPC (e.g. an archive endpoint) overrides the public RPC, which can drop old-state reads.
        // The public RPC only serves recent state, so the default is the latest block.
        string memory rpc = vm.envOr("FORK_RPC", string(RPC));
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        try this.fork(rpc, forkBlock) {}
        catch {
            vm.skip(true);
        }
        owner = FC.owner();
        bb = new BuybackV2(V1.poolManager(), owner, 0.05 ether);
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks hooks) = V1.poolKey();
        fathom = Currency.unwrap(c1);
        bytes memory hookData = V1.hookData();
        vm.prank(owner);
        bb.configure(PoolKey(c0, c1, fee, spacing, hooks), hookData);
    }

    function fork(string memory rpc, uint256 forkBlock) external {
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
    }

    function test_feeWethThroughV2_burnsFathom() public {
        IRouter.Hop[] memory usdg = FC.route(RH.USDG).hops;
        IRouter.Hop[] memory hops = new IRouter.Hop[](usdg.length + 1);
        hops[0] = IRouter.Hop(1, abi.encode(DLMM.getPair(RH.WETH, RH.USDG, 10), true));
        for (uint256 i; i < usdg.length; ++i) {
            hops[i + 1] = usdg[i];
        }
        vm.startPrank(owner);
        FC.setBuyback(address(bb));
        FC.setRoute(RH.WETH, hops, 2 ether, true);
        vm.stopPrank();

        // Live fees, topped up when they are dust: USDG has 6 decimals, so a few hundred million wei of
        // WETH rounds below the oracle floor and convert() rightly refuses it.
        uint256 fees = IERC20(RH.WETH).balanceOf(address(FC));
        if (fees < 1e13) {
            deal(RH.WETH, address(FC), 1e13);
            fees = 1e13;
        }
        vm.prank(tester);
        uint256 ethOut = FC.convert(RH.WETH, 0);
        assertGt(ethOut, fees * 95 / 100);
        assertEq(address(bb).balance, ethOut);

        uint256 dead0 = IERC20(fathom).balanceOf(DEAD);
        vm.roll(block.number + 1);
        vm.prank(tester);
        uint256 burned = bb.buyback();
        assertGt(burned, 0);
        assertEq(IERC20(fathom).balanceOf(DEAD) - dead0, burned);
    }

    function test_anyoneBurnsATinyAmountOfTheirOwnEth() public {
        vm.deal(tester, 1 gwei);
        uint256 dead0 = IERC20(fathom).balanceOf(DEAD);
        vm.prank(tester);
        uint256 burned = bb.buyback{value: 1 gwei}();
        assertGt(burned, 0);
        assertEq(IERC20(fathom).balanceOf(DEAD) - dead0, burned);
    }
}

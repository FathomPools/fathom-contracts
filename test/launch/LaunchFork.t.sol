// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ProtocolConfig} from "../../src/core/ProtocolConfig.sol";
import {DammHook} from "../../src/hooks/DammHook.sol";
import {LaunchPools} from "../../src/launch/LaunchPools.sol";
import {LaunchVault} from "../../src/launch/LaunchVault.sol";
import {RobinhoodAddresses as RH} from "../../script/RobinhoodAddresses.sol";

/// Robinhood Chain 4663 (latest block): launches on the live PoolManager and DammHook, trades through
/// the anti-snipe window, collects the launch position's fees, and runs a vault launch end to end.
contract LaunchForkTest is Test {
    using StateLibrary for IPoolManager;

    string constant RPC = "https://rpc.mainnet.chain.robinhood.com";
    IPoolManager constant PM = IPoolManager(RH.POOL_MANAGER);
    DammHook constant HOOK = DammHook(0x13dEa09a13fDF2C32E6CFe0b5A50C4C47AA1a8cC);
    int24 constant START_TICK = 184_200; // 1e8 tokens per ETH

    LaunchPools lp;
    LaunchVault vault;
    PoolSwapTest router;
    address creator = makeAddr("creator");
    address sniper = makeAddr("sniper");
    address trader = makeAddr("trader");

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(RPC));
        try this.fork(rpc) {}
        catch {
            vm.skip(true);
        }
        require(address(HOOK.poolManager()) == address(PM), "live hook on the live PoolManager");
        lp = new LaunchPools(PM, HOOK);
        vault = new LaunchVault(lp);
        router = new PoolSwapTest(PM);
    }

    function fork(string memory rpc) external {
        vm.createSelectFork(rpc);
    }

    function _params() internal view returns (LaunchPools.LaunchParams memory) {
        return LaunchPools.LaunchParams({
            name: "Fork Launch",
            symbol: "FORK",
            supply: 1e27,
            seedAmount: 9e26,
            startTick: START_TICK,
            creator: creator,
            fees: DammHook.PoolParams({baseFeeBps: 100, snipeStartFeeBps: 5000, snipeSeconds: 600, variableFeeControl: 10_000})
        });
    }

    function _swap(address who, PoolKey memory key, bool buy, uint256 amountIn) internal returns (uint256 out) {
        vm.startPrank(who);
        if (buy) vm.deal(who, who.balance + amountIn);
        else IERC20(Currency.unwrap(key.currency1)).approve(address(router), amountIn);
        BalanceDelta d = router.swap{value: buy ? amountIn : 0}(
            key,
            SwapParams({
                zeroForOne: buy,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        out = buy ? uint128(d.amount1()) : uint128(d.amount0());
    }

    function test_fork_launchSnipeWindowAndFees() public {
        ProtocolConfig cfg = HOOK.config();
        if (cfg.paused()) vm.skip(true);
        address collector = cfg.feeCollector();
        uint256 share = cfg.protocolFeeShareBps();

        vm.prank(creator);
        (address token, PoolId id,) = lp.launch(_params());
        PoolKey memory key = lp.poolKeyOf(token);
        (, int24 tick,,) = PM.getSlot0(id);
        assertEq(tick, START_TICK);
        (,,,, uint40 createdAt,,,) = HOOK.pools(id);
        assertEq(createdAt, block.timestamp);
        (, uint24 total) = HOOK.currentFee(id);
        assertEq(total, 500_000, "anti-snipe start fee from the first block");

        // a sniper in the launch block pays the start fee: protocol share to the live collector,
        // the rest of it to the launch position
        uint256 c0 = collector.balance;
        uint256 got = _swap(sniper, key, true, 0.1 ether);
        assertGt(got, 0);
        uint256 proto = 0.1 ether * (500_000 * share / 10_000) / 1e6;
        assertEq(collector.balance - c0, proto);
        (uint256 f0,) = lp.pendingFees(id);
        assertApproxEqAbs(f0, (0.1 ether - proto) * (500_000 - 500_000 * share / 10_000) / 1e6, 2);

        // after the window: base fee, round trip, fees in both currencies to the creator
        vm.warp(vm.getBlockTimestamp() + 601);
        (, total) = HOOK.currentFee(id);
        assertLt(total, 500_000);
        uint256 more = _swap(trader, key, true, 0.05 ether);
        _swap(trader, key, false, more / 2);
        (uint256 p0, uint256 p1) = lp.pendingFees(id);
        assertGt(p0, f0);
        assertGt(p1, 0);
        uint256 e0 = creator.balance;
        uint256 t0 = IERC20(token).balanceOf(creator);
        vm.prank(trader);
        (uint256 a0, uint256 a1) = lp.collectFees(id);
        assertEq(a0, p0);
        assertEq(a1, p1);
        assertEq(creator.balance - e0, a0);
        assertEq(IERC20(token).balanceOf(creator) - t0, a1);
        (uint128 liq,,) = PM.getPositionInfo(id, address(lp), lp.TICK_LOWER(), START_TICK, bytes32(0));
        assertEq(liq, lp.getLaunch(id).liquidity, "launch liquidity stays locked");
        emit log_named_uint("sniper tokens for 0.1 ETH", got);
        emit log_named_uint("creator fees collected (wei ETH)", a0);
    }

    function test_fork_vaultLaunch() public {
        if (HOOK.config().paused()) vm.skip(true);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint40 end = uint40(vm.getBlockTimestamp() + 1 hours);
        vm.prank(creator);
        uint256 id = vault.open(_params(), end);
        vm.deal(alice, 0.3 ether);
        vm.deal(bob, 0.1 ether);
        vm.prank(alice);
        vault.deposit{value: 0.3 ether}(id);
        vm.prank(bob);
        vault.deposit{value: 0.1 ether}(id);

        vm.warp(end);
        (address token, PoolId poolId, uint256 bought) = vault.launch(id);
        assertGt(bought, 0);
        (, int24 tick,,) = PM.getSlot0(poolId);
        assertLt(tick, START_TICK);
        uint256 back = vault.getVault(id).ethBack;
        assertGt(back, 0, "LP share of the launch fee paid back");

        vm.prank(alice);
        (uint256 ta, uint256 ea) = vault.claim(id);
        vm.prank(bob);
        (uint256 tb, uint256 eb) = vault.claim(id);
        assertEq(ta, bought * 3 / 4);
        assertEq(tb, bought / 4);
        assertEq(ea, back * 3 / 4);
        assertEq(eb, back / 4);
        assertEq(IERC20(token).balanceOf(alice), ta);
        assertLe(IERC20(token).balanceOf(address(vault)), 1);
    }
}

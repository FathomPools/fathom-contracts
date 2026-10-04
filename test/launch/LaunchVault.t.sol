// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {LaunchPools} from "../../src/launch/LaunchPools.sol";
import {LaunchVault} from "../../src/launch/LaunchVault.sol";
import {LaunchBase} from "./LaunchBase.t.sol";

contract LaunchVaultTest is LaunchBase {
    LaunchVault internal vault;
    address internal carol = makeAddr("carol");
    uint40 internal end;

    function setUp() public {
        _deployLaunch();
        vault = new LaunchVault(lp);
        end = uint40(vm.getBlockTimestamp() + 1 days);
    }

    function _open() internal returns (uint256 id) {
        vm.prank(creator);
        id = vault.open(_params(), end);
    }

    function _deposit(uint256 id, address who, uint256 amount) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        vault.deposit{value: amount}(id);
    }

    // ---------------------------------------------------------------- open

    function test_open_storesParamsAndChecksThem() public {
        uint256 id = _open();
        assertEq(id, 1);
        assertEq(vault.vaultCount(), 1);
        LaunchVault.Vault memory v = vault.getVault(id);
        assertEq(v.opener, creator);
        assertEq(v.depositEnd, end);
        assertFalse(v.launched);
        LaunchPools.LaunchParams memory p = vault.getParams(id);
        assertEq(p.name, "Launch Test");
        assertEq(p.symbol, "LT");
        assertEq(p.supply, SUPPLY);
        assertEq(p.seedAmount, SEED);
        assertEq(p.startTick, START_TICK);
        assertEq(p.creator, creator);
        assertEq(p.fees.snipeStartFeeBps, 5000);

        LaunchPools.LaunchParams memory bad = _params();
        bad.fees.snipeSeconds = 0;
        vm.expectRevert(LaunchPools.LaunchPools__BadFees.selector);
        vault.open(bad, end);

        uint256 now_ = vm.getBlockTimestamp();
        vm.expectRevert(LaunchVault.LaunchVault__BadWindow.selector);
        vault.open(_params(), uint40(now_));
        vm.expectRevert(LaunchVault.LaunchVault__BadWindow.selector);
        vault.open(_params(), uint40(now_ + 7 days + 1));
        vault.open(_params(), uint40(now_ + 7 days));
        assertEq(vault.vaultCount(), 2);
    }

    // ---------------------------------------------------------------- deposits

    function test_depositAndWithdraw_beforeTheWindowCloses() public {
        uint256 id = _open();
        _deposit(id, alice, 1 ether);
        _deposit(id, alice, 0.5 ether);
        _deposit(id, bob, 2 ether);
        assertEq(vault.depositOf(id, alice), 1.5 ether);
        assertEq(vault.getVault(id).totalDeposits, 3.5 ether);
        assertEq(address(vault).balance, 3.5 ether);

        vm.prank(alice);
        vault.withdraw(id, 0.4 ether);
        assertEq(alice.balance, 0.4 ether);
        assertEq(vault.depositOf(id, alice), 1.1 ether);
        assertEq(vault.getVault(id).totalDeposits, 3.1 ether);

        vm.startPrank(alice);
        vm.expectRevert(LaunchVault.LaunchVault__BadAmount.selector);
        vault.withdraw(id, 1.1 ether + 1);
        vm.expectRevert(LaunchVault.LaunchVault__BadAmount.selector);
        vault.withdraw(id, 0);
        vm.expectRevert(LaunchVault.LaunchVault__ZeroAmount.selector);
        vault.deposit(id);
        vm.expectRevert(LaunchVault.LaunchVault__UnknownVault.selector);
        vault.deposit{value: 1}(9);
        vm.expectRevert(LaunchVault.LaunchVault__UnknownVault.selector);
        vault.withdraw(9, 1);
        vault.withdraw(id, 1.1 ether); // all of it
        vm.stopPrank();
        assertEq(vault.depositOf(id, alice), 0);
        assertEq(alice.balance, 1.5 ether);
    }

    function test_depositsAndWithdrawalsCloseAtDepositEnd() public {
        uint256 id = _open();
        _deposit(id, alice, 1 ether);
        vm.warp(end);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(LaunchVault.LaunchVault__DepositsClosed.selector);
        vault.deposit{value: 1 ether}(id);
        vm.expectRevert(LaunchVault.LaunchVault__DepositsClosed.selector);
        vault.withdraw(id, 1 ether);
        vm.stopPrank();
    }

    function test_receive_onlyFromLaunchPools() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- launch + claims

    /// Three depositors, one swap: the same price for all, shares pro rata, the LP share of the launch
    /// fee paid back pro rata too, and exactly what a direct launch with the same ETH would buy.
    function test_launch_oneSwapSamePriceProRata() public {
        uint256 id = _open();
        _deposit(id, alice, 1 ether);
        _deposit(id, bob, 3 ether);
        _deposit(id, carol, 0.5 ether);
        uint256 total = 4.5 ether;

        uint256 snap = vm.snapshotState();
        vm.warp(end);
        vm.deal(address(this), total);
        (,, uint256 direct) = lp.launch{value: total}(_params());
        vm.revertToState(snap);

        vm.warp(end);
        vm.prank(makeAddr("anyone"));
        (address token, PoolId poolId, uint256 bought) = vault.launch(id);
        assertEq(bought, direct, "one swap of the whole vault");
        LaunchVault.Vault memory v = vault.getVault(id);
        assertTrue(v.launched);
        assertEq(v.token, token);
        assertEq(PoolId.unwrap(v.poolId), PoolId.unwrap(poolId));
        assertEq(v.tokensBought, bought);
        assertEq(IERC20(token).balanceOf(address(vault)), bought);
        assertEq(address(vault).balance, v.ethBack);
        assertApproxEqRel(v.ethBack, 4.05 ether * 400_000 / 1e6, 1e12, "LP share of the 50 % launch fee");
        assertEq(lp.getLaunch(poolId).feeRecipient, creator);
        assertGt(IERC20(token).balanceOf(creator), 0, "unseeded supply to the creator");

        address[3] memory who = [alice, bob, carol];
        uint256[3] memory dep = [uint256(1 ether), 3 ether, 0.5 ether];
        uint256 sumT;
        uint256 sumE;
        for (uint256 i; i < 3; ++i) {
            (uint256 ct, uint256 ce) = vault.claimable(id, who[i]);
            uint256 e0 = who[i].balance;
            vm.prank(who[i]);
            (uint256 t, uint256 e) = vault.claim(id);
            assertEq(t, ct);
            assertEq(e, ce);
            assertEq(t, bought * dep[i] / total);
            assertEq(e, v.ethBack * dep[i] / total);
            assertEq(IERC20(token).balanceOf(who[i]), t);
            assertEq(who[i].balance - e0, e);
            sumT += t;
            sumE += e;
        }
        (uint256 left, uint256 leftEth) = vault.claimable(id, alice);
        assertEq(left + leftEth, 0, "settled");
        assertLe(bought - sumT, 3);
        assertLe(v.ethBack - sumE, 3);

        vm.prank(alice);
        vm.expectRevert(LaunchVault.LaunchVault__NothingToClaim.selector);
        vault.claim(id);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LaunchVault.LaunchVault__NothingToClaim.selector);
        vault.claim(id);
    }

    function test_launch_timingAndOnce() public {
        uint256 id = _open();
        _deposit(id, alice, 1 ether);
        vm.expectRevert(LaunchVault.LaunchVault__DepositsOpen.selector);
        vault.launch(id);
        vm.prank(alice);
        vm.expectRevert(LaunchVault.LaunchVault__NotLaunched.selector);
        vault.claim(id);
        vm.expectRevert(LaunchVault.LaunchVault__UnknownVault.selector);
        vault.launch(5);

        vm.warp(end);
        vault.launch(id);
        vm.expectRevert(LaunchVault.LaunchVault__AlreadyLaunched.selector);
        vault.launch(id);
        vm.prank(alice);
        vm.expectRevert(LaunchVault.LaunchVault__NotRefundable.selector);
        vault.refund(id);
    }

    function test_launch_withoutDeposits_launchesWithoutBuy() public {
        uint256 id = _open();
        vm.warp(end);
        (address token, PoolId poolId, uint256 bought) = vault.launch(id);
        assertEq(bought, 0);
        assertEq(_tick(poolId), START_TICK);
        assertEq(IERC20(token).balanceOf(address(vault)), 0);
        vm.prank(alice);
        vm.expectRevert(LaunchVault.LaunchVault__NothingToClaim.selector);
        vault.claim(id);
    }

    /// Two vaults side by side: launching one leaves the other's ETH alone.
    function test_twoVaults_isolatedBalances() public {
        uint256 a = _open();
        uint256 b = _open();
        _deposit(a, alice, 2 ether);
        _deposit(b, bob, 1 ether);
        vm.warp(end);
        vault.launch(a);
        LaunchVault.Vault memory va = vault.getVault(a);
        assertEq(address(vault).balance, 1 ether + va.ethBack);
        vm.warp(uint256(end) + vault.LAUNCH_WINDOW());
        vm.prank(bob);
        assertEq(vault.refund(b), 1 ether);
        vm.prank(alice);
        vault.claim(a);
        assertLe(address(vault).balance, 1);
    }

    // ---------------------------------------------------------------- no launch

    function test_refund_whenTheWindowPassesWithoutALaunch() public {
        uint256 id = _open();
        _deposit(id, alice, 1 ether);
        _deposit(id, bob, 2 ether);
        vm.warp(end);
        vm.prank(alice);
        vm.expectRevert(LaunchVault.LaunchVault__NotRefundable.selector);
        vault.refund(id);

        vm.warp(uint256(end) + vault.LAUNCH_WINDOW());
        vm.expectRevert(LaunchVault.LaunchVault__LaunchExpired.selector);
        vault.launch(id);
        vm.prank(alice);
        assertEq(vault.refund(id), 1 ether);
        vm.prank(bob);
        assertEq(vault.refund(id), 2 ether);
        assertEq(alice.balance, 1 ether);
        assertEq(bob.balance, 2 ether);
        assertEq(address(vault).balance, 0);

        vm.prank(alice);
        vm.expectRevert(LaunchVault.LaunchVault__NothingToClaim.selector);
        vault.refund(id);
        vm.prank(carol);
        vm.expectRevert(LaunchVault.LaunchVault__NothingToClaim.selector);
        vault.refund(id);
        vm.expectRevert(LaunchVault.LaunchVault__UnknownVault.selector);
        vault.refund(42);
    }

    /// The protocol stays paused through the whole launch window: launch keeps failing, refunds open.
    function test_pausedThroughTheLaunchWindow_refunds() public {
        uint256 id = _open();
        _deposit(id, alice, 1 ether);
        vm.prank(owner);
        config.setPaused(true);
        vm.warp(end);
        vm.expectRevert();
        vault.launch(id);
        assertFalse(vault.getVault(id).launched);
        vm.warp(uint256(end) + vault.LAUNCH_WINDOW());
        vm.prank(alice);
        assertEq(vault.refund(id), 1 ether);
    }

    // ---------------------------------------------------------------- fuzz

    /// Pro-rata claims round down: nobody gets more than their share, the vault never runs short, and
    /// at most one wei per depositor stays behind.
    function testFuzz_claimRounding(uint256[6] memory amounts, uint256 order) public {
        uint256 id = _open();
        address[6] memory who;
        uint256 total;
        for (uint256 i; i < 6; ++i) {
            amounts[i] = bound(amounts[i], 1, 50 ether);
            who[i] = address(uint160(0xA11CE + i));
            _deposit(id, who[i], amounts[i]);
            total += amounts[i];
        }
        vm.warp(end);
        (address token,, uint256 bought) = vault.launch(id);
        uint256 back = vault.getVault(id).ethBack;

        uint256 sumT;
        uint256 sumE;
        for (uint256 k; k < 6; ++k) {
            uint256 i = (k + order % 6) % 6; // claim order must not matter
            vm.prank(who[i]);
            (uint256 t, uint256 e) = vault.claim(id);
            assertEq(t, bought * amounts[i] / total);
            assertEq(e, back * amounts[i] / total);
            sumT += t;
            sumE += e;
        }
        assertLe(sumT, bought);
        assertLe(sumE, back);
        assertLt(bought - sumT, 6);
        assertLt(back - sumE, 6);
        assertEq(IERC20(token).balanceOf(address(vault)), bought - sumT);
        assertEq(address(vault).balance, back - sumE);
    }
}

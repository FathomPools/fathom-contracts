// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRouter} from "../interfaces/IRouter.sol";
import {DlmmVault} from "./DlmmVault.sol";
import {DlmmVaultFactory} from "./DlmmVaultFactory.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// One-token deposits into and withdrawals out of Fathom DLMM vaults, in one transaction.
///
/// - `zapIn` takes a single token (or native ETH for a WETH vault), swaps `swapAmount` of it into the
///   vault's other token through the Fathom Router, deposits both into the vault for `to` and returns
///   whatever the vault did not take to the caller.
/// - `zapOut` redeems vault shares and swaps the side the caller does not want through the Router, so
///   the whole withdrawal arrives in one token (or native ETH).
///
/// The zap has no owner and holds nothing between calls. The caller picks the route and the split
/// off-chain; the contract only checks that the route lands in the right token and enforces the
/// caller's minimums (`minSwapOut` and `minShares` in, `minOut` out) and deadline. Only vaults
/// created by the Fathom vault factory are accepted.
contract DlmmVaultZap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IRouter public immutable router;
    address public immutable weth;
    DlmmVaultFactory public immutable factory;

    event ZapIn(
        address indexed sender,
        address indexed vault,
        address indexed to,
        address tokenIn,
        uint256 amountIn,
        uint256 swapped,
        uint256 shares,
        uint256 refundX,
        uint256 refundY
    );
    event ZapOut(
        address indexed sender,
        address indexed vault,
        address indexed to,
        address tokenOut,
        uint256 shares,
        uint256 amountOut
    );

    error DlmmVaultZap__UnknownVault();
    error DlmmVaultZap__BadToken();
    error DlmmVaultZap__BadRoute();
    error DlmmVaultZap__ValueMismatch();
    error DlmmVaultZap__ZeroAmount();
    error DlmmVaultZap__BadSplit();
    error DlmmVaultZap__Expired();
    error DlmmVaultZap__TooLittleReceived(uint256 amountOut);
    error DlmmVaultZap__NativeTransferFailed();

    constructor(IRouter router_, address weth_, DlmmVaultFactory factory_) {
        router = router_;
        weth = weth_;
        factory = factory_;
    }

    /// Native ETH from WETH.withdraw and from routes that end in ETH.
    receive() external payable {}

    struct ZapInParams {
        address vault;
        address tokenIn; // tokenX or tokenY of the vault; address(0) = native ETH for a WETH side
        uint256 amountIn;
        uint256 swapAmount; // part of amountIn swapped into the other token (0 = deposit one-sided)
        IRouter.Hop[] hops; // route tokenIn -> other token (ignored when swapAmount == 0)
        uint256 minSwapOut;
        uint256 minShares;
        uint24 activeIdDesired;
        uint24 idSlippage;
        address to;
        uint256 deadline;
    }

    /// Deposits a single token into `p.vault`. Unused tokens (the vault only takes its own mix) are
    /// returned to the caller, as native ETH if the caller paid in ETH.
    function zapIn(ZapInParams calldata p) external payable nonReentrant returns (uint256 shares) {
        if (block.timestamp > p.deadline) revert DlmmVaultZap__Expired();
        if (!factory.isVault(p.vault)) revert DlmmVaultZap__UnknownVault();
        if (p.amountIn == 0) revert DlmmVaultZap__ZeroAmount();
        DlmmVault v = DlmmVault(p.vault);
        address x = address(v.tokenX());
        address y = address(v.tokenY());

        // Take the input; native ETH is wrapped so the rest of the flow only sees ERC-20s.
        address held = p.tokenIn == address(0) ? weth : p.tokenIn;
        if (held != x && held != y) revert DlmmVaultZap__BadToken();
        if (p.tokenIn == address(0)) {
            if (msg.value != p.amountIn) revert DlmmVaultZap__ValueMismatch();
            IWETH9(weth).deposit{value: msg.value}();
        } else {
            if (msg.value != 0) revert DlmmVaultZap__ValueMismatch();
            IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        }
        if (p.swapAmount > p.amountIn) revert DlmmVaultZap__BadSplit();
        if (p.swapAmount != 0) _swap(p.hops, held, held == x ? y : x, p.swapAmount, p.minSwapOut, p.deadline);

        uint256 bx = IERC20(x).balanceOf(address(this));
        uint256 by = IERC20(y).balanceOf(address(this));
        IERC20(x).forceApprove(p.vault, bx);
        IERC20(y).forceApprove(p.vault, by);
        uint256 usedX;
        uint256 usedY;
        (shares, usedX, usedY) = v.deposit(bx, by, p.minShares, p.to, p.activeIdDesired, p.idSlippage, p.deadline);
        IERC20(x).forceApprove(p.vault, 0);
        IERC20(y).forceApprove(p.vault, 0);

        uint256 rx = bx - usedX;
        uint256 ry = by - usedY;
        bool native = p.tokenIn == address(0);
        _pay(x, msg.sender, rx, native);
        _pay(y, msg.sender, ry, native);
        emit ZapIn(msg.sender, p.vault, p.to, p.tokenIn, p.amountIn, p.swapAmount, shares, rx, ry);
    }

    struct ZapOutParams {
        address vault;
        uint256 shares;
        address tokenOut; // tokenX or tokenY; address(0) = native ETH for a WETH side
        IRouter.Hop[] hops; // route other token -> tokenOut (ignored if that side is empty)
        uint256 minOut;
        address to;
        uint256 deadline;
    }

    /// Redeems `p.shares` (approved to this contract) and sends the whole withdrawal to `p.to` in
    /// `p.tokenOut`. Reverts below `p.minOut`. Works while the protocol is paused as long as the
    /// route does (withdrawals never check the pause flag; swaps do).
    function zapOut(ZapOutParams calldata p) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > p.deadline) revert DlmmVaultZap__Expired();
        if (!factory.isVault(p.vault)) revert DlmmVaultZap__UnknownVault();
        if (p.shares == 0) revert DlmmVaultZap__ZeroAmount();
        DlmmVault v = DlmmVault(p.vault);
        address x = address(v.tokenX());
        address y = address(v.tokenY());
        address want = p.tokenOut == address(0) ? weth : p.tokenOut;
        if (want != x && want != y) revert DlmmVaultZap__BadToken();
        address other = want == x ? y : x;

        IERC20(p.vault).safeTransferFrom(msg.sender, address(this), p.shares);
        v.withdraw(p.shares, address(this), 0, 0, p.deadline);

        uint256 rest = IERC20(other).balanceOf(address(this));
        if (rest != 0) _swap(p.hops, other, want, rest, 0, p.deadline);

        amountOut = IERC20(want).balanceOf(address(this));
        if (amountOut < p.minOut) revert DlmmVaultZap__TooLittleReceived(amountOut);
        _pay(want, p.to, amountOut, p.tokenOut == address(0));
        emit ZapOut(msg.sender, p.vault, p.to, p.tokenOut, p.shares, amountOut);
    }

    // ------------------------------------------------------------------ internals

    /// Swaps `amount` of `tokenIn` through the Router and requires at least `minOut` of `tokenOut`
    /// (WETH counts native ETH the route returns, which is wrapped). The route's own tokens only have
    /// to be ETH/WETH-compatible with ours; what counts is the balance that actually arrives.
    function _swap(
        IRouter.Hop[] calldata hops,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 minOut,
        uint256 deadline
    ) internal {
        (address rin, address rout) = router.routeTokens(hops);
        if (!_same(rin, tokenIn) || !_same(rout, tokenOut)) revert DlmmVaultZap__BadRoute();
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        if (rin == address(0)) {
            IWETH9(weth).withdraw(amount);
            router.swapExactIn{value: amount}(hops, amount, 0, address(this), deadline);
        } else {
            IERC20(tokenIn).forceApprove(address(router), amount);
            router.swapExactIn(hops, amount, 0, address(this), deadline);
            IERC20(tokenIn).forceApprove(address(router), 0);
        }
        uint256 eth = address(this).balance - ethBefore;
        if (eth != 0) {
            if (tokenOut != weth) revert DlmmVaultZap__BadRoute();
            IWETH9(weth).deposit{value: eth}();
        }
        uint256 got = IERC20(tokenOut).balanceOf(address(this)) - before;
        if (got < minOut) revert DlmmVaultZap__TooLittleReceived(got);
    }

    /// Sends `amount` of `token`; WETH is unwrapped first when the counterparty uses native ETH.
    function _pay(address token, address to, uint256 amount, bool native) internal {
        if (amount == 0) return;
        if (native && token == weth) {
            IWETH9(weth).withdraw(amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert DlmmVaultZap__NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// Equal, or native ETH vs WETH.
    function _same(address a, address b) internal view returns (bool) {
        if (a == b) return true;
        return (a == address(0) && b == weth) || (a == weth && b == address(0));
    }
}

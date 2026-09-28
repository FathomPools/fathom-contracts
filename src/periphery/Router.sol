// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouter} from "../interfaces/IRouter.sol";
import {IDlmmPair} from "../interfaces/IDlmmPair.sol";
import {PonsAdapter} from "./PonsAdapter.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// Exact-in router across Uniswap v4 pools (our hooks, Pons graduated pools, any v4 pool),
/// Fathom DLMM pairs and Pons bonding curves. Holds nothing between calls; every hop's output
/// lands here and the final output is forwarded to `to`. One PoolManager unlock per v4 hop.
contract Router is IRouter, IUnlockCallback {
    using SafeERC20 for IERC20;

    uint8 public constant V4 = 0;
    uint8 public constant DLMM = 1;
    uint8 public constant PONS_CURVE = 2;
    uint8 public constant WETH_WRAP = 3;
    uint256 public constant MAX_SWAP_HOPS = 3;

    IPoolManager public immutable poolManager;
    address public immutable weth;

    /// Quote mode: the unlock callback reverts with the swap output.
    error QuoteResult(uint256 amountOut);

    struct V4Call {
        PoolKey key;
        bool zeroForOne;
        bytes hookData;
        uint256 amountIn;
        bool quote;
    }

    constructor(IPoolManager pm, address weth_) {
        poolManager = pm;
        weth = weth_;
    }

    receive() external payable {}

    // ---------------------------------------------------------------- swap

    function swapExactIn(Hop[] calldata hops, uint256 amountIn, uint256 minAmountOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 out)
    {
        if (block.timestamp > deadline) revert Expired();
        if (to == address(0)) revert ZeroRecipient();
        if (amountIn == 0) revert ZeroAmount();
        (address tokenIn,) = routeTokens(hops);

        // Starting currency: native if ETH was sent (auto-wrapped if the first hop wants WETH).
        address cur;
        if (msg.value > 0) {
            if (msg.value != amountIn || (tokenIn != address(0) && tokenIn != weth)) revert ValueMismatch();
        } else {
            if (tokenIn == address(0)) revert ValueMismatch();
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            cur = tokenIn;
        }
        address startToken = cur;

        out = amountIn;
        for (uint256 i; i < hops.length; ++i) {
            (cur, out) = _execute(hops[i], cur, out);
        }
        if (out < minAmountOut) revert TooLittleReceived();
        _send(cur, to, out);
        emit Swapped(msg.sender, to, startToken, cur, amountIn, out);
    }

    // ---------------------------------------------------------------- quote

    function quoteExactIn(Hop[] calldata hops, uint256 amountIn) external returns (uint256 out) {
        routeTokens(hops);
        out = amountIn;
        for (uint256 i; i < hops.length; ++i) {
            Hop calldata h = hops[i];
            if (h.kind == V4) {
                (PoolKey memory key, bool zeroForOne, bytes memory hookData) =
                    abi.decode(h.data, (PoolKey, bool, bytes));
                try poolManager.unlock(abi.encode(V4Call(key, zeroForOne, hookData, out, true))) {
                    revert BadRoute(); // unreachable: quote callbacks always revert
                } catch (bytes memory reason) {
                    out = _parseQuote(reason);
                }
            } else if (h.kind == DLMM) {
                (address pair, bool swapForY) = abi.decode(h.data, (address, bool));
                (uint128 left, uint128 o,) = IDlmmPair(pair).getSwapOut(uint128(out), swapForY);
                if (left > 0) revert InsufficientLiquidity();
                out = o;
            } else if (h.kind == PONS_CURVE) {
                (address curve, bool isBuy) = abi.decode(h.data, (address, bool));
                out = PonsAdapter.quote(curve, isBuy, out);
            }
        }
    }

    // ---------------------------------------------------------------- route shape

    /// Validates hop kinds/count and token chaining (ETH<->WETH treated as compatible).
    function routeTokens(Hop[] calldata hops) public view returns (address tokenIn, address tokenOut) {
        uint256 n = hops.length;
        if (n == 0) revert BadRoute();
        uint256 swaps;
        for (uint256 i; i < n; ++i) {
            (address hin, address hout) = _hopTokens(hops[i], i == 0 ? address(0) : tokenOut);
            if (hops[i].kind != WETH_WRAP) {
                if (++swaps > MAX_SWAP_HOPS) revert BadRoute();
            }
            if (i == 0) tokenIn = hin;
            else if (!_compatible(tokenOut, hin)) revert BadRoute();
            tokenOut = hout;
        }
    }

    // ---------------------------------------------------------------- v4 callback

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        V4Call memory c = abi.decode(raw, (V4Call));
        BalanceDelta delta = poolManager.swap(
            c.key,
            SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: -int256(c.amountIn),
                sqrtPriceLimitX96: c.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            c.hookData
        );
        (int128 dIn, int128 dOut) =
            c.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 out = dOut > 0 ? uint256(uint128(dOut)) : 0;
        if (c.quote) revert QuoteResult(out);

        uint256 paid = dIn < 0 ? uint256(uint128(-dIn)) : 0;
        if (paid != c.amountIn) revert PartialFill();
        (Currency cin, Currency cout) = c.zeroForOne ? (c.key.currency0, c.key.currency1) : (c.key.currency1, c.key.currency0);
        if (cin.isAddressZero()) {
            poolManager.settle{value: paid}();
        } else {
            poolManager.sync(cin);
            IERC20(Currency.unwrap(cin)).safeTransfer(address(poolManager), paid);
            poolManager.settle();
        }
        if (out > 0) poolManager.take(cout, address(this), out);
        return abi.encode(out);
    }

    // ---------------------------------------------------------------- internals

    function _execute(Hop calldata h, address cur, uint256 amount) internal returns (address, uint256) {
        if (h.kind == WETH_WRAP) {
            if (cur == address(0)) {
                IWETH(weth).deposit{value: amount}();
                return (weth, amount);
            }
            IWETH(weth).withdraw(amount);
            return (address(0), amount);
        }
        (address hin, address hout) = _hopTokens(h, cur);
        _bridge(cur, hin, amount);
        uint256 out;
        if (h.kind == V4) {
            (PoolKey memory key, bool zeroForOne, bytes memory hookData) = abi.decode(h.data, (PoolKey, bool, bytes));
            out = abi.decode(poolManager.unlock(abi.encode(V4Call(key, zeroForOne, hookData, amount, false))), (uint256));
        } else if (h.kind == DLMM) {
            (address pair, bool swapForY) = abi.decode(h.data, (address, bool));
            IERC20(hin).safeTransfer(pair, amount);
            out = IDlmmPair(pair).swap(swapForY, address(this));
        } else {
            (address curve, bool isBuy) = abi.decode(h.data, (address, bool));
            out = PonsAdapter.swap(curve, isBuy, hin, hout, amount);
        }
        return (hout, out);
    }

    function _hopTokens(Hop calldata h, address cur) internal view returns (address hin, address hout) {
        if (h.kind == V4) {
            (PoolKey memory key, bool zeroForOne,) = abi.decode(h.data, (PoolKey, bool, bytes));
            (hin, hout) = zeroForOne
                ? (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1))
                : (Currency.unwrap(key.currency1), Currency.unwrap(key.currency0));
        } else if (h.kind == DLMM) {
            (address pair, bool swapForY) = abi.decode(h.data, (address, bool));
            address x = IDlmmPair(pair).tokenX();
            address y = IDlmmPair(pair).tokenY();
            (hin, hout) = swapForY ? (x, y) : (y, x);
        } else if (h.kind == PONS_CURVE) {
            (address curve, bool isBuy) = abi.decode(h.data, (address, bool));
            (hin, hout) = PonsAdapter.tokens(curve, isBuy);
        } else if (h.kind == WETH_WRAP) {
            if (cur == address(0)) (hin, hout) = (address(0), weth);
            else if (cur == weth) (hin, hout) = (weth, address(0));
            else revert BadRoute();
        } else {
            revert BadKind();
        }
    }

    function _compatible(address a, address b) internal view returns (bool) {
        return a == b || (a == address(0) && b == weth) || (a == weth && b == address(0));
    }

    function _bridge(address cur, address need, uint256 amount) internal {
        if (cur == need) return;
        if (cur == address(0) && need == weth) IWETH(weth).deposit{value: amount}();
        else if (cur == weth && need == address(0)) IWETH(weth).withdraw(amount);
        else revert BadRoute();
    }

    function _send(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _parseQuote(bytes memory reason) internal pure returns (uint256 out) {
        if (reason.length != 36 || bytes4(reason) != QuoteResult.selector) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
        assembly {
            out := mload(add(reason, 36))
        }
    }
}

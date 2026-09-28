// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPonsCurve} from "../interfaces/IPonsCurve.sol";
import {IRouter} from "../interfaces/IRouter.sol";

/// Pons bonding-curve buy/sell for the Router (pre-graduation only). A graduated curve reverts
/// `PonsGraduated()`; the web then routes through the token's Pons v4 pool (memeHook) as a V4 hop.
library PonsAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    /// (input, output) of a curve hop; address(0) = native ETH quote.
    function tokens(address curve, bool isBuy) internal view returns (address tin, address tout) {
        IPonsCurve c = IPonsCurve(curve);
        address q = c.isNativeQuote() ? address(0) : c.pairToken();
        address t = c.token();
        (tin, tout) = isBuy ? (q, t) : (t, q);
    }

    /// Swap `amountIn` of `tin` (held by this contract) on the curve; output lands here.
    function swap(address curve, bool isBuy, address tin, address tout, uint256 amountIn)
        internal
        returns (uint256 out)
    {
        IPonsCurve c = IPonsCurve(curve);
        if (c.graduated()) revert IRouter.PonsGraduated();
        uint256 before = balanceOf(tout);
        if (tin == address(0)) {
            c.buy{value: amountIn}(amountIn, 0, address(this));
        } else {
            IERC20(tin).forceApprove(curve, amountIn);
            if (isBuy) c.buy(amountIn, 0, address(this));
            else c.sell(amountIn, 0, address(this));
        }
        out = balanceOf(tout) - before;
    }

    /// Off-chain-style quote from reserves: fees (feeBps + creatorTaxBps, + snipe tax on buys) come
    /// off the quote side, x*y=k over (quoteReserve incl. phantom quote, tokenReserve).
    function quote(address curve, bool isBuy, uint256 amountIn) internal view returns (uint256 out) {
        IPonsCurve c = IPonsCurve(curve);
        if (c.graduated()) revert IRouter.PonsGraduated();
        (uint256 q, uint256 t) = c.getReserves();
        uint256 feeBps = c.feeBps() + c.creatorTaxBps();
        if (isBuy) {
            feeBps += c.currentSnipeTaxBps(address(this));
            if (feeBps >= BPS) return 0;
            uint256 net = amountIn * (BPS - feeBps) / BPS;
            out = t * net / (q + net);
        } else {
            uint256 gross = q * amountIn / (t + amountIn);
            out = feeBps >= BPS ? 0 : gross * (BPS - feeBps) / BPS;
        }
    }

    /// Curve of a Pons-launched token (factory `getLaunchedToken` returns a static struct led by
    /// (token, curve)); address(0) if unknown.
    function curveOf(address factory, address token) internal view returns (address curve) {
        (bool ok, bytes memory ret) = factory.staticcall(abi.encodeWithSignature("getLaunchedToken(address)", token));
        if (!ok || ret.length < 64) return address(0);
        (, curve) = abi.decode(ret, (address, address));
    }

    function balanceOf(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }
}

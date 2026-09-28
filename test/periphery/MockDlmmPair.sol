// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDlmmPair} from "../../src/interfaces/IDlmmPair.sol";

/// Fixed-rate IDlmmPair for Router tests: 1 X = rateE18/1e18 Y, no fee, pay-first swaps.
contract MockDlmmPair {
    address public tokenX;
    address public tokenY;
    uint256 public rateE18;
    uint128 public reserveX;
    uint128 public reserveY;

    constructor(address x, address y, uint256 rate) {
        tokenX = x;
        tokenY = y;
        rateE18 = rate;
    }

    /// Call after funding the pair directly.
    function sync() external {
        reserveX = uint128(IERC20(tokenX).balanceOf(address(this)));
        reserveY = uint128(IERC20(tokenY).balanceOf(address(this)));
    }

    function getReserves() external view returns (uint128, uint128) {
        return (reserveX, reserveY);
    }

    function getSwapOut(uint128 amountIn, bool swapForY)
        public
        view
        returns (uint128 amountInLeft, uint128 amountOut, uint128 fee)
    {
        uint256 out = swapForY ? uint256(amountIn) * rateE18 / 1e18 : uint256(amountIn) * 1e18 / rateE18;
        uint256 avail = swapForY ? reserveY : reserveX;
        if (out > avail) return (amountIn, 0, 0);
        return (0, uint128(out), 0);
    }

    function swap(bool swapForY, address to) external returns (uint256 amountOut) {
        uint256 bx = IERC20(tokenX).balanceOf(address(this));
        uint256 by = IERC20(tokenY).balanceOf(address(this));
        uint256 amountIn = swapForY ? bx - reserveX : by - reserveY;
        (uint128 left, uint128 out,) = getSwapOut(uint128(amountIn), swapForY);
        require(left == 0 && amountIn > 0, "liq");
        amountOut = out;
        IERC20(swapForY ? tokenY : tokenX).transfer(to, amountOut);
        reserveX = uint128(IERC20(tokenX).balanceOf(address(this)));
        reserveY = uint128(IERC20(tokenY).balanceOf(address(this)));
        emit IDlmmPair.Swap(msg.sender, to, 0, swapForY, amountIn, amountOut, 0, 0);
    }
}

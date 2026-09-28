// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Fixed-point helpers for the DLMM (Liquidity-Book style) pair. Prices are 128.128 fixed point:
/// price(id) = (1 + binStep / 1e4) ^ (id - 2^23), expressed as Y per X in raw token units.
library BinMath {
    uint256 internal constant SCALE_OFFSET = 128;
    uint256 internal constant SCALE = 1 << 128;
    int256 internal constant REAL_ID_SHIFT = 1 << 23;
    /// |id - 2^23| must stay below 2^20 (same bound as LB) to keep the pow loop bounded.
    uint256 internal constant MAX_EXPONENT = 1 << 20;

    uint256 internal constant PRECISION = 1e18;

    error BinMath__PowOutOfBounds();

    function getPriceFromId(uint24 id, uint16 binStep) internal pure returns (uint256) {
        uint256 base = SCALE + (uint256(binStep) << SCALE_OFFSET) / 10_000;
        return pow(base, int256(uint256(id)) - REAL_ID_SHIFT);
    }

    /// x ^ y for a 128.128 `x` > 1 and signed integer `y`, by binary exponentiation. The loop squares
    /// 1/x (< 1) so intermediate products never overflow; the result is inverted back for y > 0.
    function pow(uint256 x, int256 y) internal pure returns (uint256 result) {
        bool positive = y > 0;
        uint256 absY = positive ? uint256(y) : uint256(-y);
        if (absY >= MAX_EXPONENT || x <= SCALE) revert BinMath__PowOutOfBounds();

        uint256 sq = type(uint256).max / x; // (1/x) in 128.128, < 2^128
        result = SCALE;
        while (absY != 0) {
            if (absY & 1 != 0) result = (result * sq) >> SCALE_OFFSET;
            absY >>= 1;
            if (absY != 0) sq = (sq * sq) >> SCALE_OFFSET;
        }
        if (result == 0) revert BinMath__PowOutOfBounds();
        if (positive) result = type(uint256).max / result;
    }

    /// Value of (x, y) in Y units at `price` (the constant-sum invariant of a bin).
    function getLiquidity(uint256 x, uint256 y, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(x, price, SCALE) + y;
    }

    /// Fee to add on top of a fee-less amount: amount * fee / (1 - fee), rounded up.
    function feeOnAmount(uint256 amount, uint256 feeRate) internal pure returns (uint256) {
        return Math.mulDiv(amount, feeRate, PRECISION - feeRate, Math.Rounding.Ceil);
    }

    /// Fee contained in a fee-inclusive amount: amount * fee, rounded up.
    function feeFromAmount(uint256 amountWithFees, uint256 feeRate) internal pure returns (uint256) {
        return Math.mulDiv(amountWithFees, feeRate, PRECISION, Math.Rounding.Ceil);
    }
}

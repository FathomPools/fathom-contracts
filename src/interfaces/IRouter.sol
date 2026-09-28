// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Fathom Router boundary. address(0) = native ETH everywhere.
/// Hop kinds and their `data`:
///   0 V4          abi.encode(PoolKey key, bool zeroForOne, bytes hookData)
///   1 DLMM        abi.encode(address pair, bool swapForY)
///   2 PONS_CURVE  abi.encode(address curve, bool buy)
///   3 WETH        empty: flips native ETH <-> WETH (needed only to unwrap a final WETH output;
///                 ETH/WETH mismatches between hops are bridged automatically)
interface IRouter {
    struct Hop {
        uint8 kind;
        bytes data;
    }

    event Swapped(
        address indexed sender,
        address indexed to,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    error Expired();
    error BadRoute();
    error BadKind();
    error ZeroAmount();
    error ZeroRecipient();
    error ValueMismatch();
    error TooLittleReceived();
    error PartialFill();
    error InsufficientLiquidity();
    error NotPoolManager();
    error NativeTransferFailed();
    error PonsGraduated();

    function swapExactIn(Hop[] calldata hops, uint256 amountIn, uint256 minAmountOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 out);

    /// Non-view; call with eth_call. v4 hops are simulated (revert-with-result), DLMM via getSwapOut,
    /// Pons curves via their reserves/fees.
    function quoteExactIn(Hop[] calldata hops, uint256 amountIn) external returns (uint256 out);

    /// Route input token (first hop) and output token (after the last hop).
    function routeTokens(Hop[] calldata hops) external view returns (address tokenIn, address tokenOut);
}

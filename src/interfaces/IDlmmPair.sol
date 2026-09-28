// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Contract boundary between the DLMM (Liquidity Book style) pair and the rest of Fathom.
/// Swaps follow the LB "pay first" pattern: the caller transfers `amountIn` of the input token to
/// the pair, then calls `swap`; the pair measures its balance delta as the input.
interface IDlmmPair {
    event Swap(
        address indexed sender,
        address indexed to,
        uint24 activeId,
        bool swapForY,
        uint256 amountIn,
        uint256 amountOut,
        uint256 totalFee,
        uint256 protocolFee
    );
    event DepositedToBins(address indexed sender, address indexed to, uint256[] ids, uint256[] amountsX, uint256[] amountsY);
    event WithdrawnFromBins(address indexed sender, address indexed to, uint256[] ids, uint256[] amountsX, uint256[] amountsY);

    function tokenX() external view returns (address);
    function tokenY() external view returns (address);
    function binStep() external view returns (uint16);
    function getActiveId() external view returns (uint24);
    function getBin(uint24 id) external view returns (uint128 reserveX, uint128 reserveY);
    function getReserves() external view returns (uint128 reserveX, uint128 reserveY);
    /// Price of 1 X in Y at bin `id`, 128.128 fixed point, raw token units.
    function getPriceFromId(uint24 id) external view returns (uint256 price128x128);

    /// Quote: output (after fees) for `amountIn`; `amountInLeft` > 0 when liquidity runs out.
    function getSwapOut(uint128 amountIn, bool swapForY)
        external
        view
        returns (uint128 amountInLeft, uint128 amountOut, uint128 fee);

    /// Swap the tokens already sent to the pair. swapForY = true: X in, Y out.
    function swap(bool swapForY, address to) external returns (uint256 amountOut);
}

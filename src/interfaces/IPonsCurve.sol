// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Pons (Robinhood Chain launchpad) bonding curve, as decoded from live bytecode (4663).
/// buy/sell take (amountIn, minOut, recipient) and return the amount out. For a native-quote curve
/// `buy` is payable and requires msg.value == amountIn (else `NativeValueMismatch(value, amountIn)`).
/// Buys pay feeBps + creatorTaxBps (+ a decaying launch snipe tax) on the input; x*y=k over
/// (quoteReserve incl. the phantom virtual quote, tokenReserve).
interface IPonsCurve {
    function buy(uint256 amountIn, uint256 minOut, address recipient) external payable returns (uint256 out);
    function sell(uint256 amountIn, uint256 minOut, address recipient) external returns (uint256 out);
    function graduated() external view returns (bool);
    function readyToGraduate() external view returns (bool);
    function isNativeQuote() external view returns (bool);
    function pairToken() external view returns (address);
    function token() external view returns (address);
    function feeBps() external view returns (uint256);
    function creatorTaxBps() external view returns (uint256);
    function currentSnipeTaxBps(address buyer) external view returns (uint256);
    function quoteReserve() external view returns (uint256);
    function tokenReserve() external view returns (uint256);
    function getReserves() external view returns (uint256 quoteReserve_, uint256 tokenReserve_);
}

/// Pons factory. `getLaunchedToken` returns a static struct whose first two words are
/// (token, curve); read it raw via `PonsAdapter.curveOf`.
interface IPonsFactory {
    function memeHook() external view returns (address);
    function poolManager() external view returns (address);
}

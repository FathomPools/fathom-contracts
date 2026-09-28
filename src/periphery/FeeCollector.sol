// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouter} from "../interfaces/IRouter.sol";
import {AssetRegistry} from "../core/AssetRegistry.sol";

/// Receives Fathom protocol fees (ERC-20 + ETH). The owner sets, per fee token, a Router route to
/// native ETH, a per-call cap and whether an AssetRegistry oracle bounds the output. Anyone can then
/// `convert`; the ETH goes straight to the Buyback. ETH fees are forwarded with `forwardEth`.
contract FeeCollector is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_SLIPPAGE_BPS = 2000;

    struct Route {
        IRouter.Hop[] hops;
        uint256 maxPerCall; // max input per convert call (token units)
        bool useOracle; // minOut from AssetRegistry prices (token as asset or quote, ETH as quote(0))
        bool set;
    }

    IRouter public immutable router;
    AssetRegistry public immutable registry;
    address public buyback;
    uint16 public maxSlippageBps = 300;
    mapping(address => Route) internal _routes;

    event RouteSet(address indexed token, uint256 maxPerCall, bool useOracle);
    event RouteCleared(address indexed token);
    event BuybackSet(address buyback);
    event MaxSlippageSet(uint16 bps);
    event Converted(address indexed token, uint256 amountIn, uint256 ethOut);
    event EthForwarded(uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error BadRoute();
    error NoRoute();
    error HasRoute();
    error OverCap();
    error ZeroAmount();
    error StaleOracle();
    error BadSlippage();
    error NativeTransferFailed();

    constructor(address owner_, IRouter router_, AssetRegistry registry_, address buyback_) Ownable(owner_) {
        if (address(router_) == address(0) || buyback_ == address(0)) revert ZeroAddress();
        router = router_;
        registry = registry_;
        buyback = buyback_;
    }

    receive() external payable {}

    // ---------------------------------------------------------------- admin

    function setRoute(address token, IRouter.Hop[] calldata hops, uint256 maxPerCall, bool useOracle)
        external
        onlyOwner
    {
        if (token == address(0) || maxPerCall == 0) revert BadRoute();
        (address tin, address tout) = router.routeTokens(hops);
        if (tin != token || tout != address(0)) revert BadRoute();
        if (useOracle && address(registry) == address(0)) revert BadRoute();
        Route storage r = _routes[token];
        delete r.hops;
        for (uint256 i; i < hops.length; ++i) {
            r.hops.push(hops[i]);
        }
        r.maxPerCall = maxPerCall;
        r.useOracle = useOracle;
        r.set = true;
        emit RouteSet(token, maxPerCall, useOracle);
    }

    function clearRoute(address token) external onlyOwner {
        delete _routes[token];
        emit RouteCleared(token);
    }

    function setBuyback(address b) external onlyOwner {
        if (b == address(0)) revert ZeroAddress();
        buyback = b;
        emit BuybackSet(b);
    }

    function setMaxSlippageBps(uint16 bps) external onlyOwner {
        if (bps > MAX_SLIPPAGE_BPS) revert BadSlippage();
        maxSlippageBps = bps;
        emit MaxSlippageSet(bps);
    }

    /// Only for tokens without a conversion route (stray or unsupported fee tokens).
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (_routes[token].set) revert HasRoute();
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    // ---------------------------------------------------------------- views

    function route(address token) external view returns (Route memory) {
        return _routes[token];
    }

    /// Oracle floor for converting `amount` of `token` (0 when the route has no oracle).
    function minEthOut(address token, uint256 amount) public view returns (uint256) {
        Route storage r = _routes[token];
        if (!r.useOracle) return 0;
        (uint256 pToken, bool s1) = registry.isAsset(token) ? registry.assetPrice(token) : registry.quotePrice(token);
        (uint256 pEth, bool s2) = registry.quotePrice(address(0));
        if (s1 || s2) revert StaleOracle();
        uint256 valueEth = amount * pToken / (10 ** IERC20Metadata(token).decimals()) * 1e18 / pEth;
        return valueEth * (10_000 - maxSlippageBps) / 10_000;
    }

    // ---------------------------------------------------------------- permissionless

    /// Swap `amount` (0 = min(balance, cap)) of `token` to ETH for the Buyback.
    function convert(address token, uint256 amount) external nonReentrant returns (uint256 ethOut) {
        Route storage r = _routes[token];
        if (!r.set) revert NoRoute();
        if (amount == 0) {
            amount = IERC20(token).balanceOf(address(this));
            if (amount > r.maxPerCall) amount = r.maxPerCall;
        }
        if (amount == 0) revert ZeroAmount();
        if (amount > r.maxPerCall) revert OverCap();
        uint256 minOut = minEthOut(token, amount);
        IERC20(token).forceApprove(address(router), amount);
        ethOut = router.swapExactIn(r.hops, amount, minOut, buyback, block.timestamp);
        emit Converted(token, amount, ethOut);
    }

    /// Forward ETH fees held here to the Buyback.
    function forwardEth() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert ZeroAmount();
        (bool ok,) = buyback.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit EthForwarded(amount);
    }
}

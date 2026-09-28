// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolConfig} from "../core/ProtocolConfig.sol";
import {AssetRegistry} from "../core/AssetRegistry.sol";
import {FathomHookBase} from "./FathomHookBase.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title StockHook — oracle-guarded v4 pools for AssetRegistry assets (Stock Tokens / RWAs).
/// Anyone may create a pool, but only for an enabled registry asset paired with an enabled
/// registry quote (USDG, native ETH = address(0), WETH). Fee comes from `registry.riskParams`
/// (open / closed / stale) and is split LP / protocol exactly like DammHook. After every swap the
/// pool price must lie inside the oracle band (±maxDevBps around asset/quote from Chainlink); a
/// swap that ends outside the band is allowed only if it moved the price strictly closer to the
/// oracle price (so arbitrageurs can pull a drifted pool back). While the oracle is stale ONLY
/// such toward-oracle swaps are allowed.
contract StockHook is FathomHookBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Pool {
        address asset;
        bool assetIs0;
        uint8 dec0;
        uint8 dec1;
        address quote;
    }

    struct Oracle {
        uint256 priceE18; // 1 whole asset in whole quote units, 18 dec
        uint160 sqrtPriceX96; // oracle price as a pool sqrt price
        uint160 lower;
        uint160 upper;
        uint16 feeBps;
        bool open;
        bool stale;
    }

    AssetRegistry public immutable registry;
    mapping(PoolId => Pool) public pools;

    bytes32 internal constant T_PRE = keccak256("fathom.stock.pre");
    bytes32 internal constant T_ORACLE = keccak256("fathom.stock.oracle");
    bytes32 internal constant T_LOWER = keccak256("fathom.stock.lower");
    bytes32 internal constant T_UPPER = keccak256("fathom.stock.upper");
    bytes32 internal constant T_PRICE = keccak256("fathom.stock.price");
    bytes32 internal constant T_FLAGS = keccak256("fathom.stock.flags");

    event StockPoolCreated(PoolId indexed id, address indexed asset, address quote);
    event StockSwap(
        PoolId indexed id, uint24 totalFeePips, uint256 protocolFee, uint256 oraclePriceE18, bool marketOpen, bool stale
    );

    error NotRegisteredPair();
    error UnknownPool();
    error PriceOutOfBand();
    error StaleAwayFromOracle();

    constructor(IPoolManager pm, ProtocolConfig config_, AssetRegistry registry_) FathomHookBase(pm, config_) {
        registry = registry_;
    }

    /// Permissionless for registered asset/quote pairs. `sqrtPriceX96 == 0` → start at the oracle
    /// price; otherwise it must lie inside the current oracle band.
    function createPool(PoolKey calldata key, uint160 sqrtPriceX96) external returns (PoolId id, int24 tick) {
        _checkKey(key);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        Pool memory p;
        if (registry.isAsset(c0) && registry.isQuote(c1)) {
            (p.asset, p.quote, p.assetIs0) = (c0, c1, true);
        } else if (registry.isAsset(c1) && registry.isQuote(c0)) {
            (p.asset, p.quote) = (c1, c0);
        } else {
            revert NotRegisteredPair();
        }
        p.dec0 = _decimals(c0);
        p.dec1 = _decimals(c1);

        Oracle memory o = _oracle(p);
        if (sqrtPriceX96 == 0) sqrtPriceX96 = o.sqrtPriceX96;
        else if (sqrtPriceX96 < o.lower || sqrtPriceX96 > o.upper) revert PriceOutOfBand();

        id = key.toId();
        pools[id] = p;
        tick = poolManager.initialize(key, sqrtPriceX96); // reverts if already initialized
        emit StockPoolCreated(id, p.asset, p.quote);
    }

    // ---------------------------------------------------------------- views

    /// Current oracle band of `id` as pool sqrt prices.
    function bandSqrtPrices(PoolId id) external view returns (uint160 lower, uint160 upper) {
        Oracle memory o = _oracle(_pool(id));
        return (o.lower, o.upper);
    }

    /// Oracle price as a pool sqrt price, plus fee state (LP part and total, pips).
    function oracleState(PoolId id)
        external
        view
        returns (uint160 oracleSqrtPriceX96, uint256 priceE18, uint24 lpFeePips, uint24 totalFeePips, bool open, bool stale)
    {
        Oracle memory o = _oracle(_pool(id));
        totalFeePips = uint24(uint256(o.feeBps) * 100);
        (lpFeePips,) = _split(totalFeePips);
        return (o.sqrtPriceX96, o.priceE18, lpFeePips, totalFeePips, o.open, o.stale);
    }

    // ---------------------------------------------------------------- hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _notPaused();
        PoolId id = key.toId();
        Oracle memory o = _oracle(_pool(id));
        (uint160 pre,,,) = poolManager.getSlot0(id);
        _tstore(T_PRE, pre);
        _tstore(T_ORACLE, o.sqrtPriceX96);
        _tstore(T_LOWER, o.lower);
        _tstore(T_UPPER, o.upper);
        _tstore(T_PRICE, o.priceE18);
        _tstore(T_FLAGS, (o.open ? 1 : 0) | (o.stale ? 2 : 0));
        return _chargeBefore(key, params, uint256(o.feeBps) * 100);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        (int128 hookDelta, uint24 totalPips, uint256 fee,) = _chargeAfter(key, params, delta);

        (uint160 post,,,) = poolManager.getSlot0(id);
        uint256 flags = _tload(T_FLAGS);
        bool stale = flags & 2 != 0;
        bool outside = post < _tload(T_LOWER) || post > _tload(T_UPPER);
        if (outside || stale) {
            uint256 o = _tload(T_ORACLE);
            uint256 pre = _tload(T_PRE);
            uint256 dPost = post > o ? post - o : o - post;
            uint256 dPre = pre > o ? pre - o : o - pre;
            if (dPost >= dPre) {
                if (outside) revert PriceOutOfBand();
                revert StaleAwayFromOracle();
            }
        }
        emit StockSwap(id, totalPips, fee, _tload(T_PRICE), flags & 1 != 0, stale);
        return (this.afterSwap.selector, hookDelta);
    }

    // ---------------------------------------------------------------- oracle math

    function _pool(PoolId id) internal view returns (Pool memory p) {
        p = pools[id];
        if (p.asset == address(0)) revert UnknownPool();
    }

    function _oracle(Pool memory p) internal view returns (Oracle memory o) {
        uint16 maxDev;
        (o.feeBps, maxDev, o.stale, o.open) = registry.riskParams(p.asset);
        (uint256 aUsd,) = registry.assetPrice(p.asset);
        (uint256 qUsd, bool qStale) = registry.quotePrice(p.quote);
        if (qStale && !o.stale) {
            AssetRegistry.Asset memory a = registry.asset(p.asset);
            (o.feeBps, maxDev, o.stale) = (a.staleFeeBps, a.closedMaxDevBps, true);
        }
        if (maxDev >= BPS) maxDev = uint16(BPS - 1);
        o.priceE18 = aUsd * 1e18 / qUsd;
        // raw token1 per raw token0 = num / den
        (uint256 num, uint256 den) = p.assetIs0
            ? (aUsd * 10 ** p.dec1, qUsd * 10 ** p.dec0)
            : (qUsd * 10 ** p.dec1, aUsd * 10 ** p.dec0);
        o.sqrtPriceX96 = _sqrtX96(num, den);
        o.lower = _sqrtX96(num * (BPS - maxDev), den * BPS);
        o.upper = _sqrtX96(num * (BPS + maxDev), den * BPS);
    }

    /// sqrt(num/den) · 2^96, keeping precision for both tiny and large prices.
    function _sqrtX96(uint256 num, uint256 den) internal pure returns (uint160) {
        if (num / den < 2 ** 64) return uint160(Math.sqrt(Math.mulDiv(num, 2 ** 192, den)));
        return uint160(Math.sqrt(Math.mulDiv(num, 2 ** 96, den)) << 48);
    }

    function _decimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18;
        return IERC20Decimals(token).decimals();
    }
}

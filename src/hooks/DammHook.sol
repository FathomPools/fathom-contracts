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
import {ProtocolConfig} from "../core/ProtocolConfig.sol";
import {FathomHookBase} from "./FathomHookBase.sol";

/// @title DammHook — permissionless dynamic-fee v4 pools (Meteora DAMM v2 style).
/// Fee = base fee (creator-picked, 5–100 bps) or the anti-snipe schedule (start ≤ 5000 bps, linear
/// decay to base over ≤ 3600 s) + a volatility surcharge `variableFeeControl · vol² / 1e5` pips,
/// where `vol` accumulates |tick movement| per swap and decays linearly to zero over
/// `VOL_DECAY_SECONDS`. Total is capped at 500 bps outside the snipe window.
/// Create pools only via `createPool` (key.fee must be the DYNAMIC_FEE_FLAG, key.hooks this hook).
contract DammHook is FathomHookBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct PoolParams {
        uint16 baseFeeBps; // 5–100
        uint16 snipeStartFeeBps; // base..5000, used only when snipeSeconds > 0
        uint32 snipeSeconds; // 0 (off) – 3600
        uint32 variableFeeControl; // 0 disables the volatility surcharge; 10_000 ≈ 10 bps at 100 ticks
    }

    struct Pool {
        uint16 baseFeeBps;
        uint16 snipeStartFeeBps;
        uint32 snipeSeconds;
        uint32 variableFeeControl;
        uint40 createdAt;
        int24 lastTick;
        uint32 vol; // decaying |tick movement| accumulator
        uint40 lastUpdate;
    }

    uint16 public constant MIN_BASE_FEE_BPS = 5;
    uint16 public constant MAX_BASE_FEE_BPS = 100;
    uint16 public constant MAX_SNIPE_FEE_BPS = 5000;
    uint32 public constant MAX_SNIPE_SECONDS = 3600;
    uint16 public constant MAX_FEE_BPS = 500;
    uint32 public constant VOL_DECAY_SECONDS = 600;
    uint256 internal constant VFC_SCALE = 1e5;

    mapping(PoolId => Pool) public pools;

    event DammPoolCreated(
        PoolId indexed id,
        Currency currency0,
        Currency currency1,
        int24 tickSpacing,
        uint16 baseFeeBps,
        uint16 snipeStartFeeBps,
        uint32 snipeSeconds,
        address creator
    );
    event DammSwapFee(PoolId indexed id, uint24 totalFeePips, uint256 protocolFee, Currency feeCurrency);

    error BadParams();

    constructor(IPoolManager pm, ProtocolConfig config_) FathomHookBase(pm, config_) {}

    /// Permissionless: validate `p`, store it and initialize the v4 pool at `sqrtPriceX96`.
    function createPool(PoolKey calldata key, uint160 sqrtPriceX96, PoolParams calldata p)
        external
        returns (PoolId id, int24 tick)
    {
        _checkKey(key);
        if (p.baseFeeBps < MIN_BASE_FEE_BPS || p.baseFeeBps > MAX_BASE_FEE_BPS) revert BadParams();
        if (p.snipeSeconds > MAX_SNIPE_SECONDS) revert BadParams();
        uint16 snipeStart;
        if (p.snipeSeconds > 0) {
            if (p.snipeStartFeeBps < p.baseFeeBps || p.snipeStartFeeBps > MAX_SNIPE_FEE_BPS) revert BadParams();
            snipeStart = p.snipeStartFeeBps;
        }
        id = key.toId();
        tick = poolManager.initialize(key, sqrtPriceX96); // reverts if already initialized
        pools[id] = Pool({
            baseFeeBps: p.baseFeeBps,
            snipeStartFeeBps: snipeStart,
            snipeSeconds: p.snipeSeconds,
            variableFeeControl: p.variableFeeControl,
            createdAt: uint40(block.timestamp),
            lastTick: tick,
            vol: 0,
            lastUpdate: uint40(block.timestamp)
        });
        emit DammPoolCreated(
            id, key.currency0, key.currency1, key.tickSpacing, p.baseFeeBps, snipeStart, p.snipeSeconds, msg.sender
        );
    }

    // ---------------------------------------------------------------- fee math

    /// Current fee of `id`: LP part (dynamic LP fee) and total (LP + protocol), both in pips.
    function currentFee(PoolId id) external view returns (uint24 lpFeePips, uint24 totalFeePips) {
        totalFeePips = _totalFeePips(pools[id]);
        (lpFeePips,) = _split(totalFeePips);
    }

    function _decayedVol(Pool storage s) internal view returns (uint256) {
        uint256 dt = block.timestamp - s.lastUpdate;
        if (dt >= VOL_DECAY_SECONDS) return 0;
        return uint256(s.vol) * (VOL_DECAY_SECONDS - dt) / VOL_DECAY_SECONDS;
    }

    function _totalFeePips(Pool storage s) internal view returns (uint24) {
        if (s.createdAt == 0) return 0;
        uint256 sched = s.baseFeeBps;
        uint256 elapsed = block.timestamp - s.createdAt;
        if (elapsed < s.snipeSeconds) {
            sched = s.snipeStartFeeBps - (uint256(s.snipeStartFeeBps) - s.baseFeeBps) * elapsed / s.snipeSeconds;
        }
        uint256 v = _decayedVol(s);
        uint256 total = sched * 100 + uint256(s.variableFeeControl) * v * v / VFC_SCALE;
        uint256 cap = (sched > MAX_FEE_BPS ? sched : MAX_FEE_BPS) * 100;
        return uint24(total > cap ? cap : total);
    }

    // ---------------------------------------------------------------- hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _notPaused();
        return _chargeBefore(key, params, _totalFeePips(pools[key.toId()]));
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        (int128 hookDelta, uint24 totalPips, uint256 fee, Currency feeCurrency) = _chargeAfter(key, params, delta);

        // volatility accumulator: decay, then add this swap's |tick movement|
        Pool storage s = pools[id];
        (, int24 tick,,) = poolManager.getSlot0(id);
        int256 d = int256(tick) - int256(s.lastTick);
        uint256 v = _decayedVol(s) + uint256(d < 0 ? -d : d);
        s.vol = v > type(uint32).max ? type(uint32).max : uint32(v);
        s.lastTick = tick;
        s.lastUpdate = uint40(block.timestamp);

        emit DammSwapFee(id, totalPips, fee, feeCurrency);
        return (this.afterSwap.selector, hookDelta);
    }
}

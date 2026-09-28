// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {ProtocolConfig} from "../core/ProtocolConfig.sol";

/// Shared plumbing of the Fathom v4 hooks: pause gate, LP/protocol fee split and protocol-fee
/// collection. The protocol share is always charged on the swap INPUT currency: exact-input in
/// `beforeSwap` (specified delta), exact-output in `afterSwap` (unspecified delta). It is sent
/// straight to `config.feeCollector()` with `poolManager.take`; if the PoolManager does not hold
/// enough of that currency at that moment (the trader settles after the swap), the fee is minted
/// as an ERC-6909 claim to this hook instead and anyone can `sweep` it to the collector later.
/// Liquidity removal is never gated (no beforeRemoveLiquidity permission).
abstract contract FathomHookBase is BaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;

    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant BPS = 10_000;

    // transient slots (per swap; swaps on one hook never nest)
    bytes32 internal constant T_TOTAL_PIPS = keccak256("fathom.hook.totalPips");
    bytes32 internal constant T_PROTO_PIPS = keccak256("fathom.hook.protoPips");
    bytes32 internal constant T_PROTO_FEE = keccak256("fathom.hook.protoFee");

    ProtocolConfig public immutable config;

    event ProtocolFeeClaimMinted(Currency indexed currency, uint256 amount);
    event FeesSwept(Currency indexed currency, address indexed to, uint256 amount);

    error Paused();
    error NothingToSweep();
    error NotDynamicFee();
    error WrongHook();
    error OnlyViaCreatePool();

    constructor(IPoolManager pm, ProtocolConfig config_) BaseHook(pm) {
        config = config_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- gates

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != address(this)) revert OnlyViaCreatePool();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert NotDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _notPaused();
        return this.beforeAddLiquidity.selector;
    }

    function _notPaused() internal view {
        if (config.paused()) revert Paused();
    }

    function _checkKey(PoolKey calldata key) internal view {
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert NotDynamicFee();
    }

    // ---------------------------------------------------------------- fee split

    /// Split a total fee (pips) into the LP part (dynamic LP fee) and the protocol part (hook delta).
    function _split(uint256 totalPips) internal view returns (uint24 lpPips, uint24 protoPips) {
        protoPips = uint24(totalPips * config.protocolFeeShareBps() / BPS);
        lpPips = uint24(totalPips - protoPips);
    }

    /// Call from `_beforeSwap` once the total fee is known. Returns the hook return values.
    function _chargeBefore(PoolKey calldata key, SwapParams calldata params, uint256 totalPips)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint24 lpPips, uint24 protoPips) = _split(totalPips);
        uint256 fee;
        if (params.amountSpecified < 0 && protoPips > 0) {
            fee = uint256(-params.amountSpecified) * protoPips / PIPS;
            if (fee > 0) _collect(params.zeroForOne ? key.currency0 : key.currency1, fee);
        }
        _tstore(T_TOTAL_PIPS, totalPips);
        _tstore(T_PROTO_PIPS, protoPips);
        _tstore(T_PROTO_FEE, fee);
        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(SafeCast.toInt128(int256(fee)), 0),
            lpPips | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// Call from `_afterSwap`. Charges exact-output swaps on the input (unspecified) side.
    /// Returns (hookDeltaUnspecified, totalPips, protocolFee, feeCurrency).
    function _chargeAfter(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        returns (int128 hookDelta, uint24 totalPips, uint256 fee, Currency feeCurrency)
    {
        totalPips = uint24(_tload(T_TOTAL_PIPS));
        feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        if (params.amountSpecified < 0) return (0, totalPips, _tload(T_PROTO_FEE), feeCurrency);
        uint256 protoPips = _tload(T_PROTO_PIPS);
        int128 paid = params.zeroForOne ? delta.amount0() : delta.amount1();
        if (paid < 0 && protoPips > 0) {
            fee = uint256(uint128(-paid)) * protoPips / PIPS;
            if (fee > 0) _collect(feeCurrency, fee);
        }
        hookDelta = SafeCast.toInt128(int256(fee));
    }

    /// Credit `amount` of `c` owed to this hook by the swap to the fee collector.
    function _collect(Currency c, uint256 amount) internal {
        if (c.balanceOf(address(poolManager)) >= amount) {
            poolManager.take(c, config.feeCollector(), amount);
        } else {
            poolManager.mint(address(this), c.toId(), amount);
            emit ProtocolFeeClaimMinted(c, amount);
        }
    }

    // ---------------------------------------------------------------- sweep

    /// Permissionless: redeem this hook's ERC-6909 fee claims of `c` to the fee collector.
    function sweep(Currency c) external returns (uint256 amount) {
        amount = poolManager.balanceOf(address(this), c.toId());
        if (amount == 0) revert NothingToSweep();
        address to = config.feeCollector();
        poolManager.unlock(abi.encode(c, to, amount));
        emit FeesSwept(c, to, amount);
    }

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Currency c, address to, uint256 amount) = abi.decode(raw, (Currency, address, uint256));
        poolManager.burn(address(this), c.toId(), amount);
        poolManager.take(c, to, amount);
        return "";
    }

    // ---------------------------------------------------------------- transient

    function _tstore(bytes32 slot, uint256 v) internal {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    function _tload(bytes32 slot) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {DammHook} from "../hooks/DammHook.sol";
import {LaunchToken} from "./LaunchToken.sol";

/// One-transaction token launches on Fathom DAMM pools.
///
/// `launch` deploys a fixed-supply LaunchToken, creates its native-ETH DAMM pool through the DammHook
/// and seeds part of the supply into it, one-sided, all in the same transaction:
/// - currency0 is native ETH and currency1 the new token, so the pool price is tokens per ETH. The
///   pool starts at `startTick` and the seed is a single range from the lowest usable tick up to
///   `startTick`: at the start price it holds only the token, and it sells the token to buyers at
///   every higher token price. Nobody else can hold the token before the pool exists.
/// - Every launch has the DAMM anti-snipe window (`snipeSeconds` > 0, start fee above the base fee):
///   from the pool's first block the fee starts at `snipeStartFeeBps`, decays linearly to the base fee,
///   and the volatility surcharge applies on top. The hook takes its protocol share as on any DAMM
///   pool; the LP share accrues to the launch position.
/// - The rest of the supply (supply minus the tokens the seed actually used) goes to `creator`.
/// - The token is deployed with CREATE2 under a salt of (caller, launch count, block number), so its
///   address, and with it the pool id, is not known before the block the launch lands in. The
///   PoolManager accepts any address as a currency, so a predictable address would let anyone
///   initialize the pool first and block the launch. If that still happens (a same-block front-run),
///   the launch reverts with LaunchPools__PoolTaken and works again from the next block.
///
/// The launch position:
/// - Held by this contract in the PoolManager (owner = this contract, ticks [TICK_LOWER, startTick],
///   salt 0). It is locked for good: this contract only ever adds that liquidity once and pokes it
///   with a zero delta to collect fees. Nothing here removes liquidity, and there is no owner, no
///   admin function and no upgrade path.
/// - Its fees belong to the launch's `feeRecipient` (the creator at launch). Anyone can call
///   `collectFees`, which pays both currencies straight from the PoolManager to the fee recipient.
///   Only the current fee recipient can hand the right to another address (`setFeeRecipient`).
///   Collecting works while the protocol is paused (a zero-delta poke is not gated by the hook).
///
/// Buy at launch (optional): ETH sent with `launch` buys the token as the pool's first swap, in the
/// same unlock as the seed, so nobody can trade ahead of it. It pays the anti-snipe start fee like any
/// swap, but the launch position is the pool's only liquidity at that point, so the LP share of that
/// fee is all its own: it is collected right after the swap and paid back to the buyer with the
/// tokens. Only the hook's protocol share stays charged. LaunchVault uses this to buy for all its
/// depositors at one price.
contract LaunchPools is ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    struct LaunchParams {
        string name; // 1–64 bytes
        string symbol; // 1–16 bytes
        uint256 supply; // whole supply in wei (18 decimals), minted once
        uint256 seedAmount; // part of the supply seeded into the pool, 0 < seedAmount <= supply
        int24 startTick; // start price as a tick of tokens per ETH, a multiple of TICK_SPACING
        address creator; // receives the unseeded supply and the launch position's fees
        DammHook.PoolParams fees; // DAMM fee schedule; the anti-snipe window is required
    }

    struct Launch {
        address token;
        address feeRecipient;
        int24 startTick; // upper tick of the launch position
        uint128 liquidity; // liquidity of the launch position, never changes
        uint40 launchedAt;
    }

    int24 public constant TICK_SPACING = 60;
    /// Lowest usable tick at TICK_SPACING (TickMath.minUsableTick(60)): the lower end of every seed.
    int24 public constant TICK_LOWER = -887220;
    /// Highest start tick: TickMath.maxUsableTick(60).
    int24 public constant MAX_START_TICK = 887220;
    uint256 public constant MAX_SUPPLY = 1e33; // 10^15 whole tokens
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;

    IPoolManager public immutable poolManager;
    DammHook public immutable dammHook;

    mapping(PoolId => Launch) internal _launches;
    PoolId[] internal _ids;

    event Launched(
        PoolId indexed id,
        address indexed token,
        address indexed creator,
        address launcher,
        string name,
        string symbol,
        uint256 supply,
        uint256 seeded,
        int24 startTick,
        uint128 liquidity,
        uint256 ethSpent, // ETH the launch buy cost, net of the LP-fee payback
        uint256 bought
    );
    event FeesCollected(PoolId indexed id, address indexed to, uint256 amount0, uint256 amount1);
    event FeeRecipientSet(PoolId indexed id, address indexed recipient);

    error LaunchPools__BadName();
    error LaunchPools__BadSupply();
    error LaunchPools__BadSeed();
    error LaunchPools__BadTick();
    error LaunchPools__BadFees();
    error LaunchPools__ZeroAddress();
    error LaunchPools__PoolTaken();
    error LaunchPools__UnknownLaunch();
    error LaunchPools__NotFeeRecipient();
    error LaunchPools__NotPoolManager();
    error LaunchPools__NativeTransferFailed();

    constructor(IPoolManager pm, DammHook hook) {
        if (address(pm) == address(0) || address(hook) == address(0)) revert LaunchPools__ZeroAddress();
        poolManager = pm;
        dammHook = hook;
    }

    // ---------------------------------------------------------------- launch

    /// Deploy the token, create and seed its pool, and buy with `msg.value` (if any) as the first swap.
    /// The tokens bought and the ETH paid back (LP share of the launch fee, plus anything unspent) go to
    /// the caller; the unseeded supply goes to `p.creator`.
    function launch(LaunchParams calldata p)
        external
        payable
        nonReentrant
        returns (address token, PoolId id, uint256 bought)
    {
        (uint128 liquidity,) = preview(p);
        bytes32 salt = keccak256(abi.encode(msg.sender, _ids.length, block.number));
        token = address(new LaunchToken{salt: salt}(p.name, p.symbol, p.supply, address(this)));
        PoolKey memory key = poolKeyOf(token);
        id = key.toId();
        (uint160 taken,,,) = poolManager.getSlot0(id);
        if (taken != 0) revert LaunchPools__PoolTaken();
        dammHook.createPool(key, TickMath.getSqrtPriceAtTick(p.startTick), p.fees);

        uint256 seeded;
        uint256 ethPaid;
        (seeded, bought, ethPaid) = abi.decode(
            poolManager.unlock(abi.encode(true, abi.encode(key, p.startTick, liquidity, msg.value))),
            (uint256, uint256, uint256)
        );
        _launches[id] = Launch({
            token: token,
            feeRecipient: p.creator,
            startTick: p.startTick,
            liquidity: liquidity,
            launchedAt: uint40(block.timestamp)
        });
        _ids.push(id);

        // Still held here: supply - (seeded - bought).
        if (bought != 0) IERC20(token).safeTransfer(msg.sender, bought);
        if (p.supply != seeded) IERC20(token).safeTransfer(p.creator, p.supply - seeded);
        if (msg.value != ethPaid) _sendEth(msg.sender, msg.value - ethPaid);

        emit FeeRecipientSet(id, p.creator);
        emit Launched(
            id, token, p.creator, msg.sender, p.name, p.symbol, p.supply, seeded, p.startTick, liquidity, ethPaid, bought
        );
    }

    /// Check `p` exactly as `launch` does (reverts on the first problem) and return the launch
    /// position's liquidity and the token amount the seed will use (<= seedAmount, rounding dust stays
    /// with the creator).
    function preview(LaunchParams calldata p) public view returns (uint128 liquidity, uint256 seeded) {
        uint256 n = bytes(p.name).length;
        uint256 s = bytes(p.symbol).length;
        if (n == 0 || n > MAX_NAME_BYTES || s == 0 || s > MAX_SYMBOL_BYTES) revert LaunchPools__BadName();
        if (p.supply == 0 || p.supply > MAX_SUPPLY) revert LaunchPools__BadSupply();
        if (p.seedAmount == 0 || p.seedAmount > p.supply) revert LaunchPools__BadSeed();
        if (p.creator == address(0)) revert LaunchPools__ZeroAddress();
        if (p.startTick % TICK_SPACING != 0 || p.startTick <= TICK_LOWER || p.startTick > MAX_START_TICK) {
            revert LaunchPools__BadTick();
        }
        // The hook's own bounds, plus a mandatory anti-snipe window.
        DammHook.PoolParams calldata f = p.fees;
        DammHook h = dammHook;
        if (
            f.baseFeeBps < h.MIN_BASE_FEE_BPS() || f.baseFeeBps > h.MAX_BASE_FEE_BPS() || f.snipeSeconds == 0
                || f.snipeSeconds > h.MAX_SNIPE_SECONDS() || f.snipeStartFeeBps <= f.baseFeeBps
                || f.snipeStartFeeBps > h.MAX_SNIPE_FEE_BPS()
        ) revert LaunchPools__BadFees();

        uint160 lo = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 hi = TickMath.getSqrtPriceAtTick(p.startTick);
        uint256 l = FullMath.mulDiv(p.seedAmount, FixedPoint96.Q96, hi - lo);
        if (l == 0 || l > Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING)) revert LaunchPools__BadSeed();
        liquidity = SafeCast.toUint128(l);
        seeded = SqrtPriceMath.getAmount1Delta(lo, hi, liquidity, true);
    }

    // ---------------------------------------------------------------- launch position fees

    /// Permissionless: pay the launch position's accrued fees to its fee recipient.
    function collectFees(PoolId id) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Launch storage l = _launches[id];
        if (l.token == address(0)) revert LaunchPools__UnknownLaunch();
        address to = l.feeRecipient;
        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(false, abi.encode(poolKeyOf(l.token), l.startTick, to))), (uint256, uint256)
        );
        emit FeesCollected(id, to, amount0, amount1);
    }

    /// The current fee recipient hands the launch position's fees to `to`.
    function setFeeRecipient(PoolId id, address to) external {
        Launch storage l = _launches[id];
        if (l.token == address(0)) revert LaunchPools__UnknownLaunch();
        if (msg.sender != l.feeRecipient) revert LaunchPools__NotFeeRecipient();
        if (to == address(0)) revert LaunchPools__ZeroAddress();
        l.feeRecipient = to;
        emit FeeRecipientSet(id, to);
    }

    // ---------------------------------------------------------------- views

    /// The DAMM pool key of a launch token: native ETH / token, dynamic fee, TICK_SPACING, the hook.
    function poolKeyOf(address token) public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(dammHook))
        });
    }

    function getLaunch(PoolId id) external view returns (Launch memory) {
        return _launches[id];
    }

    function launchCount() external view returns (uint256) {
        return _ids.length;
    }

    /// Launches `[offset, offset + limit)` in launch order (clamped to the list).
    function getLaunches(uint256 offset, uint256 limit)
        external
        view
        returns (PoolId[] memory ids, Launch[] memory launches)
    {
        uint256 n = _ids.length;
        uint256 end = offset >= n ? offset : (limit > n - offset ? n : offset + limit);
        ids = new PoolId[](end - offset);
        launches = new Launch[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            ids[i - offset] = _ids[i];
            launches[i - offset] = _launches[_ids[i]];
        }
    }

    /// Fees the launch position has accrued and `collectFees` would pay now (ETH, token).
    function pendingFees(PoolId id) external view returns (uint256 amount0, uint256 amount1) {
        Launch storage l = _launches[id];
        if (l.token == address(0)) return (0, 0);
        (uint128 liq, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(id, address(this), TICK_LOWER, l.startTick, bytes32(0));
        (uint256 in0, uint256 in1) = poolManager.getFeeGrowthInside(id, TICK_LOWER, l.startTick);
        unchecked {
            amount0 = FullMath.mulDiv(in0 - last0, liq, FixedPoint128.Q128);
            amount1 = FullMath.mulDiv(in1 - last1, liq, FixedPoint128.Q128);
        }
    }

    // ---------------------------------------------------------------- PoolManager callback

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert LaunchPools__NotPoolManager();
        (bool isLaunch, bytes memory data) = abi.decode(raw, (bool, bytes));
        if (isLaunch) {
            (PoolKey memory key, int24 tickUpper, uint128 liquidity, uint256 buyEth) =
                abi.decode(data, (PoolKey, int24, uint128, uint256));
            return _seedAndBuy(key, tickUpper, liquidity, buyEth);
        }
        (PoolKey memory k, int24 upper, address to) = abi.decode(data, (PoolKey, int24, address));
        BalanceDelta f = _modify(k, upper, 0);
        uint256 a0 = uint128(f.amount0());
        uint256 a1 = uint128(f.amount1());
        if (a0 != 0) poolManager.take(k.currency0, to, a0);
        if (a1 != 0) poolManager.take(k.currency1, to, a1);
        return abi.encode(a0, a1);
    }

    /// Add the launch position, run the optional first buy, take back its LP fee, settle the net.
    function _seedAndBuy(PoolKey memory key, int24 tickUpper, uint128 liquidity, uint256 buyEth)
        internal
        returns (bytes memory)
    {
        BalanceDelta d = _modify(key, tickUpper, int256(uint256(liquidity)));
        uint256 seeded = uint128(-d.amount1());
        uint256 bought;
        uint256 ethPaid;
        if (buyEth != 0) {
            BalanceDelta s = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -SafeCast.toInt256(buyEth),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            // The launch position is the pool's only liquidity: the LP share of this swap's fee is all its own.
            BalanceDelta f = _modify(key, tickUpper, 0);
            bought = uint128(s.amount1()) + uint256(uint128(f.amount1()));
            ethPaid = uint128(-s.amount0()) - uint256(uint128(f.amount0()));
            if (ethPaid != 0) poolManager.settle{value: ethPaid}();
        }
        // The buy's tokens come out of the seed, so only the difference moves.
        uint256 owed = seeded - bought;
        if (owed != 0) {
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(poolManager), owed);
            poolManager.settle();
        }
        return abi.encode(seeded, bought, ethPaid);
    }

    function _modify(PoolKey memory key, int24 tickUpper, int256 liquidityDelta) internal returns (BalanceDelta d) {
        (d,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert LaunchPools__NativeTransferFailed();
    }
}

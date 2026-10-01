// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Buyback-and-burn of the Fathom protocol token, v2.
/// Holds ETH from the FeeCollector. Anyone may call `buyback()` at most once per block, optionally
/// adding their own ETH (any amount, emitted as `Received` so its source stays visible on-chain): it
/// spends up to `maxEthPerCall` on the protocol token through its native-ETH v4 pool, sends every
/// token bought straight to 0xdead and pays the caller a `callerRewardBps` reward on the ETH spent.
///
/// Price guard (the token has no Chainlink feed, so the floor comes from the pool itself):
/// - `referenceSqrtPriceX96` follows the pool price at a capped rate (`driftBpsPerHour`, at most
///   `maxDeviationBps` per update). Every `buyback()` catches it up first, and `poke()` does the
///   same on its own. With no time elapsed it cannot move, so a pump inside one block never shifts it.
/// - Only a token price above the band can hurt a buyer, so only that side is guarded: `buyback()`
///   reverts if the token is more than `maxDeviationBps` above the reference (front-run pump). A
///   cheaper token never blocks a buyback, however stale the reference is.
/// - The swap stops at the tighter of the reference band edge and `maxDeviationBps` above the price it
///   started from, so one call never pays more than either. Unspent ETH stays for later.
/// - The owner can retune the band and `resetReference()` after a large genuine repricing.
contract BuybackV2 is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 public constant MAX_CALLER_REWARD_BPS = 500;
    uint16 public constant MAX_DEVIATION_BPS = 2000;
    uint16 public constant MAX_DRIFT_BPS_PER_HOUR = 10_000;

    IPoolManager public immutable poolManager;
    PoolKey public poolKey; // currency0 = native ETH, currency1 = protocol token
    bytes public hookData;
    address public token;
    uint256 public maxEthPerCall;
    uint16 public callerRewardBps = 50;
    uint256 public lastBuybackBlock;
    uint256 public totalEthSpent;
    uint256 public totalBurned;

    uint16 public maxDeviationBps = 1000; // 10 %
    uint16 public driftBpsPerHour = 3000; // 30 % / hour
    uint160 public referenceSqrtPriceX96;
    uint40 public referenceUpdatedAt;

    event Configured(address indexed token, bytes32 indexed poolId, uint256 maxEthPerCall);
    event MaxEthPerCallSet(uint256 maxEthPerCall);
    event CallerRewardSet(uint16 bps);
    event Received(address indexed from, uint256 amount);
    event BoughtBack(uint256 ethIn, uint256 tokensBurned, address indexed caller, uint256 reward);
    event ReferenceUpdated(uint160 sqrtPriceX96);
    event PriceGuardSet(uint16 maxDeviationBps, uint16 driftBpsPerHour);

    error ZeroAddress();
    error AlreadyConfigured();
    error NotConfigured();
    error BadKey();
    error BadReward();
    error OncePerBlock();
    error NothingToSpend();
    error NotPoolManager();
    error NativeTransferFailed();
    error BadGuard();
    /// The token is more than `maxDeviationBps` above the reference (sqrt price below `bandEdge`).
    error PriceAboveBand(uint160 sqrtPriceX96, uint160 bandEdge);

    constructor(IPoolManager pm, address owner_, uint256 maxEthPerCall_) Ownable(owner_) {
        if (address(pm) == address(0)) revert ZeroAddress();
        poolManager = pm;
        maxEthPerCall = maxEthPerCall_;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------- admin

    /// One-shot: the ETH/protocol-token v4 pool used for buybacks.
    function configure(PoolKey calldata key, bytes calldata hookData_) external onlyOwner {
        if (token != address(0)) revert AlreadyConfigured();
        if (!key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert BadKey();
        poolKey = key;
        hookData = hookData_;
        token = Currency.unwrap(key.currency1);
        uint160 price = _poolSqrtPrice();
        if (price == 0) revert BadKey(); // pool not initialized
        _setReference(price);
        emit Configured(token, keccak256(abi.encode(key)), maxEthPerCall);
    }

    function setPriceGuard(uint16 maxDeviationBps_, uint16 driftBpsPerHour_) external onlyOwner {
        if (maxDeviationBps_ == 0 || maxDeviationBps_ > MAX_DEVIATION_BPS || driftBpsPerHour_ > MAX_DRIFT_BPS_PER_HOUR) {
            revert BadGuard();
        }
        maxDeviationBps = maxDeviationBps_;
        driftBpsPerHour = driftBpsPerHour_;
        emit PriceGuardSet(maxDeviationBps_, driftBpsPerHour_);
    }

    /// Snap the reference to the current pool price (after a large genuine repricing).
    function resetReference() external onlyOwner {
        if (token == address(0)) revert NotConfigured();
        _setReference(_poolSqrtPrice());
    }

    function setMaxEthPerCall(uint256 v) external onlyOwner {
        maxEthPerCall = v;
        emit MaxEthPerCallSet(v);
    }

    function setCallerRewardBps(uint16 bps) external onlyOwner {
        if (bps > MAX_CALLER_REWARD_BPS) revert BadReward();
        callerRewardBps = bps;
        emit CallerRewardSet(bps);
    }

    // ---------------------------------------------------------------- permissionless

    /// Spend up to min(balance incl. msg.value, maxEthPerCall) (minus the caller reward) buying the
    /// token and burn it. Reverts (refunding msg.value) if the token is above the reference band.
    function buyback() external payable nonReentrant returns (uint256 burned) {
        if (token == address(0)) revert NotConfigured();
        if (msg.value != 0) emit Received(msg.sender, msg.value);
        if (lastBuybackBlock == block.number) revert OncePerBlock();
        uint256 budget = address(this).balance;
        if (budget > maxEthPerCall) budget = maxEthPerCall;
        uint256 maxIn = budget - budget * callerRewardBps / 10_000;
        if (maxIn == 0) revert NothingToSpend();
        lastBuybackBlock = block.number;

        uint160 cur = _poolSqrtPrice();
        _drift(cur);
        uint256 dev = uint256(maxDeviationBps) * 1e14;
        (uint160 refEdge,) = _band(referenceSqrtPriceX96, dev);
        if (cur <= refEdge) revert PriceAboveBand(cur, refEdge);
        (uint160 curEdge,) = _band(cur, dev);
        uint160 limit = curEdge > refEdge ? curEdge : refEdge;

        uint256 spent;
        (burned, spent) = abi.decode(poolManager.unlock(abi.encode(maxIn, limit)), (uint256, uint256));
        if (spent == 0) revert NothingToSpend();
        // Same effective rate as a full fill (budget * bps), pro rata on a partial one; never more
        // than was held back for it (rounding could exceed it by 1 wei when the whole balance is spent).
        uint256 reward = spent * callerRewardBps / (10_000 - callerRewardBps);
        if (reward > budget - maxIn) reward = budget - maxIn;
        totalEthSpent += spent;
        totalBurned += burned;
        if (reward > 0) {
            (bool ok,) = msg.sender.call{value: reward}("");
            if (!ok) revert NativeTransferFailed();
        }
        emit BoughtBack(spent, burned, msg.sender, reward);
    }

    /// Permissionless: move the reference toward the pool price by the drift budget accrued since
    /// the last update.
    function poke() external {
        if (token == address(0)) revert NotConfigured();
        _drift(_poolSqrtPrice());
    }

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 ethIn, uint160 limit) = abi.decode(raw, (uint256, uint160));
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        BalanceDelta delta = poolManager.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: limit}), hookData
        );
        uint256 owed = uint256(uint128(-delta.amount0()));
        if (owed > 0) poolManager.settle{value: owed}();
        uint256 out = uint256(uint128(delta.amount1()));
        // burn = straight from the PoolManager to the dead address; nothing sits here
        if (out > 0) poolManager.take(poolKey.currency1, DEAD, out);
        return abi.encode(out, owed);
    }

    // ---------------------------------------------------------------- price guard internals

    function _poolSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
    }

    function _setReference(uint160 sqrtPriceX96) internal {
        referenceSqrtPriceX96 = sqrtPriceX96;
        referenceUpdatedAt = uint40(block.timestamp);
        emit ReferenceUpdated(sqrtPriceX96);
    }

    /// Clamp `cur` into the band the reference may move this update: driftBpsPerHour * elapsed,
    /// never more than maxDeviationBps. No elapsed time -> no movement.
    function _drift(uint160 cur) internal {
        uint256 elapsed = block.timestamp - referenceUpdatedAt;
        if (elapsed == 0) return;
        uint256 frac = uint256(driftBpsPerHour) * 1e14 * elapsed / 1 hours; // 1e18 = 100 %
        uint256 cap = uint256(maxDeviationBps) * 1e14;
        if (frac > cap) frac = cap;
        (uint160 low, uint160 high) = _band(referenceSqrtPriceX96, frac);
        _setReference(cur < low ? low : cur > high ? high : cur);
    }

    function _band(uint160 ref, uint256 frac) internal pure returns (uint160 low, uint160 high) {
        uint256 down = Math.sqrt((1e18 - frac) * 1e18);
        uint256 up = Math.sqrt((1e18 + frac) * 1e18);
        low = uint160(uint256(ref) * down / 1e18);
        uint256 h = uint256(ref) * up / 1e18;
        high = h > TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE : uint160(h);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDlmmPair} from "../interfaces/IDlmmPair.sol";
import {ProtocolConfig} from "../core/ProtocolConfig.sol";
import {BinMath} from "../libraries/BinMath.sol";
import {BinTree} from "../libraries/BinTree.sol";

/// Fee parameters copied into a pair at creation (Liquidity Book v2.1 semantics).
/// baseFee      = baseFactor * binStep * 1e10               (1e18 = 100 %)
/// variableFee  = (volatilityAccumulator * binStep)^2 * variableFeeControl / 100
struct DlmmFeeParams {
    uint16 baseFactor;
    uint16 filterPeriod;
    uint16 decayPeriod;
    uint16 reductionFactor; // bps
    uint24 variableFeeControl;
    uint24 maxVolatilityAccumulator;
}

/// Liquidity-Book-style discrete-bin AMM. Written from scratch after the LB v2.1 design.
///
/// - Bins hold (reserveX, reserveY); bins below the active id hold only Y, bins above only X.
///   Inside a bin the curve is constant-sum at price(id) = (1 + binStep/1e4)^(id - 2^23).
/// - Swaps and mints are "pay first": tokens are sent to the pair, then the call measures
///   balance - tracked reserves.
/// - Fees are charged on the input token and stay in the bin (LPs capture them on burn), except
///   `ProtocolConfig.protocolFeeShareBps` which is transferred to `feeCollector` on every swap.
/// - Liquidity shares are an internal ERC1155-like ledger per (bin, owner).
///
/// - Composition fee (LB v2.1): a mint into the active bin whose X:Y mix differs from the bin's
///   is part swap. That implied swap pays the current swap fee: it stays in the bin for existing
///   LPs, except the protocol share which goes to `feeCollector`. Without it, mint+burn of the
///   active bin would be a fee-free swap.
contract DlmmPair is IDlmmPair, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using BinTree for BinTree.Tree;

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant MAX_FEE = 0.1e18; // 10 %
    uint256 internal constant BPS = 10_000;

    struct Bin {
        uint128 reserveX;
        uint128 reserveY;
    }

    struct VolState {
        uint24 activeId;
        uint24 idReference;
        uint24 volatilityAccumulator;
        uint24 volatilityReference;
        uint40 lastUpdate;
    }

    ProtocolConfig public immutable config;
    address public immutable factory;
    address public immutable override tokenX;
    address public immutable override tokenY;
    uint16 public immutable override binStep;

    uint16 public immutable baseFactor;
    uint16 public immutable filterPeriod;
    uint16 public immutable decayPeriod;
    uint16 public immutable reductionFactor;
    uint24 public immutable variableFeeControl;
    uint24 public immutable maxVolatilityAccumulator;

    VolState internal _state;
    uint128 internal _reserveX;
    uint128 internal _reserveY;
    mapping(uint24 => Bin) internal _bins;
    BinTree.Tree internal _tree;

    mapping(uint256 => mapping(address => uint256)) internal _balances;
    mapping(uint256 => uint256) internal _totalSupplies;
    mapping(address => mapping(address => bool)) internal _approvals;

    event ApprovalForAll(address indexed owner, address indexed spender, bool approved);
    event CompositionFees(
        address indexed sender, uint24 id, uint256 feeX, uint256 feeY, uint256 protocolFeeX, uint256 protocolFeeY
    );

    error DlmmPair__Paused();
    error DlmmPair__ZeroAddress();
    error DlmmPair__InvalidLength();
    error DlmmPair__InvalidId();
    error DlmmPair__DistributionOverflow();
    error DlmmPair__CompositionFlawed(uint24 id);
    error DlmmPair__ZeroShares(uint24 id);
    error DlmmPair__InsufficientAmountIn();
    error DlmmPair__InsufficientAmountOut();
    error DlmmPair__OutOfLiquidity();
    error DlmmPair__NotApproved();
    error DlmmPair__InsufficientShares(uint24 id);

    modifier notPaused() {
        if (config.paused()) revert DlmmPair__Paused();
        _;
    }

    constructor(
        ProtocolConfig config_,
        address tokenX_,
        address tokenY_,
        uint16 binStep_,
        uint24 activeId_,
        DlmmFeeParams memory p
    ) {
        config = config_;
        factory = msg.sender;
        tokenX = tokenX_;
        tokenY = tokenY_;
        binStep = binStep_;
        baseFactor = p.baseFactor;
        filterPeriod = p.filterPeriod;
        decayPeriod = p.decayPeriod;
        reductionFactor = p.reductionFactor;
        variableFeeControl = p.variableFeeControl;
        maxVolatilityAccumulator = p.maxVolatilityAccumulator;

        BinMath.getPriceFromId(activeId_, binStep_); // validates the id is in the priceable range
        _state = VolState({
            activeId: activeId_,
            idReference: activeId_,
            volatilityAccumulator: 0,
            volatilityReference: 0,
            lastUpdate: uint40(block.timestamp)
        });
    }

    // ------------------------------------------------------------------ views

    function getActiveId() external view returns (uint24) {
        return _state.activeId;
    }

    function getBin(uint24 id) external view returns (uint128 reserveX, uint128 reserveY) {
        Bin memory b = _bins[id];
        return (b.reserveX, b.reserveY);
    }

    function getReserves() external view returns (uint128 reserveX, uint128 reserveY) {
        return (_reserveX, _reserveY);
    }

    function getPriceFromId(uint24 id) external view returns (uint256) {
        return BinMath.getPriceFromId(id, binStep);
    }

    function getVolatilityState()
        external
        view
        returns (uint24 activeId, uint24 idReference, uint24 volatilityAccumulator, uint24 volatilityReference, uint40 lastUpdate)
    {
        VolState memory s = _state;
        return (s.activeId, s.idReference, s.volatilityAccumulator, s.volatilityReference, s.lastUpdate);
    }

    /// Total fee rate (1e18 = 100 %) for a given volatility accumulator.
    function getFeeRate(uint24 volatilityAccumulator) external view returns (uint256) {
        return _feeRate(volatilityAccumulator);
    }

    /// Next bin holding liquidity in the swap direction (swapForY walks down, otherwise up).
    function getNextNonEmptyBin(bool swapForY, uint24 id) external view returns (uint24 nextId, bool found) {
        return swapForY ? _tree.findLower(id) : _tree.findHigher(id);
    }

    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return _balances[id][owner];
    }

    function totalSupply(uint256 id) external view returns (uint256) {
        return _totalSupplies[id];
    }

    function isApprovedForAll(address owner, address spender) external view returns (bool) {
        return _approvals[owner][spender];
    }

    function getSwapOut(uint128 amountIn, bool swapForY)
        external
        view
        returns (uint128 amountInLeft, uint128 amountOut, uint128 fee)
    {
        VolState memory s = _state;
        _updateReferences(s);
        uint16 share = config.protocolFeeShareBps();
        uint24 id = s.activeId;
        uint256 left = amountIn;
        uint256 out;
        uint256 fees;

        while (true) {
            Bin memory bin = _bins[id];
            if ((swapForY ? bin.reserveY : bin.reserveX) != 0) {
                (uint256 inWithFees, uint256 o, uint256 f,) = _swapInBin(s, id, bin, left, swapForY, share);
                left -= inWithFees;
                out += o;
                fees += f;
            }
            if (left == 0) break;
            (uint24 next, bool found) = swapForY ? _tree.findLower(id) : _tree.findHigher(id);
            if (!found) break;
            id = next;
        }
        return (left.toUint128(), out.toUint128(), fees.toUint128());
    }

    // ------------------------------------------------------------------ swap

    function swap(bool swapForY, address to) external nonReentrant notPaused returns (uint256 amountOut) {
        if (to == address(0)) revert DlmmPair__ZeroAddress();
        uint256 amountIn = swapForY
            ? IERC20(tokenX).balanceOf(address(this)) - _reserveX
            : IERC20(tokenY).balanceOf(address(this)) - _reserveY;
        if (amountIn == 0) revert DlmmPair__InsufficientAmountIn();

        VolState memory s = _state;
        _updateReferences(s);
        uint16 share = config.protocolFeeShareBps();
        uint24 id = s.activeId;
        uint256 left = amountIn;
        uint256 totalFee;
        uint256 protocolFee;

        while (true) {
            Bin memory bin = _bins[id];
            if ((swapForY ? bin.reserveY : bin.reserveX) != 0) {
                (uint256 inWithFees, uint256 o, uint256 f, uint256 pf) = _swapInBin(s, id, bin, left, swapForY, share);
                if (swapForY) {
                    bin.reserveX += (inWithFees - pf).toUint128();
                    bin.reserveY -= uint128(o);
                } else {
                    bin.reserveY += (inWithFees - pf).toUint128();
                    bin.reserveX -= uint128(o);
                }
                _bins[id] = bin;
                left -= inWithFees;
                amountOut += o;
                totalFee += f;
                protocolFee += pf;
            }
            if (left == 0) break;
            (uint24 next, bool found) = swapForY ? _tree.findLower(id) : _tree.findHigher(id);
            if (!found) revert DlmmPair__OutOfLiquidity();
            id = next;
        }
        if (amountOut == 0) revert DlmmPair__InsufficientAmountOut();

        s.activeId = id;
        _state = s;

        (address tokenIn, address tokenOut) = swapForY ? (tokenX, tokenY) : (tokenY, tokenX);
        if (swapForY) {
            _reserveX += (amountIn - protocolFee).toUint128();
            _reserveY -= amountOut.toUint128();
        } else {
            _reserveY += (amountIn - protocolFee).toUint128();
            _reserveX -= amountOut.toUint128();
        }

        IERC20(tokenOut).safeTransfer(to, amountOut);
        if (protocolFee != 0) IERC20(tokenIn).safeTransfer(config.feeCollector(), protocolFee);

        emit Swap(msg.sender, to, id, swapForY, amountIn, amountOut, totalFee, protocolFee);
    }

    // ------------------------------------------------------------------ liquidity

    /// Deposit tokens already sent to the pair. `distributionX/Y[i]` is the 1e18-scaled share of
    /// the received X/Y put into `ids[i]`. Unused tokens are refunded to `msg.sender`.
    function mint(
        address to,
        uint256[] calldata ids,
        uint256[] calldata distributionX,
        uint256[] calldata distributionY
    )
        external
        nonReentrant
        notPaused
        returns (uint256 amountXAdded, uint256 amountYAdded, uint256[] memory liquidityMinted)
    {
        uint256 n = ids.length;
        if (n == 0 || distributionX.length != n || distributionY.length != n) revert DlmmPair__InvalidLength();
        if (to == address(0)) revert DlmmPair__ZeroAddress();

        uint256 receivedX = IERC20(tokenX).balanceOf(address(this)) - _reserveX;
        uint256 receivedY = IERC20(tokenY).balanceOf(address(this)) - _reserveY;
        uint24 activeId = _state.activeId;

        liquidityMinted = new uint256[](n);
        uint256[] memory amountsX = new uint256[](n);
        uint256[] memory amountsY = new uint256[](n);
        uint256 sumDX;
        uint256 sumDY;
        uint256 protocolFeeX;
        uint256 protocolFeeY;

        for (uint256 i; i < n; ++i) {
            if (ids[i] > type(uint24).max) revert DlmmPair__InvalidId();
            uint24 id = uint24(ids[i]);
            sumDX += distributionX[i];
            sumDY += distributionY[i];
            uint256 x = receivedX * distributionX[i] / PRECISION;
            uint256 y = receivedY * distributionY[i] / PRECISION;
            if ((id > activeId && y != 0) || (id < activeId && x != 0)) revert DlmmPair__CompositionFlawed(id);

            uint256 price = BinMath.getPriceFromId(id, binStep);
            Bin memory bin = _bins[id];
            uint256 supply = _totalSupplies[id];
            uint256 liquidity = BinMath.getLiquidity(x, y, price);
            uint256 shares = supply == 0
                ? liquidity
                : Math.mulDiv(liquidity, supply, BinMath.getLiquidity(bin.reserveX, bin.reserveY, price));
            uint256 pfX;
            uint256 pfY;
            if (id == activeId && supply != 0 && shares != 0) {
                (shares, pfX, pfY) = _compositionFee(id, bin, supply, shares, x, y, price);
                protocolFeeX += pfX;
                protocolFeeY += pfY;
            }
            if (shares == 0) revert DlmmPair__ZeroShares(id);

            if (supply == 0) _tree.add(id);
            bin.reserveX += (x - pfX).toUint128();
            bin.reserveY += (y - pfY).toUint128();
            _bins[id] = bin;
            _totalSupplies[id] = supply + shares;
            _balances[id][to] += shares;

            liquidityMinted[i] = shares;
            amountsX[i] = x;
            amountsY[i] = y;
            amountXAdded += x;
            amountYAdded += y;
        }
        if (sumDX > PRECISION || sumDY > PRECISION) revert DlmmPair__DistributionOverflow();

        _reserveX += (amountXAdded - protocolFeeX).toUint128();
        _reserveY += (amountYAdded - protocolFeeY).toUint128();

        if (protocolFeeX != 0) IERC20(tokenX).safeTransfer(config.feeCollector(), protocolFeeX);
        if (protocolFeeY != 0) IERC20(tokenY).safeTransfer(config.feeCollector(), protocolFeeY);
        if (receivedX > amountXAdded) IERC20(tokenX).safeTransfer(msg.sender, receivedX - amountXAdded);
        if (receivedY > amountYAdded) IERC20(tokenY).safeTransfer(msg.sender, receivedY - amountYAdded);

        emit DepositedToBins(msg.sender, to, ids, amountsX, amountsY);
    }

    /// Burn `amounts[i]` shares of `from` in `ids[i]` and send the underlying to `to`.
    /// Never checks pause: withdrawals must always work.
    function burn(address from, address to, uint256[] calldata ids, uint256[] calldata amounts)
        external
        nonReentrant
        returns (uint256 amountX, uint256 amountY)
    {
        uint256 n = ids.length;
        if (n == 0 || amounts.length != n) revert DlmmPair__InvalidLength();
        if (to == address(0)) revert DlmmPair__ZeroAddress();
        if (msg.sender != from && !_approvals[from][msg.sender]) revert DlmmPair__NotApproved();

        uint256[] memory amountsX = new uint256[](n);
        uint256[] memory amountsY = new uint256[](n);

        for (uint256 i; i < n; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            if (ids[i] > type(uint24).max) revert DlmmPair__InvalidId();
            uint24 id = uint24(ids[i]);

            uint256 bal = _balances[id][from];
            if (amount > bal) revert DlmmPair__InsufficientShares(id);
            uint256 supply = _totalSupplies[id];
            Bin memory bin = _bins[id];

            uint256 x = Math.mulDiv(amount, bin.reserveX, supply);
            uint256 y = Math.mulDiv(amount, bin.reserveY, supply);
            bin.reserveX -= uint128(x);
            bin.reserveY -= uint128(y);
            _bins[id] = bin;
            _balances[id][from] = bal - amount;
            _totalSupplies[id] = supply - amount;
            if (supply == amount) _tree.remove(id);

            amountsX[i] = x;
            amountsY[i] = y;
            amountX += x;
            amountY += y;
        }

        _reserveX -= amountX.toUint128();
        _reserveY -= amountY.toUint128();
        if (amountX != 0) IERC20(tokenX).safeTransfer(to, amountX);
        if (amountY != 0) IERC20(tokenY).safeTransfer(to, amountY);

        emit WithdrawnFromBins(msg.sender, to, ids, amountsX, amountsY);
    }

    function approveForAll(address spender, bool approved) external {
        _approvals[msg.sender][spender] = approved;
        emit ApprovalForAll(msg.sender, spender, approved);
    }

    // ------------------------------------------------------------------ internals

    /// Composition fee for a mint of (x, y) into the active bin (LB v2.1 `getCompositionFees`).
    /// If burning the fresh `shares` right away would return more of one token than was put in,
    /// the surplus was bought with the other token: that part pays the swap fee. Returns the
    /// shares re-priced on the fee-less deposit and the protocol share of the fee per token.
    function _compositionFee(
        uint24 id,
        Bin memory bin,
        uint256 supply,
        uint256 shares,
        uint256 x,
        uint256 y,
        uint256 price
    ) internal returns (uint256 newShares, uint256 pfX, uint256 pfY) {
        uint256 total = supply + shares;
        uint256 recvX = Math.mulDiv(uint256(bin.reserveX) + x, shares, total);
        uint256 recvY = Math.mulDiv(uint256(bin.reserveY) + y, shares, total);

        VolState memory s = _state;
        _updateReferences(s);
        _updateVolatilityAccumulator(s, id);
        uint256 feeRate = _feeRate(s.volatilityAccumulator);

        uint256 feeX;
        uint256 feeY;
        if (recvX > x && y > recvY) feeY = _compositionFeeOn(y - recvY, feeRate);
        else if (recvY > y && x > recvX) feeX = _compositionFeeOn(x - recvX, feeRate);
        else return (shares, 0, 0);

        uint16 share = config.protocolFeeShareBps();
        pfX = feeX * share / BPS;
        pfY = feeY * share / BPS;
        uint256 userLiquidity = BinMath.getLiquidity(x - feeX, y - feeY, price);
        uint256 binLiquidity =
            BinMath.getLiquidity(uint256(bin.reserveX) + feeX - pfX, uint256(bin.reserveY) + feeY - pfY, price);
        newShares = Math.mulDiv(userLiquidity, supply, binLiquidity);
        emit CompositionFees(msg.sender, id, feeX, feeY, pfX, pfY);
    }

    /// LB `getCompositionFee`: amount * fee * (1 + fee), rounded up.
    function _compositionFeeOn(uint256 amountWithFees, uint256 feeRate) internal pure returns (uint256) {
        return Math.mulDiv(amountWithFees, feeRate * (feeRate + PRECISION), PRECISION * PRECISION, Math.Rounding.Ceil);
    }

    /// One bin step of a swap. Returns input consumed (incl. fees), output, total fee and the
    /// protocol part of the fee. Mutates `s` (volatility accumulator).
    function _swapInBin(VolState memory s, uint24 id, Bin memory bin, uint256 amountLeft, bool swapForY, uint16 share)
        internal
        view
        returns (uint256 inWithFees, uint256 out, uint256 fee, uint256 protocolFee)
    {
        _updateVolatilityAccumulator(s, id);
        uint256 feeRate = _feeRate(s.volatilityAccumulator);
        uint256 price = BinMath.getPriceFromId(id, binStep);

        uint256 binOut = swapForY ? bin.reserveY : bin.reserveX;
        uint256 maxIn = swapForY
            ? Math.mulDiv(binOut, BinMath.SCALE, price, Math.Rounding.Ceil)
            : Math.mulDiv(binOut, price, BinMath.SCALE, Math.Rounding.Ceil);
        uint256 maxFee = BinMath.feeOnAmount(maxIn, feeRate);

        if (amountLeft >= maxIn + maxFee) {
            inWithFees = maxIn + maxFee;
            fee = maxFee;
            out = binOut;
        } else {
            fee = BinMath.feeFromAmount(amountLeft, feeRate);
            uint256 inNoFee = amountLeft - fee;
            out = swapForY
                ? Math.mulDiv(inNoFee, price, BinMath.SCALE)
                : Math.mulDiv(inNoFee, BinMath.SCALE, price);
            if (out > binOut) out = binOut;
            inWithFees = amountLeft;
        }
        protocolFee = fee * share / BPS;
    }

    function _updateReferences(VolState memory s) internal view {
        uint256 dt = block.timestamp - s.lastUpdate;
        if (dt >= filterPeriod) {
            s.idReference = s.activeId;
            s.volatilityReference =
                dt < decayPeriod ? uint24(uint256(s.volatilityAccumulator) * reductionFactor / BPS) : 0;
        }
        s.lastUpdate = uint40(block.timestamp);
    }

    function _updateVolatilityAccumulator(VolState memory s, uint24 id) internal view {
        uint256 deltaId = id > s.idReference ? id - s.idReference : s.idReference - id;
        uint256 va = uint256(s.volatilityReference) + deltaId * BPS;
        if (va > maxVolatilityAccumulator) va = maxVolatilityAccumulator;
        s.volatilityAccumulator = uint24(va);
    }

    function _feeRate(uint24 volatilityAccumulator) internal view returns (uint256) {
        uint256 baseFee = uint256(baseFactor) * binStep * 1e10;
        uint256 prod = uint256(volatilityAccumulator) * binStep;
        uint256 variableFee = (prod * prod * variableFeeControl + 99) / 100;
        uint256 total = baseFee + variableFee;
        return total > MAX_FEE ? MAX_FEE : total;
    }
}

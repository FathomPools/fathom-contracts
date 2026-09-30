// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ProtocolConfig} from "../core/ProtocolConfig.sol";
import {DlmmPair} from "../dlmm/DlmmPair.sol";
import {BinMath} from "../libraries/BinMath.sol";

interface IDlmmVaultFactory {
    function config() external view returns (ProtocolConfig);
    function keeper() external view returns (address);
}

/// Auto-rebalancing DLMM vault. Holds one position over [lowerId, upperId] = activeId ± halfWidth in
/// a DLMM pair and issues ERC-20 shares for it.
///
/// - Deposits take both tokens in the vault's current X:Y mix and add them to every bin in the same
///   proportion the vault already holds, so a deposit is an exact slice of the vault. Share pricing
///   therefore needs no price at all: moving the pool price before a deposit cannot dilute holders.
/// - Withdrawals burn a slice of every bin plus the idle balance. They never check pause.
/// - Rebalancing (keeper or protocol owner) pulls the whole position and lays it out again around the
///   current active bin with the vault's shape. It never swaps: X goes to the active bin and above,
///   Y to the active bin and below, exactly what the pair would accept from any LP. It is allowed only
///   once the active bin has drifted more than halfWidth / 2 bins from the range centre, at most
///   once per MIN_REBALANCE_INTERVAL, and within `idSlippage` of the bin the keeper priced against.
/// - Fees earned by the bins compound into the position; the vault itself charges no fee.
contract DlmmVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant SHAPE_SPOT = 0;
    uint8 public constant SHAPE_CURVE = 1;
    uint8 public constant SHAPE_BIDASK = 2;
    uint24 public constant MAX_HALF_WIDTH = 50;
    uint256 public constant MIN_REBALANCE_INTERVAL = 5 minutes;
    /// Shares locked forever on the first deposit (inflation-attack guard).
    uint256 public constant MIN_SHARES = 1000;
    /// Bins whose deposit would mint fewer pair shares than this are skipped; the dust stays idle.
    uint256 internal constant MIN_BIN_SHARES = 1000;
    uint256 internal constant PRECISION = 1e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    DlmmPair public immutable pair;
    IERC20 public immutable tokenX;
    IERC20 public immutable tokenY;
    uint16 public immutable binStep;
    address public immutable factory;
    ProtocolConfig public immutable config;
    uint24 public immutable halfWidth;
    uint8 public immutable shape;
    uint8 internal immutable _decimals;

    uint24 public lowerId;
    uint24 public upperId;
    uint40 public lastRebalance;
    uint32 public rebalanceCount;

    event Deposit(address indexed sender, address indexed to, uint256 shares, uint256 amountX, uint256 amountY);
    event Withdraw(address indexed owner, address indexed to, uint256 shares, uint256 amountX, uint256 amountY);
    event Rebalance(
        address indexed caller,
        uint24 activeId,
        uint24 oldLowerId,
        uint24 oldUpperId,
        uint24 lowerId,
        uint24 upperId,
        uint256 amountX,
        uint256 amountY
    );

    error DlmmVault__Paused();
    error DlmmVault__Expired();
    error DlmmVault__ZeroAddress();
    error DlmmVault__ZeroAmount();
    error DlmmVault__ActiveIdSlippage(uint24 activeId);
    error DlmmVault__InsufficientShares(uint256 shares);
    error DlmmVault__AmountSlippage(uint256 amountX, uint256 amountY);
    error DlmmVault__Empty();
    error DlmmVault__NotKeeper();
    error DlmmVault__NotNeeded(uint24 activeId);
    error DlmmVault__TooSoon(uint256 readyAt);
    error DlmmVault__InvalidParams();

    constructor(DlmmPair pair_, uint24 halfWidth_, uint8 shape_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        if (halfWidth_ == 0 || halfWidth_ > MAX_HALF_WIDTH || shape_ > SHAPE_BIDASK) revert DlmmVault__InvalidParams();
        factory = msg.sender;
        config = IDlmmVaultFactory(msg.sender).config();
        pair = pair_;
        tokenX = IERC20(pair_.tokenX());
        tokenY = IERC20(pair_.tokenY());
        binStep = pair_.binStep();
        halfWidth = halfWidth_;
        shape = shape_;
        // Shares are denominated like Y: the first deposit mints its value in Y at the active price.
        uint8 d = 18;
        try IERC20Metadata(address(tokenY)).decimals() returns (uint8 v) {
            d = v;
        } catch {}
        _decimals = d;
        uint24 active = pair_.getActiveId();
        (lowerId, upperId) = _range(active);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    // ------------------------------------------------------------------ views

    /// Everything the vault owns: idle balances plus its share of every bin in range.
    function getTotalAmounts() public view returns (uint256 totalX, uint256 totalY) {
        (totalX, totalY) = _positionAmounts();
        totalX += tokenX.balanceOf(address(this));
        totalY += tokenY.balanceOf(address(this));
    }

    /// Per-bin amounts of the vault's position over [lowerId, upperId].
    function getBins() external view returns (uint24 lower, uint256[] memory amountsX, uint256[] memory amountsY) {
        lower = lowerId;
        (amountsX, amountsY,,) = _positionBins();
    }

    /// Whether the keeper may rebalance now (the time guard aside).
    function needsRebalance() public view returns (bool) {
        return _drift(pair.getActiveId()) > halfWidth / 2;
    }

    /// Shares and amounts a deposit of at most (amountXMax, amountYMax) would take right now.
    function previewDeposit(uint256 amountXMax, uint256 amountYMax)
        external
        view
        returns (uint256 shares, uint256 amountX, uint256 amountY)
    {
        uint256 supply = totalSupply();
        if (supply == 0) {
            shares = _firstShares(amountXMax, amountYMax);
            return (shares > MIN_SHARES ? shares - MIN_SHARES : 0, amountXMax, amountYMax);
        }
        (uint256 tx_, uint256 ty) = getTotalAmounts();
        return _sharesFor(amountXMax, amountYMax, tx_, ty, supply);
    }

    /// Amounts `shares` would withdraw right now.
    function previewWithdraw(uint256 shares) external view returns (uint256 amountX, uint256 amountY) {
        uint256 supply = totalSupply();
        if (supply == 0 || shares > supply) return (0, 0);
        amountX = tokenX.balanceOf(address(this)) * shares / supply;
        amountY = tokenY.balanceOf(address(this)) * shares / supply;
        uint24 lower = lowerId;
        uint256 n = uint256(upperId) - lower + 1;
        for (uint256 i; i < n; ++i) {
            uint24 id = uint24(lower + i);
            uint256 bs = pair.balanceOf(address(this), id) * shares / supply;
            if (bs == 0) continue;
            (uint128 rx, uint128 ry) = pair.getBin(id);
            uint256 ts = pair.totalSupply(id);
            amountX += Math.mulDiv(bs, rx, ts);
            amountY += Math.mulDiv(bs, ry, ts);
        }
    }

    // ------------------------------------------------------------------ deposit / withdraw

    /// Deposits up to (amountXMax, amountYMax). After the first deposit the vault takes both tokens
    /// in its current X:Y mix and returns nothing unused (only what it takes is pulled). The first
    /// deposit opens the range around the active bin and mints its value in Y at the active price.
    /// Reverts if the active bin is more than `idSlippage` from `activeIdDesired`, if fewer than
    /// `minShares` are minted, or after `deadline`.
    function deposit(
        uint256 amountXMax,
        uint256 amountYMax,
        uint256 minShares,
        address to,
        uint24 activeIdDesired,
        uint24 idSlippage,
        uint256 deadline
    ) external nonReentrant returns (uint256 shares, uint256 amountX, uint256 amountY) {
        if (block.timestamp > deadline) revert DlmmVault__Expired();
        if (config.paused()) revert DlmmVault__Paused();
        if (to == address(0)) revert DlmmVault__ZeroAddress();
        uint24 active = _checkActive(activeIdDesired, idSlippage);

        uint256 supply = totalSupply();
        if (supply == 0) {
            if (amountXMax == 0 && amountYMax == 0) revert DlmmVault__ZeroAmount();
            (amountX, amountY) = (amountXMax, amountYMax);
            shares = _firstShares(amountX, amountY);
            if (shares <= MIN_SHARES) revert DlmmVault__InsufficientShares(shares);
            shares -= MIN_SHARES;
            _pull(amountX, amountY);
            _mint(DEAD, MIN_SHARES);
            _deploy(active);
            lastRebalance = uint40(block.timestamp);
        } else {
            (uint256[] memory bx, uint256[] memory by, uint256 px, uint256 py) = _positionBins();
            uint256 tx_ = px + tokenX.balanceOf(address(this));
            uint256 ty = py + tokenY.balanceOf(address(this));
            if (tx_ == 0 && ty == 0) revert DlmmVault__Empty();
            (shares, amountX, amountY) = _sharesFor(amountXMax, amountYMax, tx_, ty, supply);
            if (shares == 0) revert DlmmVault__InsufficientShares(0);
            _pull(amountX, amountY);
            // The slice of the position goes into the bins in the vault's per-bin proportions; the
            // slice of the idle balance stays idle.
            uint256 dx = px == 0 ? 0 : Math.mulDiv(amountX, px, tx_);
            uint256 dy = py == 0 ? 0 : Math.mulDiv(amountY, py, ty);
            for (uint256 i; i < bx.length; ++i) {
                bx[i] = px == 0 ? 0 : Math.mulDiv(dx, bx[i], px);
                by[i] = py == 0 ? 0 : Math.mulDiv(dy, by[i], py);
            }
            _mintBins(active, lowerId, bx, by);
        }
        if (shares < minShares) revert DlmmVault__InsufficientShares(shares);
        _mint(to, shares);
        emit Deposit(msg.sender, to, shares, amountX, amountY);
    }

    /// Burns `shares` and sends their slice of every bin and of the idle balance to `to`.
    /// Works while the protocol is paused.
    function withdraw(uint256 shares, address to, uint256 amountXMin, uint256 amountYMin, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountX, uint256 amountY)
    {
        if (block.timestamp > deadline) revert DlmmVault__Expired();
        if (to == address(0)) revert DlmmVault__ZeroAddress();
        if (shares == 0) revert DlmmVault__ZeroAmount();
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);

        amountX = tokenX.balanceOf(address(this)) * shares / supply;
        amountY = tokenY.balanceOf(address(this)) * shares / supply;

        uint24 lower = lowerId;
        uint256 n = uint256(upperId) - lower + 1;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            uint24 id = uint24(lower + i);
            uint256 bs = pair.balanceOf(address(this), id) * shares / supply;
            if (bs == 0) continue;
            ids[k] = id;
            amounts[k] = bs;
            ++k;
        }
        if (k != 0) {
            assembly ("memory-safe") {
                mstore(ids, k)
                mstore(amounts, k)
            }
            (uint256 bx, uint256 by) = pair.burn(address(this), to, ids, amounts);
            if (amountX != 0) tokenX.safeTransfer(to, amountX);
            if (amountY != 0) tokenY.safeTransfer(to, amountY);
            amountX += bx;
            amountY += by;
        } else {
            if (amountX != 0) tokenX.safeTransfer(to, amountX);
            if (amountY != 0) tokenY.safeTransfer(to, amountY);
        }
        if (amountX < amountXMin || amountY < amountYMin) revert DlmmVault__AmountSlippage(amountX, amountY);
        emit Withdraw(msg.sender, to, shares, amountX, amountY);
    }

    // ------------------------------------------------------------------ rebalance

    /// Pulls the whole position and lays it out again around the active bin. Keeper or protocol owner.
    function rebalance(uint24 activeIdDesired, uint24 idSlippage) external nonReentrant {
        if (msg.sender != IDlmmVaultFactory(factory).keeper() && msg.sender != config.owner()) {
            revert DlmmVault__NotKeeper();
        }
        if (config.paused()) revert DlmmVault__Paused();
        uint24 active = _checkActive(activeIdDesired, idSlippage);
        if (_drift(active) <= halfWidth / 2) revert DlmmVault__NotNeeded(active);
        uint256 readyAt = uint256(lastRebalance) + MIN_REBALANCE_INTERVAL;
        if (block.timestamp < readyAt) revert DlmmVault__TooSoon(readyAt);

        (uint24 oldLower, uint24 oldUpper) = (lowerId, upperId);
        _removeAll(oldLower, oldUpper);
        (uint256 x, uint256 y) = _deploy(active);
        lastRebalance = uint40(block.timestamp);
        ++rebalanceCount;
        emit Rebalance(msg.sender, active, oldLower, oldUpper, lowerId, upperId, x, y);
    }

    // ------------------------------------------------------------------ internals

    function _checkActive(uint24 desired, uint24 slippage) internal view returns (uint24 active) {
        active = pair.getActiveId();
        uint256 d = active > desired ? active - desired : desired - active;
        if (d > slippage) revert DlmmVault__ActiveIdSlippage(active);
    }

    function _range(uint24 active) internal view returns (uint24, uint24) {
        return (active - halfWidth, active + halfWidth);
    }

    /// Bins between the active bin and the centre of the current range.
    function _drift(uint24 active) internal view returns (uint256) {
        uint256 centre = (uint256(lowerId) + upperId) / 2;
        return active > centre ? active - centre : centre - active;
    }

    function _firstShares(uint256 x, uint256 y) internal view returns (uint256) {
        return BinMath.getLiquidity(x, y, BinMath.getPriceFromId(pair.getActiveId(), binStep));
    }

    /// Largest share amount both maxima can pay for at the vault's mix, and what it costs (rounded up).
    function _sharesFor(uint256 xMax, uint256 yMax, uint256 tx_, uint256 ty, uint256 supply)
        internal
        pure
        returns (uint256 shares, uint256 x, uint256 y)
    {
        if (tx_ == 0) {
            shares = Math.mulDiv(yMax, supply, ty);
        } else if (ty == 0) {
            shares = Math.mulDiv(xMax, supply, tx_);
        } else {
            shares = Math.min(Math.mulDiv(xMax, supply, tx_), Math.mulDiv(yMax, supply, ty));
        }
        x = Math.mulDiv(shares, tx_, supply, Math.Rounding.Ceil);
        y = Math.mulDiv(shares, ty, supply, Math.Rounding.Ceil);
    }

    function _pull(uint256 x, uint256 y) internal {
        if (x != 0) tokenX.safeTransferFrom(msg.sender, address(this), x);
        if (y != 0) tokenY.safeTransferFrom(msg.sender, address(this), y);
    }

    function _binAmounts(uint24 id) internal view returns (uint256 x, uint256 y) {
        uint256 bal = pair.balanceOf(address(this), id);
        if (bal == 0) return (0, 0);
        (uint128 rx, uint128 ry) = pair.getBin(id);
        uint256 ts = pair.totalSupply(id);
        return (Math.mulDiv(bal, rx, ts), Math.mulDiv(bal, ry, ts));
    }

    function _positionAmounts() internal view returns (uint256 x, uint256 y) {
        (,, x, y) = _positionBins();
    }

    /// The vault's amounts in every bin of its range, and their sums.
    function _positionBins() internal view returns (uint256[] memory ax, uint256[] memory ay, uint256 x, uint256 y) {
        uint24 lower = lowerId;
        uint256 n = uint256(upperId) - lower + 1;
        ax = new uint256[](n);
        ay = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (ax[i], ay[i]) = _binAmounts(uint24(lower + i));
            x += ax[i];
            y += ay[i];
        }
    }

    function _removeAll(uint24 lower, uint24 upper) internal {
        uint256 n = uint256(upper) - lower + 1;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            uint24 id = uint24(lower + i);
            uint256 bal = pair.balanceOf(address(this), id);
            if (bal == 0) continue;
            ids[k] = id;
            amounts[k] = bal;
            ++k;
        }
        if (k == 0) return;
        assembly ("memory-safe") {
            mstore(ids, k)
            mstore(amounts, k)
        }
        pair.burn(address(this), address(this), ids, amounts);
    }

    /// Lays the whole idle balance out over activeId ± halfWidth with the vault's shape.
    function _deploy(uint24 active) internal returns (uint256 x, uint256 y) {
        (uint24 lower, uint24 upper) = _range(active);
        (lowerId, upperId) = (lower, upper);
        x = tokenX.balanceOf(address(this));
        y = tokenY.balanceOf(address(this));
        if (x == 0 && y == 0) return (0, 0);

        uint256 n = uint256(upper) - lower + 1;
        uint256[] memory wx = new uint256[](n);
        uint256[] memory wy = new uint256[](n);
        uint256 sx;
        uint256 sy;
        // Weights are doubled so the active bin can take half a share from each side when both
        // tokens are deposited (it holds both), mirroring the app's liquidity shapes.
        bool both = x != 0 && y != 0;
        for (uint256 i; i < n; ++i) {
            uint24 id = uint24(lower + i);
            if (x != 0 && id >= active) {
                uint256 w = _weight(id - active) * (both && id == active ? 1 : 2);
                wx[i] = w;
                sx += w;
            }
            if (y != 0 && id <= active) {
                uint256 w = _weight(active - id) * (both && id == active ? 1 : 2);
                wy[i] = w;
                sy += w;
            }
        }
        uint256[] memory ax = new uint256[](n);
        uint256[] memory ay = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            if (wx[i] != 0) ax[i] = x * wx[i] / sx;
            if (wy[i] != 0) ay[i] = y * wy[i] / sy;
        }
        // The active bin only takes its own X:Y mix, so the deposit is not part swap (no composition
        // fee). What does not fit moves one bin out on its own side.
        uint256 ia = halfWidth;
        (uint256 leftX, uint256 leftY) = (ax[ia], ay[ia]);
        (ax[ia], ay[ia]) = _matchActive(active, leftX, leftY);
        ax[ia + 1] += leftX - ax[ia];
        ay[ia - 1] += leftY - ay[ia];
        _mintBins(active, lower, ax, ay);
    }

    /// Largest (x', y') <= (x, y) in the active bin's current X:Y ratio (any mix if the bin is empty).
    function _matchActive(uint24 active, uint256 x, uint256 y) internal view returns (uint256, uint256) {
        if (pair.totalSupply(active) == 0) return (x, y);
        (uint128 rx, uint128 ry) = pair.getBin(active);
        if (rx == 0 && ry == 0) return (0, 0);
        if (rx == 0) return (0, y);
        if (ry == 0) return (x, 0);
        if (x * ry > y * rx) return (Math.mulDiv(y, rx, ry), y);
        return (x, Math.mulDiv(x, ry, rx));
    }

    /// Shape weight at `d` bins from the active bin (d in [0, halfWidth]).
    function _weight(uint256 d) internal view returns (uint256) {
        if (shape == SHAPE_CURVE) return uint256(halfWidth) + 1 - d;
        if (shape == SHAPE_BIDASK) return d + 1;
        return 1;
    }

    /// Mints amounts per bin starting at `lower`. X is only placed at or above the active bin and Y
    /// at or below it; bins that would mint dust pair shares are skipped (their tokens stay idle).
    function _mintBins(uint24 active, uint24 lower, uint256[] memory ax, uint256[] memory ay) internal {
        uint256 n = ax.length;
        uint256[] memory ids = new uint256[](n);
        uint256 k;
        uint256 sx;
        uint256 sy;
        for (uint256 i; i < n; ++i) {
            uint24 id = uint24(lower + i);
            if (id < active) ax[i] = 0;
            if (id > active) ay[i] = 0;
            if ((ax[i] == 0 && ay[i] == 0) || !_mintsShares(id, ax[i], ay[i])) continue;
            ids[k] = id;
            ax[k] = ax[i];
            ay[k] = ay[i];
            sx += ax[i];
            sy += ay[i];
            ++k;
        }
        if (k == 0) return;
        uint256[] memory dx = new uint256[](k);
        uint256[] memory dy = new uint256[](k);
        for (uint256 i; i < k; ++i) {
            if (sx != 0) dx[i] = ax[i] * PRECISION / sx;
            if (sy != 0) dy[i] = ay[i] * PRECISION / sy;
        }
        assembly ("memory-safe") {
            mstore(ids, k)
        }
        if (sx != 0) tokenX.safeTransfer(address(pair), sx);
        if (sy != 0) tokenY.safeTransfer(address(pair), sy);
        // The pair refunds any rounding leftover to this vault, where it stays idle.
        pair.mint(address(this), ids, dx, dy);
    }

    /// True if depositing (x, y) into bin `id` mints at least MIN_BIN_SHARES pair shares
    /// (same math as DlmmPair.mint, before any composition fee).
    function _mintsShares(uint24 id, uint256 x, uint256 y) internal view returns (bool) {
        uint256 price = BinMath.getPriceFromId(id, binStep);
        uint256 liq = BinMath.getLiquidity(x, y, price);
        uint256 supply = pair.totalSupply(id);
        if (supply == 0) return liq >= MIN_BIN_SHARES;
        (uint128 rx, uint128 ry) = pair.getBin(id);
        uint256 binLiq = BinMath.getLiquidity(rx, ry, price);
        if (binLiq == 0) return false;
        return Math.mulDiv(liq, supply, binLiq) >= MIN_BIN_SHARES;
    }
}

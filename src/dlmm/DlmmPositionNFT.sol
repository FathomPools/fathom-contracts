// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DlmmFactory} from "./DlmmFactory.sol";
import {DlmmPair} from "./DlmmPair.sol";

/// ERC-721 wrapper over DLMM bin shares. The NFT contract holds the pair shares; each token id
/// records its own share per bin over a contiguous range [lowerId, upperId]. Swap fees accrue into
/// bin reserves, so decreasing liquidity collects them.
contract DlmmPositionNFT is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        address pair;
        uint24 lowerId;
        uint24 upperId;
    }

    /// Deposit slippage bounds (Liquidity Book router style). The deposit reverts if the pair's
    /// active bin is more than `idSlippage` bins from `activeIdDesired` (the bin the caller priced
    /// against), if less than `amountXMin`/`amountYMin` actually lands in the bins, or after
    /// `deadline`. Protects against being sandwiched by a price-moving swap.
    struct DepositGuard {
        uint24 activeIdDesired;
        uint24 idSlippage;
        uint256 amountXMin;
        uint256 amountYMin;
        uint256 deadline;
    }

    DlmmFactory public immutable factory;
    uint256 public nextTokenId = 1;

    mapping(uint256 => Position) public positions;
    mapping(uint256 => uint256[]) internal _shares;

    event PositionMinted(uint256 indexed tokenId, address indexed owner, address indexed pair, uint24 lowerId, uint24 upperId);
    event LiquidityIncreased(uint256 indexed tokenId, uint256 amountX, uint256 amountY);
    event LiquidityDecreased(uint256 indexed tokenId, uint16 bps, address to, uint256 amountX, uint256 amountY);

    error DlmmPositionNFT__UnknownPair();
    error DlmmPositionNFT__InvalidRange();
    error DlmmPositionNFT__InvalidBps();
    error DlmmPositionNFT__Expired();
    error DlmmPositionNFT__ActiveIdSlippage(uint24 activeId);
    error DlmmPositionNFT__AmountSlippage(uint256 amountX, uint256 amountY);

    constructor(DlmmFactory factory_) ERC721("Fathom DLMM Position", "FTHM-DLMM") {
        factory = factory_;
    }

    function getShares(uint256 tokenId) external view returns (uint256[] memory) {
        return _shares[tokenId];
    }

    /// Pulls `amountX`/`amountY` from the caller and deposits them over [lowerId, upperId] with the
    /// given 1e18-scaled distributions (one entry per bin). Unused tokens are refunded to the caller.
    /// `guard` bounds the active bin, the amounts actually deposited and the deadline.
    function mint(
        address pair,
        uint24 lowerId,
        uint24 upperId,
        uint256 amountX,
        uint256 amountY,
        uint256[] calldata distributionX,
        uint256[] calldata distributionY,
        address to,
        DepositGuard calldata guard
    ) external nonReentrant returns (uint256 tokenId, uint256 amountXAdded, uint256 amountYAdded) {
        if (!factory.isPair(pair)) revert DlmmPositionNFT__UnknownPair();
        if (upperId < lowerId) revert DlmmPositionNFT__InvalidRange();

        tokenId = nextTokenId++;
        positions[tokenId] = Position({pair: pair, lowerId: lowerId, upperId: upperId});
        uint256[] memory minted;
        (amountXAdded, amountYAdded, minted) =
            _deposit(pair, lowerId, upperId, amountX, amountY, distributionX, distributionY, guard);
        _shares[tokenId] = minted;

        _safeMint(to, tokenId);
        emit PositionMinted(tokenId, to, pair, lowerId, upperId);
        emit LiquidityIncreased(tokenId, amountXAdded, amountYAdded);
    }

    /// Adds liquidity to an existing position (same bin range). Owner or approved only.
    function increase(
        uint256 tokenId,
        uint256 amountX,
        uint256 amountY,
        uint256[] calldata distributionX,
        uint256[] calldata distributionY,
        DepositGuard calldata guard
    ) external nonReentrant returns (uint256 amountXAdded, uint256 amountYAdded) {
        _checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
        Position memory p = positions[tokenId];
        uint256[] memory minted;
        (amountXAdded, amountYAdded, minted) =
            _deposit(p.pair, p.lowerId, p.upperId, amountX, amountY, distributionX, distributionY, guard);
        uint256[] storage shares = _shares[tokenId];
        for (uint256 i; i < minted.length; ++i) {
            shares[i] += minted[i];
        }
        emit LiquidityIncreased(tokenId, amountXAdded, amountYAdded);
    }

    /// Removes `bps` (of 10_000) of every bin's shares and sends the tokens (incl. accrued fees) to `to`.
    /// Reverts if less than `amountXMin`/`amountYMin` comes out or after `deadline`; pass 0 mins to
    /// withdraw unconditionally (withdrawals are never paused).
    function decrease(uint256 tokenId, uint16 bps, address to, uint256 amountXMin, uint256 amountYMin, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountX, uint256 amountY)
    {
        _checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
        _checkDeadline(deadline);
        (amountX, amountY) = _decrease(tokenId, bps, to);
        _checkAmounts(amountX, amountY, amountXMin, amountYMin);
    }

    /// Withdraws everything to `to` and burns the NFT. Same min-amount / deadline bounds as `decrease`.
    function burn(uint256 tokenId, address to, uint256 amountXMin, uint256 amountYMin, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountX, uint256 amountY)
    {
        _checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
        _checkDeadline(deadline);
        (amountX, amountY) = _decrease(tokenId, 10_000, to);
        _checkAmounts(amountX, amountY, amountXMin, amountYMin);
        delete positions[tokenId];
        delete _shares[tokenId];
        _burn(tokenId);
    }

    function _decrease(uint256 tokenId, uint16 bps, address to) internal returns (uint256 amountX, uint256 amountY) {
        if (bps == 0 || bps > 10_000) revert DlmmPositionNFT__InvalidBps();
        Position memory p = positions[tokenId];
        uint256[] storage shares = _shares[tokenId];
        uint256 n = shares.length;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = uint256(p.lowerId) + i;
            uint256 s = shares[i];
            uint256 amt = bps == 10_000 ? s : s * bps / 10_000;
            amounts[i] = amt;
            shares[i] = s - amt;
        }
        (amountX, amountY) = DlmmPair(p.pair).burn(address(this), to, ids, amounts);
        emit LiquidityDecreased(tokenId, bps, to, amountX, amountY);
    }

    function _deposit(
        address pair,
        uint24 lowerId,
        uint24 upperId,
        uint256 amountX,
        uint256 amountY,
        uint256[] calldata distributionX,
        uint256[] calldata distributionY,
        DepositGuard calldata guard
    ) internal returns (uint256 addedX, uint256 addedY, uint256[] memory minted) {
        _checkDeadline(guard.deadline);
        uint24 activeId = DlmmPair(pair).getActiveId();
        uint24 desired = guard.activeIdDesired;
        uint256 drift = activeId > desired ? activeId - desired : desired - activeId;
        if (drift > guard.idSlippage) revert DlmmPositionNFT__ActiveIdSlippage(activeId);

        uint256 n = uint256(upperId) - lowerId + 1;
        if (distributionX.length != n || distributionY.length != n) revert DlmmPositionNFT__InvalidRange();
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = uint256(lowerId) + i;
        }

        IERC20 tx_ = IERC20(DlmmPair(pair).tokenX());
        IERC20 ty = IERC20(DlmmPair(pair).tokenY());
        if (amountX != 0) tx_.safeTransferFrom(msg.sender, pair, amountX);
        if (amountY != 0) ty.safeTransferFrom(msg.sender, pair, amountY);

        (addedX, addedY, minted) = DlmmPair(pair).mint(address(this), ids, distributionX, distributionY);

        // The pair refunds unused tokens to this contract; forward them to the caller.
        uint256 bx = tx_.balanceOf(address(this));
        if (bx != 0) tx_.safeTransfer(msg.sender, bx);
        uint256 by = ty.balanceOf(address(this));
        if (by != 0) ty.safeTransfer(msg.sender, by);

        _checkAmounts(addedX, addedY, guard.amountXMin, guard.amountYMin);
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DlmmPositionNFT__Expired();
    }

    function _checkAmounts(uint256 amountX, uint256 amountY, uint256 amountXMin, uint256 amountYMin) internal pure {
        if (amountX < amountXMin || amountY < amountYMin) revert DlmmPositionNFT__AmountSlippage(amountX, amountY);
    }
}

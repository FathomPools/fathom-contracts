// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// Curated registry of oracle-priced assets (Stock Tokens, future RWAs) and the quote currencies they
/// may be paired with. `address(0)` is native ETH. Prices are USD per 1 whole token, 18 decimals.
contract AssetRegistry is Ownable2Step {
    enum AssetClass {
        NONE,
        STOCK,
        RWA
    }

    struct Asset {
        AssetClass class;
        address feed; // Chainlink USD feed
        uint32 heartbeat; // max oracle age in seconds before the price counts as stale
        uint16 openFeeBps; // swap fee while the market session is open
        uint16 closedFeeBps; // swap fee while closed
        uint16 staleFeeBps; // swap fee while the oracle is stale
        uint16 openMaxDevBps; // max |poolPrice - oraclePrice| / oraclePrice while open
        uint16 closedMaxDevBps; // same, while closed or stale
        bool enabled;
    }

    struct Quote {
        address feed; // 0 → pegged at exactly $1 (USDG)
        uint32 heartbeat;
        bool enabled;
    }

    uint16 public constant MAX_FEE_BPS = 1000;

    mapping(address => Asset) internal _assets;
    mapping(address => Quote) internal _quotes;
    address[] public assetList;

    /// Regular session in seconds after 00:00 UTC, Monday–Friday. Owner shifts it for US DST.
    uint32 public sessionOpenUtc = 13 hours + 30 minutes; // 09:30 ET during DST
    uint32 public sessionCloseUtc = 20 hours; // 16:00 ET during DST
    /// UTC day index (timestamp / 1 days) → exchange holiday.
    mapping(uint256 => bool) public holiday;

    event AssetSet(address indexed asset, AssetClass class, address feed, bool enabled);
    event QuoteSet(address indexed quote, address feed, bool enabled);
    event SessionSet(uint32 openUtc, uint32 closeUtc);
    event HolidaySet(uint256 indexed day, bool isHoliday);

    error BadParams();
    error UnknownAsset();
    error UnknownQuote();
    error BadOracle();

    constructor(address owner_) Ownable(owner_) {}

    // ---------------------------------------------------------------- admin

    function setAsset(address asset, Asset calldata a) external onlyOwner {
        if (asset == address(0) || a.class == AssetClass.NONE || a.feed == address(0)) revert BadParams();
        if (a.openFeeBps > MAX_FEE_BPS || a.closedFeeBps > MAX_FEE_BPS || a.staleFeeBps > MAX_FEE_BPS) {
            revert BadParams();
        }
        if (a.openMaxDevBps == 0 || a.closedMaxDevBps == 0) revert BadParams();
        if (_assets[asset].class == AssetClass.NONE) assetList.push(asset);
        _assets[asset] = a;
        emit AssetSet(asset, a.class, a.feed, a.enabled);
    }

    function setQuote(address quote, address feed, uint32 heartbeat, bool enabled) external onlyOwner {
        _quotes[quote] = Quote(feed, heartbeat, enabled);
        emit QuoteSet(quote, feed, enabled);
    }

    function setSession(uint32 openUtc, uint32 closeUtc) external onlyOwner {
        if (openUtc >= closeUtc || closeUtc > 1 days) revert BadParams();
        sessionOpenUtc = openUtc;
        sessionCloseUtc = closeUtc;
        emit SessionSet(openUtc, closeUtc);
    }

    function setHoliday(uint256 day, bool isHoliday) external onlyOwner {
        holiday[day] = isHoliday;
        emit HolidaySet(day, isHoliday);
    }

    // ---------------------------------------------------------------- views

    function asset(address a) external view returns (Asset memory) {
        return _assets[a];
    }

    function quote(address q) external view returns (Quote memory) {
        return _quotes[q];
    }

    function assetCount() external view returns (uint256) {
        return assetList.length;
    }

    function isAsset(address a) public view returns (bool) {
        return _assets[a].enabled;
    }

    function isQuote(address q) public view returns (bool) {
        return _quotes[q].enabled;
    }

    /// True during the regular Mon–Fri session outside holidays.
    function isMarketOpen() public view returns (bool) {
        uint256 day = block.timestamp / 1 days;
        if (holiday[day]) return false;
        uint256 weekday = (day + 3) % 7; // 1970-01-01 was a Thursday → 0 = Monday
        if (weekday >= 5) return false;
        uint256 t = block.timestamp % 1 days;
        return t >= sessionOpenUtc && t < sessionCloseUtc;
    }

    /// USD price of 1 whole `a` (18 dec) and whether it is older than the heartbeat.
    function assetPrice(address a) public view returns (uint256 priceE18, bool stale) {
        Asset storage s = _assets[a];
        if (!s.enabled) revert UnknownAsset();
        return _read(s.feed, s.heartbeat);
    }

    /// USD price of 1 whole quote token (18 dec). USDG-style quotes without a feed are exactly $1.
    function quotePrice(address q) public view returns (uint256 priceE18, bool stale) {
        Quote storage s = _quotes[q];
        if (!s.enabled) revert UnknownQuote();
        if (s.feed == address(0)) return (1e18, false);
        return _read(s.feed, s.heartbeat);
    }

    /// Fee and max deviation that apply to `a` right now, plus the oracle state.
    function riskParams(address a) external view returns (uint16 feeBps, uint16 maxDevBps, bool stale, bool open) {
        Asset storage s = _assets[a];
        if (!s.enabled) revert UnknownAsset();
        (, stale) = _read(s.feed, s.heartbeat);
        open = isMarketOpen();
        if (stale) return (s.staleFeeBps, s.closedMaxDevBps, true, open);
        if (open) return (s.openFeeBps, s.openMaxDevBps, false, true);
        return (s.closedFeeBps, s.closedMaxDevBps, false, false);
    }

    function _read(address feed, uint32 heartbeat) internal view returns (uint256 priceE18, bool stale) {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert BadOracle();
        uint8 dec = IAggregatorV3(feed).decimals();
        priceE18 = dec <= 18 ? uint256(answer) * 10 ** (18 - dec) : uint256(answer) / 10 ** (dec - 18);
        stale = block.timestamp > updatedAt + heartbeat;
    }
}

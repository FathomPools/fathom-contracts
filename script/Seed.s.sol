// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId as PoolIdLike} from "v4-core/src/types/PoolId.sol";

import {RobinhoodAddresses as RH} from "./RobinhoodAddresses.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {DammHook} from "../src/hooks/DammHook.sol";
import {StockHook} from "../src/hooks/StockHook.sol";
import {DlmmFactory} from "../src/dlmm/DlmmFactory.sol";
import {BinMath} from "../src/libraries/BinMath.sol";

/// Creates the launch pools (no liquidity — LPs add it through the app / v4 PositionManager):
///   DAMM ETH/USDG at the Chainlink price, STOCK pools for the first `SEED_STOCKS` (default 5)
///   stocks vs USDG at their oracle price, DLMM WETH/USDG (binStep 10) at the Chainlink price.
///   forge script script/Seed.s.sol --rpc-url $ROBINHOOD_RPC_URL --private-key $PK --sender $ADDR --broadcast
contract Seed is Script {
    int24 constant TICK_SPACING = 60;
    uint16 constant DLMM_BIN_STEP = 10;

    function run() external {
        string memory json = vm.readFile(
            block.chainid == RH.CHAIN_ID ? "deployments/robinhood.json" : "deployments/local.json"
        );
        DammHook damm = DammHook(vm.parseJsonAddress(json, ".dammHook"));
        StockHook stock = StockHook(vm.parseJsonAddress(json, ".stockHook"));
        DlmmFactory dlmm = DlmmFactory(vm.parseJsonAddress(json, ".dlmmFactory"));
        uint256 nStocks = vm.envOr("SEED_STOCKS", uint256(5));

        (, int256 ethUsd8,,,) = IAggregatorV3(RH.ETH_USD).latestRoundData();
        // USDG raw (6 dec) per wei (18 dec) = ethUsd8 / 1e20
        uint160 ethUsdgSqrt = uint160(Math.sqrt(FullMath.mulDiv(uint256(ethUsd8), 1 << 192, 1e20)));
        uint24 activeId = _idForPrice(FullMath.mulDiv(uint256(ethUsd8), 1 << 128, 1e20));

        vm.startBroadcast();
        (bytes32 dammId,) = _pool(damm, Currency.wrap(address(0)), Currency.wrap(RH.USDG), ethUsdgSqrt);
        console2.log("DAMM ETH/USDG");
        console2.logBytes32(dammId);

        RH.StockQuote[] memory s = RH.stocks();
        for (uint256 i; i < nStocks && i < s.length; ++i) {
            (Currency c0, Currency c1) = s[i].token < RH.USDG
                ? (Currency.wrap(s[i].token), Currency.wrap(RH.USDG))
                : (Currency.wrap(RH.USDG), Currency.wrap(s[i].token));
            PoolKey memory key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(address(stock)));
            (PoolIdLike pid,) = stock.createPool(key, 0);
            bytes32 id = PoolIdLike.unwrap(pid);
            console2.log(string.concat("STOCK ", s[i].symbol, "/USDG"));
            console2.logBytes32(id);
        }

        address pair = dlmm.createPair(RH.WETH, RH.USDG, DLMM_BIN_STEP, activeId);
        console2.log("DLMM WETH/USDG", pair, activeId);
        vm.stopBroadcast();
    }

    function _pool(DammHook damm, Currency c0, Currency c1, uint160 sqrtP) internal returns (bytes32, int24) {
        PoolKey memory key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(address(damm)));
        (PoolIdLike id, int24 tick) = damm.createPool(key, sqrtP, DammHook.PoolParams(30, 0, 0, 10_000));
        return (PoolIdLike.unwrap(id), tick);
    }

    /// Largest bin id whose price (128.128, Y raw per X raw) is <= target.
    function _idForPrice(uint256 target128) internal pure returns (uint24) {
        // ±80k bins at binStep 10 spans e^±80, inside the 128.128 range
        uint24 lo = (1 << 23) - 80_000;
        uint24 hi = (1 << 23) + 80_000;
        while (lo < hi) {
            uint24 mid = uint24((uint256(lo) + hi + 1) / 2);
            if (BinMath.getPriceFromId(mid, DLMM_BIN_STEP) <= target128) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }
}


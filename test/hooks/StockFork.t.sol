// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolConfig} from "../../src/core/ProtocolConfig.sol";
import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {StockHook} from "../../src/hooks/StockHook.sol";
import {HookDeployer} from "../../src/hooks/HookDeployer.sol";
import {RobinhoodAddresses as RH} from "../../script/RobinhoodAddresses.sol";

/// Live Robinhood Chain (4663) fork: canonical v4 PoolManager, real NVDA Stock Token + Chainlink
/// feed, USDG quote. Skipped when the RPC is unreachable.
contract StockForkTest is Test {
    IPoolManager internal constant PM = IPoolManager(RH.POOL_MANAGER);
    address internal collector = makeAddr("collector");
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        try vm.createSelectFork(rpc) {
            forked = block.chainid == RH.CHAIN_ID;
        } catch {}
    }

    function test_fork_nvdaUsdgPool() public {
        if (!forked) vm.skip(true);
        address nvda = RH.stocks()[0].token;
        address nvdaFeed = RH.stocks()[0].feed;

        ProtocolConfig config = new ProtocolConfig(address(this), collector);
        AssetRegistry registry = new AssetRegistry(address(this));
        // generous heartbeat so a weekend-old feed does not trip the stale guard
        registry.setAsset(
            nvda, AssetRegistry.Asset(AssetRegistry.AssetClass.STOCK, nvdaFeed, 7 days, 30, 150, 500, 200, 50, true)
        );
        registry.setQuote(RH.USDG, address(0), 0, true);
        StockHook hook = HookDeployer.deployStock(address(this), PM, config, registry);

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        PoolSwapTest router = new PoolSwapTest(PM);
        deal(nvda, address(this), 10_000e18);
        deal(RH.USDG, address(this), 10_000_000e6);
        IERC20(nvda).approve(address(lp), type(uint256).max);
        IERC20(RH.USDG).approve(address(lp), type(uint256).max);
        IERC20(nvda).approve(address(router), type(uint256).max);
        IERC20(RH.USDG).approve(address(router), type(uint256).max);

        bool nvdaIs0 = nvda < RH.USDG;
        PoolKey memory key = PoolKey(
            Currency.wrap(nvdaIs0 ? nvda : RH.USDG),
            Currency.wrap(nvdaIs0 ? RH.USDG : nvda),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(hook))
        );
        (PoolId id, int24 tick) = hook.createPool(key, 0);
        int24 mid = tick / 60 * 60;
        lp.modifyLiquidity(key, ModifyLiquidityParams(mid - 6000, mid + 6000, 1e17, 0), "");

        (, uint256 priceE18, uint24 lpPips, uint24 totalPips,,) = hook.oracleState(id);
        assertGt(priceE18, 1e18); // NVDA priced in USDG, whole units
        router.swap(
            key,
            SwapParams(nvdaIs0, -1e18, nvdaIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 expectedFee = 1e18 * uint256(totalPips - lpPips) / 1e6;
        // NVDA reports UI-scaled balances (TransferWithScaledUI), so compare approximately
        assertApproxEqRel(
            IERC20(nvda).balanceOf(collector) + PM.balanceOf(address(hook), uint160(nvda)), expectedFee, 0.01e18
        );

        // a swap that pushes the pool far outside the oracle band reverts
        vm.expectRevert();
        router.swap(
            key,
            SwapParams(nvdaIs0, -2000e18, nvdaIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}

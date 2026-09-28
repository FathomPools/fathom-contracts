// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {RobinhoodAddresses as RH} from "./RobinhoodAddresses.sol";
import {ProtocolConfig} from "../src/core/ProtocolConfig.sol";
import {AssetRegistry} from "../src/core/AssetRegistry.sol";
import {DammHook} from "../src/hooks/DammHook.sol";
import {StockHook} from "../src/hooks/StockHook.sol";
import {HookDeployer} from "../src/hooks/HookDeployer.sol";
import {DlmmFactory} from "../src/dlmm/DlmmFactory.sol";
import {DlmmPositionNFT} from "../src/dlmm/DlmmPositionNFT.sol";
import {Router} from "../src/periphery/Router.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";
import {FeeCollector} from "../src/periphery/FeeCollector.sol";
import {Buyback} from "../src/periphery/Buyback.sol";

/// Deploys the whole protocol to Robinhood Chain and registers every stock with a Chainlink feed.
///   forge script script/Deploy.s.sol --rpc-url $ROBINHOOD_RPC_URL --private-key $PK --sender $ADDR --broadcast
/// Dry run (fork simulation): same command without --broadcast / --private-key.
/// The broadcaster becomes owner of everything. Writes deployments/robinhood.json.
contract Deploy is Script {
    uint256 constant BUYBACK_MAX_ETH_PER_CALL = 0.05 ether;

    struct Deployed {
        ProtocolConfig config;
        AssetRegistry registry;
        DammHook damm;
        StockHook stock;
        DlmmFactory dlmmFactory;
        DlmmPositionNFT dlmmNft;
        Router router;
        FeeCollector feeCollector;
        Buyback buyback;
    }

    function run() external returns (Deployed memory d) {
        address owner = msg.sender;
        IPoolManager pm = IPoolManager(RH.POOL_MANAGER);
        uint256 startBlock = block.number;

        vm.startBroadcast();
        d.registry = new AssetRegistry(owner);
        d.buyback = new Buyback(pm, owner, BUYBACK_MAX_ETH_PER_CALL);
        d.router = new Router(pm, RH.WETH);
        d.feeCollector = new FeeCollector(owner, IRouter(address(d.router)), d.registry, address(d.buyback));
        d.config = new ProtocolConfig(owner, address(d.feeCollector));
        d.damm = HookDeployer.deployDamm(HookDeployer.CREATE2_PROXY, pm, d.config);
        d.stock = HookDeployer.deployStock(HookDeployer.CREATE2_PROXY, pm, d.config, d.registry);
        d.dlmmFactory = new DlmmFactory(d.config);
        d.dlmmNft = new DlmmPositionNFT(d.dlmmFactory);

        // Quotes: USDG pegged at $1 (no feed), native ETH + WETH priced by Chainlink ETH/USD.
        d.registry.setQuote(RH.USDG, address(0), 0, true);
        d.registry.setQuote(address(0), RH.ETH_USD, uint32(RH.HEARTBEAT), true);
        d.registry.setQuote(RH.WETH, RH.ETH_USD, uint32(RH.HEARTBEAT), true);

        RH.StockQuote[] memory s = RH.stocks();
        for (uint256 i; i < s.length; ++i) {
            d.registry.setAsset(
                s[i].token,
                AssetRegistry.Asset({
                    class: AssetRegistry.AssetClass.STOCK,
                    feed: s[i].feed,
                    heartbeat: uint32(RH.HEARTBEAT),
                    openFeeBps: 30,
                    closedFeeBps: 150,
                    staleFeeBps: 500,
                    openMaxDevBps: 200,
                    closedMaxDevBps: 50,
                    enabled: true
                })
            );
        }
        vm.stopBroadcast();

        _write(d, startBlock);
    }

    function _write(Deployed memory d, uint256 startBlock) internal {
        string memory k = "deploy";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "startBlock", startBlock);
        vm.serializeAddress(k, "poolManager", RH.POOL_MANAGER);
        vm.serializeAddress(k, "positionManager", RH.POSITION_MANAGER);
        vm.serializeAddress(k, "protocolConfig", address(d.config));
        vm.serializeAddress(k, "assetRegistry", address(d.registry));
        vm.serializeAddress(k, "dammHook", address(d.damm));
        vm.serializeAddress(k, "stockHook", address(d.stock));
        vm.serializeAddress(k, "dlmmFactory", address(d.dlmmFactory));
        vm.serializeAddress(k, "dlmmPositionNft", address(d.dlmmNft));
        vm.serializeAddress(k, "router", address(d.router));
        vm.serializeAddress(k, "feeCollector", address(d.feeCollector));
        string memory json = vm.serializeAddress(k, "buyback", address(d.buyback));
        string memory path = block.chainid == RH.CHAIN_ID ? "deployments/robinhood.json" : "deployments/local.json";
        vm.writeJson(json, path);
        console2.log("wrote", path);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {RobinhoodAddresses as RH} from "./RobinhoodAddresses.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";
import {DlmmFactory} from "../src/dlmm/DlmmFactory.sol";
import {FeeCollector} from "../src/periphery/FeeCollector.sol";
import {Buyback} from "../src/periphery/Buyback.sol";
import {BuybackV2} from "../src/periphery/BuybackV2.sol";

/// Deploys BuybackV2 with CREATE2 (fixed address) and switches the FeeCollector over to it:
///   1. BuybackV2 (owner = the FeeCollector's owner, 0.05 ETH per call)
///   2. configure it on the same ETH/$FATHOM pool as the v1 Buyback
///   3. FeeCollector.setBuyback(v2)
///   4. a WETH fee route: WETH -> USDG on the WETH/USDG DLMM pair (bin step 10), then the USDG
///      route's own hops to ETH (a lone WETH unwrap hop cannot start a Router route)
/// Steps 2-4 are owner calls, so run it as the protocol owner:
///   FOUNDRY_PROFILE=deploy forge script script/DeployBuybackV2.s.sol \
///     --rpc-url $ROBINHOOD_RPC_URL --broadcast --account fathom-deployer
/// Every step is skipped when already done, so a rerun is safe.
contract DeployBuybackV2 is Script {
    bytes32 constant SALT = keccak256("fathom.buyback.v2");
    uint256 constant MAX_ETH_PER_CALL = 0.05 ether;
    uint256 constant WETH_MAX_PER_CALL = 2 ether;

    function run() external returns (BuybackV2 bb) {
        string memory json = vm.readFile("deployments/robinhood.json");
        IPoolManager pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        FeeCollector fc = FeeCollector(payable(vm.parseJsonAddress(json, ".feeCollector")));
        Buyback v1 = Buyback(payable(vm.parseJsonAddress(json, ".buyback")));
        DlmmFactory dlmm = DlmmFactory(vm.parseJsonAddress(json, ".dlmmFactory"));
        address owner = fc.owner();

        bytes memory init = abi.encodePacked(type(BuybackV2).creationCode, abi.encode(pm, owner, MAX_ETH_PER_CALL));
        address predicted = vm.computeCreate2Address(SALT, keccak256(init), CREATE2_FACTORY);
        console2.log("buyback v2", predicted);
        // The app is wired to this address ahead of time: refuse to deploy anywhere else.
        if (vm.keyExistsJson(json, ".buybackV2")) {
            require(predicted == vm.parseJsonAddress(json, ".buybackV2"), "buyback bytecode changed: build with FOUNDRY_PROFILE=deploy");
        }

        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks hooks) = v1.poolKey();
        PoolKey memory key = PoolKey(c0, c1, fee, spacing, hooks);
        require(Currency.unwrap(c1) != address(0), "v1 buyback not configured");

        address pair = dlmm.getPair(RH.WETH, RH.USDG, 10);
        require(pair != address(0), "no WETH/USDG pair");
        IRouter.Hop[] memory usdg = fc.route(RH.USDG).hops;
        require(usdg.length != 0, "no USDG route");
        IRouter.Hop[] memory wethHops = new IRouter.Hop[](usdg.length + 1);
        wethHops[0] = IRouter.Hop(1, abi.encode(pair, true)); // tokenX = WETH -> tokenY = USDG
        for (uint256 i; i < usdg.length; ++i) {
            wethHops[i + 1] = usdg[i];
        }

        vm.startBroadcast();
        bb = predicted.code.length == 0
            ? new BuybackV2{salt: SALT}(pm, owner, MAX_ETH_PER_CALL)
            : BuybackV2(payable(predicted));
        require(address(bb) == predicted, "unexpected buyback address");
        if (bb.token() == address(0)) bb.configure(key, v1.hookData());
        if (fc.buyback() != address(bb)) fc.setBuyback(address(bb));
        if (!fc.route(RH.WETH).set) fc.setRoute(RH.WETH, wethHops, WETH_MAX_PER_CALL, true);
        vm.stopBroadcast();

        console2.log("token", bb.token());
        console2.log("fee collector -> buyback", fc.buyback());
    }
}

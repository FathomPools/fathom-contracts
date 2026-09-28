// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Router} from "../../src/periphery/Router.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";
import {MockDlmmPair} from "./MockDlmmPair.sol";

/// Local PoolManager with hookless pools: ETH/A (native), A/B (ERC-20), plus WETH and a
/// fixed-rate DLMM pair B/WETH (1 B = 0.5 WETH).
abstract contract PeripheryBase is Deployers {
    Router router;
    WETH weth;
    MockERC20 tokA;
    MockERC20 tokB;
    PoolKey ethA; // currency0 = ETH, currency1 = A
    PoolKey ab; // sorted A/B
    MockDlmmPair dlmm;
    address user = makeAddr("user");

    ModifyLiquidityParams WIDE = ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: 0});

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        weth = new WETH();
        router = new Router(manager, address(weth));
        tokA = new MockERC20("A", "A", 18);
        tokB = new MockERC20("B", "B", 18);
        tokA.mint(address(this), 1e30);
        tokB.mint(address(this), 1e30);
        tokA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokB.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 10_000 ether);

        ethA = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(tokA)), 3000, 60, IHooks(address(0)));
        manager.initialize(ethA, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1000 ether}(ethA, WIDE, ZERO_BYTES);

        (address c0, address c1) =
            address(tokA) < address(tokB) ? (address(tokA), address(tokB)) : (address(tokB), address(tokA));
        ab = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        manager.initialize(ab, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(ab, WIDE, ZERO_BYTES);

        dlmm = new MockDlmmPair(address(tokB), address(weth), 0.5e18);
        tokB.transfer(address(dlmm), 1000e18);
        weth.deposit{value: 1000 ether}();
        weth.transfer(address(dlmm), 1000 ether);
        dlmm.sync();

        tokA.mint(user, 1000e18);
        tokB.mint(user, 1000e18);
        vm.deal(user, 1000 ether);
        vm.startPrank(user);
        tokA.approve(address(router), type(uint256).max);
        tokB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function v4Hop(PoolKey memory k, address tokenIn) internal pure returns (IRouter.Hop memory) {
        return IRouter.Hop(0, abi.encode(k, Currency.unwrap(k.currency0) == tokenIn, bytes("")));
    }

    function dlmmHop(address pair, bool swapForY) internal pure returns (IRouter.Hop memory) {
        return IRouter.Hop(1, abi.encode(pair, swapForY));
    }

    function wethHop() internal pure returns (IRouter.Hop memory) {
        return IRouter.Hop(3, "");
    }
}

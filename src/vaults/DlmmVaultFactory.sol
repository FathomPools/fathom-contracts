// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ProtocolConfig} from "../core/ProtocolConfig.sol";
import {DlmmFactory} from "../dlmm/DlmmFactory.sol";
import {DlmmPair} from "../dlmm/DlmmPair.sol";
import {DlmmVault} from "./DlmmVault.sol";

/// Creates auto-rebalancing DLMM vaults and names the keeper allowed to rebalance them. The
/// ProtocolConfig owner curates vaults (pair, half width, shape) and sets the keeper; one vault per
/// (pair, half width, shape), deployed with CREATE2 so its address is known in advance.
contract DlmmVaultFactory {
    ProtocolConfig public immutable config;
    DlmmFactory public immutable dlmmFactory;

    address public keeper;
    address[] public allVaults;
    mapping(address => bool) public isVault;
    mapping(address => mapping(uint24 => mapping(uint8 => address))) public getVault;

    event VaultCreated(address indexed vault, address indexed pair, uint24 halfWidth, uint8 shape);
    event KeeperSet(address keeper);

    error DlmmVaultFactory__NotOwner();
    error DlmmVaultFactory__UnknownPair();
    error DlmmVaultFactory__VaultExists();

    modifier onlyOwner() {
        if (msg.sender != config.owner()) revert DlmmVaultFactory__NotOwner();
        _;
    }

    constructor(ProtocolConfig config_, DlmmFactory dlmmFactory_) {
        config = config_;
        dlmmFactory = dlmmFactory_;
    }

    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }

    function getVaults() external view returns (address[] memory) {
        return allVaults;
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function createVault(address pair, uint24 halfWidth, uint8 shape) external onlyOwner returns (address vault) {
        if (!dlmmFactory.isPair(pair)) revert DlmmVaultFactory__UnknownPair();
        if (getVault[pair][halfWidth][shape] != address(0)) revert DlmmVaultFactory__VaultExists();
        string memory sx = _symbol(DlmmPair(pair).tokenX());
        string memory sy = _symbol(DlmmPair(pair).tokenY());
        vault = address(
            new DlmmVault{salt: keccak256(abi.encode(pair, halfWidth, shape))}(
                DlmmPair(pair),
                halfWidth,
                shape,
                string.concat("Fathom Vault ", sx, "-", sy),
                string.concat("fv", sx, "-", sy)
            )
        );
        getVault[pair][halfWidth][shape] = vault;
        isVault[vault] = true;
        allVaults.push(vault);
        emit VaultCreated(vault, pair, halfWidth, shape);
    }

    function _symbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return s;
        } catch {
            return "?";
        }
    }
}

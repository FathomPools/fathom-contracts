// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Fixed-supply ERC-20 deployed by LaunchPools.
/// The whole supply is minted once, in the constructor, to `to` (the LaunchPools contract, which seeds
/// the pool and hands out the rest in the same transaction). Plain OpenZeppelin ERC-20 and nothing
/// else: no owner, no further minting, no fee or limit on transfers, no address treated differently.
contract LaunchToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply, address to) ERC20(name_, symbol_) {
        _mint(to, supply);
    }
}

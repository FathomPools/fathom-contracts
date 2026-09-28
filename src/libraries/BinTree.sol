// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Three-level 256-ary bitmap over the 24-bit bin id space. Lets a swap jump to the next non-empty
/// bin in O(1) storage reads instead of scanning empty bins.
///   level2: one word, bit k1 set  <=> level1[k1] != 0   (k1 = id >> 16)
///   level1[k1]: bit (k0 & 255) set <=> level0[k0] != 0   (k0 = id >> 8)
///   level0[k0]: bit (id & 255) set <=> bin id is in the tree
library BinTree {
    struct Tree {
        uint256 level2;
        mapping(uint256 => uint256) level1;
        mapping(uint256 => uint256) level0;
    }

    function contains(Tree storage t, uint24 id) internal view returns (bool) {
        return t.level0[id >> 8] & (1 << (id & 255)) != 0;
    }

    function add(Tree storage t, uint24 id) internal {
        uint256 k0 = uint256(id) >> 8;
        uint256 leaves = t.level0[k0];
        uint256 updated = leaves | (1 << (uint256(id) & 255));
        if (updated == leaves) return;
        t.level0[k0] = updated;
        if (leaves == 0) {
            uint256 k1 = k0 >> 8;
            uint256 l1 = t.level1[k1];
            t.level1[k1] = l1 | (1 << (k0 & 255));
            if (l1 == 0) t.level2 |= 1 << k1;
        }
    }

    function remove(Tree storage t, uint24 id) internal {
        uint256 k0 = uint256(id) >> 8;
        uint256 leaves = t.level0[k0];
        uint256 updated = leaves & ~(1 << (uint256(id) & 255));
        if (updated == leaves) return;
        t.level0[k0] = updated;
        if (updated == 0) {
            uint256 k1 = k0 >> 8;
            uint256 l1 = t.level1[k1] & ~(1 << (k0 & 255));
            t.level1[k1] = l1;
            if (l1 == 0) t.level2 &= ~(1 << k1);
        }
    }

    /// Closest id strictly below `id` that is in the tree.
    function findLower(Tree storage t, uint24 id) internal view returns (uint24, bool) {
        uint256 k0 = uint256(id) >> 8;
        uint256 b = t.level0[k0] & ((1 << (uint256(id) & 255)) - 1);
        if (b != 0) return (uint24((k0 << 8) | _msb(b)), true);

        uint256 k1 = k0 >> 8;
        b = t.level1[k1] & ((1 << (k0 & 255)) - 1);
        if (b != 0) {
            k0 = (k1 << 8) | _msb(b);
            return (uint24((k0 << 8) | _msb(t.level0[k0])), true);
        }

        b = t.level2 & ((1 << k1) - 1);
        if (b != 0) {
            k1 = _msb(b);
            k0 = (k1 << 8) | _msb(t.level1[k1]);
            return (uint24((k0 << 8) | _msb(t.level0[k0])), true);
        }
        return (0, false);
    }

    /// Closest id strictly above `id` that is in the tree.
    function findHigher(Tree storage t, uint24 id) internal view returns (uint24, bool) {
        uint256 k0 = uint256(id) >> 8;
        uint256 b = t.level0[k0] & (type(uint256).max << ((uint256(id) & 255) + 1));
        if (b != 0) return (uint24((k0 << 8) | _lsb(b)), true);

        uint256 k1 = k0 >> 8;
        b = t.level1[k1] & (type(uint256).max << ((k0 & 255) + 1));
        if (b != 0) {
            k0 = (k1 << 8) | _lsb(b);
            return (uint24((k0 << 8) | _lsb(t.level0[k0])), true);
        }

        b = t.level2 & (type(uint256).max << (k1 + 1));
        if (b != 0) {
            k1 = _lsb(b);
            k0 = (k1 << 8) | _lsb(t.level1[k1]);
            return (uint24((k0 << 8) | _lsb(t.level0[k0])), true);
        }
        return (0, false);
    }

    function _msb(uint256 x) private pure returns (uint256) {
        return Math.log2(x);
    }

    function _lsb(uint256 x) private pure returns (uint256) {
        unchecked {
            return Math.log2(x & (0 - x));
        }
    }
}

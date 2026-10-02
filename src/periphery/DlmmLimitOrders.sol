// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DlmmFactory} from "../dlmm/DlmmFactory.sol";
import {DlmmPair} from "../dlmm/DlmmPair.sol";

interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// Limit orders on Fathom DLMM pairs.
///
/// A limit order is liquidity in a single bin on the far side of the price: X in a bin above the
/// active bin sells X for Y once the price rises through it, Y in a bin below buys X once the price
/// falls through it. Inside a bin swaps trade at the bin's fixed price, so an order fills at exactly
/// that price and also earns the swap fees paid while it fills.
///
/// - Orders placed in the same bin on the same side share one batch (an epoch). The contract holds
///   the batch's bin shares and tracks each owner's part of them.
/// - Once the price has crossed the whole bin, anyone can `execute` the batch: its shares are burned
///   and the proceeds wait here for the owners to `claim`. Executing promptly matters, because a bin
///   the price crosses back trades back into the original token. Fathom's keeper executes every
///   batch listed by `readyBooks`, and `claim` executes a filled batch itself if nobody has yet.
/// - Until its batch is executed an owner can `cancel` and take whatever the bin holds for them: the
///   original token, the proceeds, or a mix while the price sits inside the bin.
/// - No owner and no fee. Placing needs the pair to be unpaused; cancel, execute and claim only burn
///   bin shares, which always works. Only pairs created by the Fathom DLMM factory are accepted.
contract DlmmLimitOrders is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant PRECISION = 1e18;

    struct Batch {
        uint256 shares; // bin shares held for the batch; frozen at execution as the claim base
        uint256 amountX; // proceeds received at execution
        uint256 amountY;
        bool sellX; // true: X above the price, filled into Y
        bool executed;
    }

    struct Book {
        address pair;
        uint24 id;
    }

    struct OrderRef {
        address pair;
        uint24 id;
        uint64 epoch;
    }

    DlmmFactory public immutable factory;
    address public immutable weth;

    /// Open epoch of each (pair, bin); every earlier epoch is executed.
    mapping(address => mapping(uint24 => uint256)) public currentEpoch;
    mapping(bytes32 => Batch) internal _batches;
    mapping(bytes32 => mapping(address => uint256)) public sharesOf;
    mapping(bytes32 => mapping(address => bool)) internal _listed;
    mapping(address => OrderRef[]) internal _orders;

    /// (pair, bin) books whose open epoch holds shares, for the keeper.
    Book[] internal _open;
    mapping(bytes32 => uint256) internal _openIndex; // index + 1

    event OrderPlaced(
        address indexed owner,
        address indexed pair,
        uint24 indexed id,
        uint256 epoch,
        bool sellX,
        uint256 amountIn,
        uint256 shares
    );
    event OrderCancelled(
        address indexed owner,
        address indexed pair,
        uint24 indexed id,
        uint256 epoch,
        uint256 shares,
        uint256 amountX,
        uint256 amountY
    );
    event BatchExecuted(
        address indexed pair,
        uint24 indexed id,
        uint256 indexed epoch,
        address caller,
        uint256 shares,
        uint256 amountX,
        uint256 amountY
    );
    event OrderClaimed(
        address indexed owner, address indexed pair, uint24 indexed id, uint256 epoch, uint256 amountX, uint256 amountY
    );

    error DlmmLimitOrders__UnknownPair();
    error DlmmLimitOrders__Expired();
    error DlmmLimitOrders__ZeroAmount();
    error DlmmLimitOrders__ZeroAddress();
    error DlmmLimitOrders__WrongSide(uint24 activeId);
    error DlmmLimitOrders__BadToken();
    error DlmmLimitOrders__ValueMismatch();
    error DlmmLimitOrders__NoOrder();
    error DlmmLimitOrders__NotFilled();
    error DlmmLimitOrders__AlreadyExecuted();
    error DlmmLimitOrders__InvalidLength();
    error DlmmLimitOrders__NativeTransferFailed();

    constructor(DlmmFactory factory_, address weth_) {
        factory = factory_;
        weth = weth_;
    }

    /// Native ETH from unwrapping WETH proceeds.
    receive() external payable {
        if (msg.sender != weth) revert DlmmLimitOrders__BadToken();
    }

    // ------------------------------------------------------------------ orders

    /// Place `amount` of X (sellX, bin above the price) or Y (bin below) into bin `id` for `to`.
    /// Send native ETH as `msg.value` (== amount) when that token is WETH.
    function place(address pair, uint24 id, bool sellX, uint256 amount, address to, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 epoch, uint256 shares)
    {
        if (block.timestamp > deadline) revert DlmmLimitOrders__Expired();
        if (!factory.isPair(pair)) revert DlmmLimitOrders__UnknownPair();
        if (amount == 0) revert DlmmLimitOrders__ZeroAmount();
        if (to == address(0)) revert DlmmLimitOrders__ZeroAddress();
        DlmmPair p = DlmmPair(pair);
        uint24 active = p.getActiveId();
        if (sellX ? id <= active : id >= active) revert DlmmLimitOrders__WrongSide(active);

        // An open batch on the other side has been crossed by the price: settle it first.
        epoch = currentEpoch[pair][id];
        Batch storage b = _batches[_key(pair, id, epoch)];
        if (b.shares != 0 && b.sellX != sellX) {
            _execute(pair, id, epoch, b);
            epoch += 1;
            b = _batches[_key(pair, id, epoch)];
        }

        IERC20 tX = IERC20(p.tokenX());
        IERC20 tY = IERC20(p.tokenY());
        IERC20 token = sellX ? tX : tY;
        if (msg.value != 0) {
            if (address(token) != weth) revert DlmmLimitOrders__BadToken();
            if (msg.value != amount) revert DlmmLimitOrders__ValueMismatch();
            IWrappedNative(weth).deposit{value: amount}();
            token.safeTransfer(pair, amount);
        } else {
            token.safeTransferFrom(msg.sender, pair, amount);
        }

        uint256[] memory ids = new uint256[](1);
        uint256[] memory distX = new uint256[](1);
        uint256[] memory distY = new uint256[](1);
        ids[0] = id;
        if (sellX) distX[0] = PRECISION;
        else distY[0] = PRECISION;
        uint256 bx = tX.balanceOf(address(this));
        uint256 by = tY.balanceOf(address(this));
        (,, uint256[] memory minted) = p.mint(address(this), ids, distX, distY);
        shares = minted[0];
        // The pair refunds anything it did not take (only tokens stranded in it): pass it on.
        uint256 rx = tX.balanceOf(address(this)) - bx;
        uint256 ry = tY.balanceOf(address(this)) - by;
        if (rx != 0) tX.safeTransfer(msg.sender, rx);
        if (ry != 0) tY.safeTransfer(msg.sender, ry);

        if (b.shares == 0) {
            b.sellX = sellX;
            _addOpen(pair, id);
        }
        b.shares += shares;
        bytes32 k = _key(pair, id, epoch);
        sharesOf[k][to] += shares;
        if (!_listed[k][to]) {
            _listed[k][to] = true;
            _orders[to].push(OrderRef(pair, id, uint64(epoch)));
        }
        emit OrderPlaced(to, pair, id, epoch, sellX, amount, shares);
    }

    /// Withdraw the caller's whole order from a batch that has not been executed yet.
    function cancel(address pair, uint24 id, uint256 epoch, address to, bool unwrap)
        external
        nonReentrant
        returns (uint256 amountX, uint256 amountY)
    {
        if (to == address(0)) revert DlmmLimitOrders__ZeroAddress();
        bytes32 k = _key(pair, id, epoch);
        Batch storage b = _batches[k];
        if (b.executed) revert DlmmLimitOrders__AlreadyExecuted();
        uint256 s = sharesOf[k][msg.sender];
        if (s == 0) revert DlmmLimitOrders__NoOrder();
        sharesOf[k][msg.sender] = 0;
        b.shares -= s;
        if (b.shares == 0) _removeOpen(pair, id);
        (amountX, amountY) = _burn(pair, id, s);
        _pay(pair, to, amountX, amountY, unwrap);
        emit OrderCancelled(msg.sender, pair, id, epoch, s, amountX, amountY);
    }

    /// Execute the open batch of (pair, bin) once the price has crossed it.
    function execute(address pair, uint24 id) external nonReentrant returns (uint256 epoch) {
        epoch = currentEpoch[pair][id];
        Batch storage b = _batches[_key(pair, id, epoch)];
        if (b.shares == 0 || !_filled(pair, id, b.sellX)) revert DlmmLimitOrders__NotFilled();
        _execute(pair, id, epoch, b);
    }

    /// Keeper entry: execute every listed book that is filled, skip the rest.
    function executeMany(address[] calldata pairs, uint24[] calldata ids) external nonReentrant returns (uint256 done) {
        if (pairs.length != ids.length) revert DlmmLimitOrders__InvalidLength();
        for (uint256 i; i < pairs.length; ++i) {
            uint256 epoch = currentEpoch[pairs[i]][ids[i]];
            Batch storage b = _batches[_key(pairs[i], ids[i], epoch)];
            if (b.shares == 0 || !_filled(pairs[i], ids[i], b.sellX)) continue;
            _execute(pairs[i], ids[i], epoch, b);
            ++done;
        }
    }

    /// Take the caller's share of an executed batch (executing it first when it is filled).
    function claim(address pair, uint24 id, uint256 epoch, address to, bool unwrap)
        external
        nonReentrant
        returns (uint256 amountX, uint256 amountY)
    {
        if (to == address(0)) revert DlmmLimitOrders__ZeroAddress();
        bytes32 k = _key(pair, id, epoch);
        Batch storage b = _batches[k];
        uint256 s = sharesOf[k][msg.sender];
        if (s == 0) revert DlmmLimitOrders__NoOrder();
        if (!b.executed) {
            if (epoch != currentEpoch[pair][id] || !_filled(pair, id, b.sellX)) revert DlmmLimitOrders__NotFilled();
            _execute(pair, id, epoch, b);
        }
        sharesOf[k][msg.sender] = 0;
        amountX = Math.mulDiv(b.amountX, s, b.shares);
        amountY = Math.mulDiv(b.amountY, s, b.shares);
        _pay(pair, to, amountX, amountY, unwrap);
        emit OrderClaimed(msg.sender, pair, id, epoch, amountX, amountY);
    }

    // ------------------------------------------------------------------ views

    function getBatch(address pair, uint24 id, uint256 epoch) external view returns (Batch memory) {
        return _batches[_key(pair, id, epoch)];
    }

    /// Every order `owner` has placed (claimed and cancelled ones included, with 0 shares).
    function ordersOf(address owner) external view returns (OrderRef[] memory) {
        return _orders[owner];
    }

    /// One order's state. Before execution the amounts are what the shares are worth in the bin now
    /// (what `cancel` would return); after it, what `claim` pays.
    function orderInfo(address pair, uint24 id, uint256 epoch, address owner)
        external
        view
        returns (uint256 shares, bool sellX, bool executed, bool filled, uint256 amountX, uint256 amountY)
    {
        bytes32 k = _key(pair, id, epoch);
        Batch memory b = _batches[k];
        shares = sharesOf[k][owner];
        sellX = b.sellX;
        executed = b.executed;
        if (executed) {
            filled = true;
            if (shares != 0) {
                amountX = Math.mulDiv(b.amountX, shares, b.shares);
                amountY = Math.mulDiv(b.amountY, shares, b.shares);
            }
        } else if (b.shares != 0) {
            filled = _filled(pair, id, sellX);
            if (shares != 0) {
                uint256 supply = DlmmPair(pair).totalSupply(id);
                (uint128 rx, uint128 ry) = DlmmPair(pair).getBin(id);
                amountX = Math.mulDiv(rx, shares, supply);
                amountY = Math.mulDiv(ry, shares, supply);
            }
        }
    }

    function openBooks() external view returns (Book[] memory) {
        return _open;
    }

    /// Books whose open batch is filled and waiting for `execute`.
    function readyBooks() external view returns (Book[] memory ready) {
        uint256 n = _open.length;
        Book[] memory tmp = new Book[](n);
        uint256 m;
        for (uint256 i; i < n; ++i) {
            Book memory bk = _open[i];
            Batch storage b = _batches[_key(bk.pair, bk.id, currentEpoch[bk.pair][bk.id])];
            if (_filled(bk.pair, bk.id, b.sellX)) tmp[m++] = bk;
        }
        ready = new Book[](m);
        for (uint256 i; i < m; ++i) {
            ready[i] = tmp[i];
        }
    }

    // ------------------------------------------------------------------ internals

    function _key(address pair, uint24 id, uint256 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(pair, id, epoch));
    }

    /// The price has crossed the whole bin: it holds none of the token the batch put in.
    function _filled(address pair, uint24 id, bool sellX) internal view returns (bool) {
        uint24 active = DlmmPair(pair).getActiveId();
        if (sellX ? active > id : active < id) return true;
        if (active != id) return false;
        (uint128 rx, uint128 ry) = DlmmPair(pair).getBin(id);
        return sellX ? rx == 0 : ry == 0;
    }

    function _execute(address pair, uint24 id, uint256 epoch, Batch storage b) internal {
        (uint256 x, uint256 y) = _burn(pair, id, b.shares);
        b.amountX = x;
        b.amountY = y;
        b.executed = true;
        currentEpoch[pair][id] = epoch + 1;
        _removeOpen(pair, id);
        emit BatchExecuted(pair, id, epoch, msg.sender, b.shares, x, y);
    }

    /// Burn `shares` of bin `id` into this contract; returns what actually arrived.
    function _burn(address pair, uint24 id, uint256 shares) internal returns (uint256 x, uint256 y) {
        DlmmPair p = DlmmPair(pair);
        IERC20 tX = IERC20(p.tokenX());
        IERC20 tY = IERC20(p.tokenY());
        uint256 bx = tX.balanceOf(address(this));
        uint256 by = tY.balanceOf(address(this));
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = shares;
        p.burn(address(this), address(this), ids, amounts);
        x = tX.balanceOf(address(this)) - bx;
        y = tY.balanceOf(address(this)) - by;
    }

    function _pay(address pair, address to, uint256 x, uint256 y, bool unwrap) internal {
        if (x != 0) _send(DlmmPair(pair).tokenX(), to, x, unwrap);
        if (y != 0) _send(DlmmPair(pair).tokenY(), to, y, unwrap);
    }

    function _send(address token, address to, uint256 amount, bool unwrap) internal {
        if (unwrap && token == weth) {
            IWrappedNative(weth).withdraw(amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert DlmmLimitOrders__NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _addOpen(address pair, uint24 id) internal {
        bytes32 k = keccak256(abi.encode(pair, id));
        if (_openIndex[k] != 0) return;
        _open.push(Book(pair, id));
        _openIndex[k] = _open.length;
    }

    function _removeOpen(address pair, uint24 id) internal {
        bytes32 k = keccak256(abi.encode(pair, id));
        uint256 i = _openIndex[k];
        if (i == 0) return;
        Book memory last = _open[_open.length - 1];
        _open[i - 1] = last;
        _openIndex[keccak256(abi.encode(last.pair, last.id))] = i;
        _open.pop();
        delete _openIndex[k];
    }
}

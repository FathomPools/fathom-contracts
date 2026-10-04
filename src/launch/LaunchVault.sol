// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {LaunchPools} from "./LaunchPools.sol";

/// Pre-launch vaults for LaunchPools: pool ETH before a token exists, buy it at launch in one swap,
/// share the tokens pro rata.
///
/// - `open` schedules a launch: its LaunchPools parameters are checked (LaunchPools.preview) and
///   stored, and deposits open until `depositEnd` (at most MAX_WINDOW ahead). Nothing can change the
///   parameters afterwards.
/// - Before `depositEnd` anyone can `deposit` ETH and `withdraw` any part of their own deposit.
/// - From `depositEnd` until `depositEnd + LAUNCH_WINDOW` anyone can call `launch`. LaunchPools
///   deploys the token, seeds its pool and spends the vault's whole balance on the token as the pool's
///   first swap, in that one transaction: nobody can trade ahead of it, and every depositor pays the
///   same average price. The swap pays the anti-snipe start fee, and LaunchPools pays the LP share of
///   that fee back with the tokens; only the hook's protocol share stays charged.
/// - After the launch every depositor can `claim` their pro-rata share of the tokens bought and of the
///   ETH paid back (deposit / total deposits, rounded down; at most a few wei stay here).
/// - If nobody launched before `depositEnd + LAUNCH_WINDOW` (e.g. the protocol stayed paused), every
///   depositor can `refund` their whole deposit.
/// - No owner and no fee. The unseeded supply and the launch position's fees go to the creator named
///   in the parameters, exactly as with a direct LaunchPools launch.
contract LaunchVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Vault {
        address opener;
        uint40 depositEnd; // deposits and withdrawals while block.timestamp < depositEnd
        bool launched;
        uint256 totalDeposits; // frozen at launch: the base of every claim
        address token;
        PoolId poolId;
        uint256 tokensBought;
        uint256 ethBack; // ETH LaunchPools paid back at launch (LP share of the launch fee)
    }

    uint256 public constant MAX_WINDOW = 7 days;
    uint256 public constant LAUNCH_WINDOW = 3 days;

    LaunchPools public immutable launchPools;

    uint256 public vaultCount; // ids are 1..vaultCount
    mapping(uint256 => Vault) internal _vaults;
    mapping(uint256 => LaunchPools.LaunchParams) internal _params;
    mapping(uint256 => mapping(address => uint256)) public depositOf;
    /// Claimed (after a launch) or refunded (after an expiry).
    mapping(uint256 => mapping(address => bool)) public settled;

    event VaultOpened(
        uint256 indexed id, address indexed opener, address indexed creator, uint40 depositEnd, string name, string symbol
    );
    event Deposited(uint256 indexed id, address indexed account, uint256 amount);
    event Withdrawn(uint256 indexed id, address indexed account, uint256 amount);
    event VaultLaunched(
        uint256 indexed id, PoolId indexed poolId, address token, address caller, uint256 ethIn, uint256 tokensBought, uint256 ethBack
    );
    event Claimed(uint256 indexed id, address indexed account, uint256 tokens, uint256 eth);
    event Refunded(uint256 indexed id, address indexed account, uint256 amount);

    error LaunchVault__UnknownVault();
    error LaunchVault__BadWindow();
    error LaunchVault__DepositsClosed();
    error LaunchVault__DepositsOpen();
    error LaunchVault__ZeroAmount();
    error LaunchVault__BadAmount();
    error LaunchVault__AlreadyLaunched();
    error LaunchVault__LaunchExpired();
    error LaunchVault__NotLaunched();
    error LaunchVault__NotRefundable();
    error LaunchVault__NothingToClaim();
    error LaunchVault__NotLaunchPools();
    error LaunchVault__NativeTransferFailed();

    constructor(LaunchPools launchPools_) {
        launchPools = launchPools_;
    }

    /// ETH paid back by LaunchPools at launch.
    receive() external payable {
        if (msg.sender != address(launchPools)) revert LaunchVault__NotLaunchPools();
    }

    // ---------------------------------------------------------------- lifecycle

    /// Schedule a launch with `p` (checked now, launched later) and open deposits until `depositEnd`.
    function open(LaunchPools.LaunchParams calldata p, uint40 depositEnd) external returns (uint256 id) {
        launchPools.preview(p);
        if (depositEnd <= block.timestamp || depositEnd > block.timestamp + MAX_WINDOW) revert LaunchVault__BadWindow();
        id = ++vaultCount;
        Vault storage v = _vaults[id];
        v.opener = msg.sender;
        v.depositEnd = depositEnd;
        _params[id] = p;
        emit VaultOpened(id, msg.sender, p.creator, depositEnd, p.name, p.symbol);
    }

    function deposit(uint256 id) external payable nonReentrant {
        Vault storage v = _vaults[id];
        if (v.depositEnd == 0) revert LaunchVault__UnknownVault();
        if (block.timestamp >= v.depositEnd) revert LaunchVault__DepositsClosed();
        if (msg.value == 0) revert LaunchVault__ZeroAmount();
        depositOf[id][msg.sender] += msg.value;
        v.totalDeposits += msg.value;
        emit Deposited(id, msg.sender, msg.value);
    }

    function withdraw(uint256 id, uint256 amount) external nonReentrant {
        Vault storage v = _vaults[id];
        if (v.depositEnd == 0) revert LaunchVault__UnknownVault();
        if (block.timestamp >= v.depositEnd) revert LaunchVault__DepositsClosed();
        uint256 d = depositOf[id][msg.sender];
        if (amount == 0 || amount > d) revert LaunchVault__BadAmount();
        depositOf[id][msg.sender] = d - amount;
        v.totalDeposits -= amount;
        _sendEth(msg.sender, amount);
        emit Withdrawn(id, msg.sender, amount);
    }

    /// Permissionless once deposits have closed: launch with the vault's whole balance as the first buy.
    /// With no deposits it launches without a buy.
    function launch(uint256 id) external nonReentrant returns (address token, PoolId poolId, uint256 bought) {
        Vault storage v = _vaults[id];
        if (v.depositEnd == 0) revert LaunchVault__UnknownVault();
        if (v.launched) revert LaunchVault__AlreadyLaunched();
        if (block.timestamp < v.depositEnd) revert LaunchVault__DepositsOpen();
        if (block.timestamp >= uint256(v.depositEnd) + LAUNCH_WINDOW) revert LaunchVault__LaunchExpired();
        v.launched = true;

        uint256 total = v.totalDeposits;
        uint256 kept = address(this).balance - total; // every other vault's ETH
        (token, poolId, bought) = launchPools.launch{value: total}(_params[id]);
        uint256 back = address(this).balance - kept;
        v.token = token;
        v.poolId = poolId;
        v.tokensBought = bought;
        v.ethBack = back;
        emit VaultLaunched(id, poolId, token, msg.sender, total, bought, back);
    }

    /// After the launch: the caller's pro-rata share of the tokens bought and of the ETH paid back.
    function claim(uint256 id) external nonReentrant returns (uint256 tokens, uint256 eth) {
        Vault storage v = _vaults[id];
        if (!v.launched) revert LaunchVault__NotLaunched();
        uint256 d = depositOf[id][msg.sender];
        if (d == 0 || settled[id][msg.sender]) revert LaunchVault__NothingToClaim();
        settled[id][msg.sender] = true;
        (tokens, eth) = _share(v, d);
        if (tokens != 0) IERC20(v.token).safeTransfer(msg.sender, tokens);
        if (eth != 0) _sendEth(msg.sender, eth);
        emit Claimed(id, msg.sender, tokens, eth);
    }

    /// Nobody launched in time: the caller's whole deposit back.
    function refund(uint256 id) external nonReentrant returns (uint256 amount) {
        Vault storage v = _vaults[id];
        if (v.depositEnd == 0) revert LaunchVault__UnknownVault();
        if (v.launched || block.timestamp < uint256(v.depositEnd) + LAUNCH_WINDOW) revert LaunchVault__NotRefundable();
        amount = depositOf[id][msg.sender];
        if (amount == 0 || settled[id][msg.sender]) revert LaunchVault__NothingToClaim();
        settled[id][msg.sender] = true;
        _sendEth(msg.sender, amount);
        emit Refunded(id, msg.sender, amount);
    }

    // ---------------------------------------------------------------- views

    function getVault(uint256 id) external view returns (Vault memory) {
        return _vaults[id];
    }

    function getParams(uint256 id) external view returns (LaunchPools.LaunchParams memory) {
        return _params[id];
    }

    /// What `claim` pays `account` now (0, 0 before the launch or once settled).
    function claimable(uint256 id, address account) external view returns (uint256 tokens, uint256 eth) {
        Vault storage v = _vaults[id];
        if (!v.launched || settled[id][account]) return (0, 0);
        return _share(v, depositOf[id][account]);
    }

    function _share(Vault storage v, uint256 d) internal view returns (uint256 tokens, uint256 eth) {
        if (d == 0) return (0, 0);
        uint256 total = v.totalDeposits;
        tokens = Math.mulDiv(v.tokensBought, d, total);
        eth = Math.mulDiv(v.ethBack, d, total);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert LaunchVault__NativeTransferFailed();
    }
}

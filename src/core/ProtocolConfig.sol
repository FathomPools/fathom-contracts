// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// Protocol-wide settings shared by every Fathom venue. Immutable (no proxy); the owner can only
/// tune parameters and pause. Pause blocks swaps and new liquidity; withdrawals must never check it.
contract ProtocolConfig is Ownable2Step {
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5000;

    bool public paused;
    address public feeCollector;
    /// Share of every swap fee (in bps of the fee) routed to the FeeCollector. Default 20 %.
    uint16 public protocolFeeShareBps = 2000;

    event Paused(bool paused);
    event FeeCollectorSet(address feeCollector);
    event ProtocolFeeShareSet(uint16 bps);

    error ZeroAddress();
    error ShareTooHigh();

    constructor(address owner_, address feeCollector_) Ownable(owner_) {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        feeCollector = feeCollector_;
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit Paused(p);
    }

    function setFeeCollector(address c) external onlyOwner {
        if (c == address(0)) revert ZeroAddress();
        feeCollector = c;
        emit FeeCollectorSet(c);
    }

    function setProtocolFeeShareBps(uint16 bps) external onlyOwner {
        if (bps > MAX_PROTOCOL_SHARE_BPS) revert ShareTooHigh();
        protocolFeeShareBps = bps;
        emit ProtocolFeeShareSet(bps);
    }
}

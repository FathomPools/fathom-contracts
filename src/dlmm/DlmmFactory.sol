// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolConfig} from "../core/ProtocolConfig.sol";
import {DlmmPair, DlmmFeeParams} from "./DlmmPair.sol";

/// Permissionless DLMM pair factory. The ProtocolConfig owner curates which bin steps are allowed
/// and their fee presets; presets are copied into a pair at creation (later edits only affect new
/// pairs). One pair per unordered token pair and bin step.
contract DlmmFactory {
    struct Preset {
        DlmmFeeParams params;
        bool enabled;
    }

    uint16 public constant MAX_BIN_STEP = 100;

    ProtocolConfig public immutable config;

    mapping(uint16 => Preset) internal _presets;
    mapping(address => mapping(address => mapping(uint16 => address))) public getPair;
    mapping(address => bool) public isPair;
    address[] public allPairs;

    event PairCreated(
        address indexed tokenX, address indexed tokenY, uint16 indexed binStep, address pair, uint24 activeId
    );
    event PresetSet(uint16 indexed binStep, DlmmFeeParams params, bool enabled);

    error DlmmFactory__NotOwner();
    error DlmmFactory__Paused();
    error DlmmFactory__InvalidTokens();
    error DlmmFactory__BinStepNotAllowed(uint16 binStep);
    error DlmmFactory__PairExists();
    error DlmmFactory__InvalidPreset();

    constructor(ProtocolConfig config_) {
        config = config_;
        // Default presets. baseFactor 1e4 => base fee == binStep in bps. variableFeeControl is scaled
        // so the variable fee tops out around 1 % at maxVolatilityAccumulator.
        _setPreset(1, _defaults(20_000, 8_000_000));
        _setPreset(5, _defaults(10_000, 320_000));
        _setPreset(10, _defaults(10_000, 80_000));
        _setPreset(25, _defaults(8_000, 13_000));
        _setPreset(50, _defaults(8_000, 3_200));
        _setPreset(100, _defaults(8_000, 800));
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function getPreset(uint16 binStep) external view returns (DlmmFeeParams memory params, bool enabled) {
        Preset memory p = _presets[binStep];
        return (p.params, p.enabled);
    }

    function setPreset(uint16 binStep, DlmmFeeParams calldata params, bool enabled) external {
        if (msg.sender != config.owner()) revert DlmmFactory__NotOwner();
        _setPreset(binStep, Preset({params: params, enabled: enabled}));
    }

    function createPair(address tokenX, address tokenY, uint16 binStep, uint24 activeId)
        external
        returns (address pair)
    {
        if (config.paused()) revert DlmmFactory__Paused();
        if (tokenX == tokenY || tokenX == address(0) || tokenY == address(0)) revert DlmmFactory__InvalidTokens();
        Preset memory p = _presets[binStep];
        if (!p.enabled) revert DlmmFactory__BinStepNotAllowed(binStep);
        if (getPair[tokenX][tokenY][binStep] != address(0)) revert DlmmFactory__PairExists();

        pair = address(
            new DlmmPair{salt: keccak256(abi.encode(tokenX, tokenY, binStep))}(
                config, tokenX, tokenY, binStep, activeId, p.params
            )
        );
        getPair[tokenX][tokenY][binStep] = pair;
        getPair[tokenY][tokenX][binStep] = pair;
        isPair[pair] = true;
        allPairs.push(pair);
        emit PairCreated(tokenX, tokenY, binStep, pair, activeId);
    }

    function _setPreset(uint16 binStep, Preset memory p) internal {
        if (binStep == 0 || binStep > MAX_BIN_STEP) revert DlmmFactory__InvalidPreset();
        if (p.params.reductionFactor > 10_000 || p.params.filterPeriod >= p.params.decayPeriod) {
            revert DlmmFactory__InvalidPreset();
        }
        _presets[binStep] = p;
        emit PresetSet(binStep, p.params, p.enabled);
    }

    function _defaults(uint16 baseFactor, uint24 variableFeeControl) internal pure returns (Preset memory) {
        return Preset({
            params: DlmmFeeParams({
                baseFactor: baseFactor,
                filterPeriod: 30,
                decayPeriod: 600,
                reductionFactor: 5_000,
                variableFeeControl: variableFeeControl,
                maxVolatilityAccumulator: 350_000
            }),
            enabled: true
        });
    }
}

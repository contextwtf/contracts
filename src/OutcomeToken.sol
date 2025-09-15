// SPDX-License-Identifier: BUSL-1.1
// Read full license and terms at https://github.com/contextwtf/contracts
pragma solidity ^0.8.19;

import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title Outcome Token
 * @notice ERC20 token representing outcomes for an option in a prediction market
 * @dev Inherits from Solady's ERC20 implementation with custom storage pattern
 */
contract OutcomeToken is ERC20 {
    struct TokenStorage {
        bool initialized;
        address predictionMarket;
        address pendingPredictionMarket;
        string name;
        string symbol;
    }

    TokenStorage private _storage;

    event PredictionMarketTransferInitiated(address indexed from, address indexed to);
    event PredictionMarketTransferAccepted(address indexed newPredictionMarket);

    error NotPredictionMarket();
    error AlreadyInitialized();

    function initialize(string memory name_, string memory symbol_, address predictionMarket_) external {
        if (_storage.initialized) revert AlreadyInitialized();
        if (predictionMarket_ == address(0)) revert NotPredictionMarket();

        _storage.name = name_;
        _storage.symbol = symbol_;
        _storage.predictionMarket = predictionMarket_;
        _storage.initialized = true;
    }

    modifier onlyPredictionMarket() {
        if (msg.sender != _storage.predictionMarket) revert NotPredictionMarket();
        _;
    }

    function setPendingPredictionMarket(address pendingPredictionMarket) external onlyPredictionMarket {
        _storage.pendingPredictionMarket = pendingPredictionMarket;
        emit PredictionMarketTransferInitiated(_storage.predictionMarket, pendingPredictionMarket);
    }

    function predictionMarket() external view returns (address) {
        return _storage.predictionMarket;
    }

    function acceptPredictionMarket() external {
        require(msg.sender == _storage.pendingPredictionMarket);
        _storage.predictionMarket = _storage.pendingPredictionMarket;
        _storage.pendingPredictionMarket = address(0);
        emit PredictionMarketTransferAccepted(_storage.predictionMarket);
    }

    function name() public view override returns (string memory) {
        return _storage.name;
    }

    function symbol() public view override returns (string memory) {
        return _storage.symbol;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyPredictionMarket {
        _mint(to, amount);
    }

    function burn(address account, uint256 amount) external onlyPredictionMarket {
        _burn(account, amount);
    }
}

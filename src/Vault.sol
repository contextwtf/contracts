// SPDX-License-Identifier: BUSL-1.1
// Read full license and terms at https://github.com/contextwtf/contracts
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {PredictionMarket} from "./PredictionMarket.sol";

/**
 * @title Vault
 * @notice Manages locking and staking of outcome tokens with optional admin-sponsored purchases
 */
contract Vault is Ownable {
    PredictionMarket public predictionMarket;
    IERC20 public usdc;

    // marketId => user => amounts[] (index i matches market.outcomeTokens[i])
    mapping(bytes32 => mapping(address => uint256[])) public locked;
    mapping(bytes32 => mapping(address => uint256[])) public staked;

    // Sponsored nonces: buyer => nonce => used
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    address public adminSigner;

    event LockUpdated(bytes32 indexed marketId, address indexed locker, uint256[] amounts);
    event Unlocked(bytes32 indexed marketId, address indexed locker, uint256[] amounts);
    event StakeUpdated(bytes32 indexed marketId, address indexed staker, uint256[] amounts);
    event SponsoredLocked(
        bytes32 indexed marketId,
        address indexed user,
        uint256 setsAmount,
        uint256 userPaid,
        uint256 subsidyUsed,
        uint256 actualCost,
        uint256 outcomes,
        uint256 nonce
    );
    event AdminSignerUpdated(address indexed oldSigner, address indexed newSigner);

    error InvalidMarket();
    error InvalidAmounts();
    error MarketResolved();
    error MarketNotResolved();
    error NoLockedTokens();
    error InsufficientStake();
    error InvalidSignature();
    error InvalidTrade();
    error NonceAlreadyUsed();
    error InsufficientContractFunds();
    error SubsidyExceeded();
    error ZeroAddress();
    error TransferFailed();

    bytes32 private constant TAG = keccak256("Vault-v1");

    constructor(address _predictionMarket, address _adminSigner, address _owner) {
        _initializeOwner(_owner);
        predictionMarket = PredictionMarket(_predictionMarket);
        usdc = PredictionMarket(_predictionMarket).usdc();
        if (_adminSigner == address(0)) revert ZeroAddress();
        emit AdminSignerUpdated(address(0), _adminSigner);
        adminSigner = _adminSigner;

        usdc.approve(_predictionMarket, type(uint256).max);
    }

    function setAdminSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit AdminSignerUpdated(adminSigner, newSigner);
        adminSigner = newSigner;
    }

    function setUsdcAllowance(uint256 amount) external onlyOwner {
        usdc.approve(address(predictionMarket), amount);
    }

    function withdrawUsdc(uint256 amount, address to) external onlyOwner {
        if (!usdc.transfer(to, amount)) revert TransferFailed();
    }

    // ========= Locking =========

    /**
     * @notice Locks outcome tokens until market resolution
     * @param marketId The market ID to lock tokens for
     * @param amounts Array of token amounts to lock for each outcome
     */
    function addLock(bytes32 marketId, uint256[] calldata amounts) external {
        if (!predictionMarket.marketExists(marketId)) revert InvalidMarket();

        PredictionMarket.MarketInfo memory m = predictionMarket.getMarketInfo(marketId);
        if (m.resolved) revert MarketResolved();
        if (amounts.length != m.outcomeTokens.length) revert InvalidAmounts();

        uint256[] storage lock = locked[marketId][msg.sender];
        if (lock.length == 0) {
            locked[marketId][msg.sender] = new uint256[](amounts.length);
        }

        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] > 0) {
                if (!IERC20(m.outcomeTokens[i]).transferFrom(msg.sender, address(this), amounts[i])) {
                    revert TransferFailed();
                }
                lock[i] += amounts[i];
            }
        }

        emit LockUpdated(marketId, msg.sender, lock);
    }

    /**
     * @notice Unlocks and returns all locked tokens after market resolution
     * @param marketId The market ID to unlock tokens from
     */
    function unlock(bytes32 marketId) external {
        uint256[] storage lock = locked[marketId][msg.sender];
        if (lock.length == 0) revert NoLockedTokens();

        PredictionMarket.MarketInfo memory m = predictionMarket.getMarketInfo(marketId);
        if (!m.resolved) revert MarketNotResolved();

        uint256[] memory unlockedAmounts = lock;
        delete locked[marketId][msg.sender];

        for (uint256 i = 0; i < unlockedAmounts.length; i++) {
            if (unlockedAmounts[i] > 0) {
                if (!IERC20(m.outcomeTokens[i]).transfer(msg.sender, unlockedAmounts[i])) revert TransferFailed();
            }
        }

        emit Unlocked(marketId, msg.sender, unlockedAmounts);
    }

    // ========= Staking =========

    /**
     * @notice Stakes outcome tokens in the vault
     * @dev Staked tokens can be removed at any time unlike locked tokens
     * @param marketId The market ID to stake tokens for
     * @param amounts Array of token amounts to stake for each outcome
     */
    function addStake(bytes32 marketId, uint256[] calldata amounts) external {
        if (!predictionMarket.marketExists(marketId)) revert InvalidMarket();

        PredictionMarket.MarketInfo memory m = predictionMarket.getMarketInfo(marketId);
        if (m.resolved) revert MarketResolved();
        if (amounts.length != m.outcomeTokens.length) revert InvalidAmounts();

        uint256[] storage stake = staked[marketId][msg.sender];
        if (stake.length == 0) {
            staked[marketId][msg.sender] = new uint256[](amounts.length);
        }

        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] > 0) {
                if (!IERC20(m.outcomeTokens[i]).transferFrom(msg.sender, address(this), amounts[i])) {
                    revert TransferFailed();
                }
                stake[i] += amounts[i];
            }
        }

        emit StakeUpdated(marketId, msg.sender, stake);
    }

    /**
     * @notice Removes staked outcome tokens from the vault
     * @dev Can be called at any time to withdraw staked tokens
     * @param marketId The market ID to remove stake from
     * @param amounts Array of token amounts to remove for each outcome
     */
    function removeStake(bytes32 marketId, uint256[] calldata amounts) external {
        if (!predictionMarket.marketExists(marketId)) revert InvalidMarket();

        uint256[] storage stake = staked[marketId][msg.sender];
        if (stake.length == 0) revert InsufficientStake();
        if (amounts.length != stake.length) revert InvalidAmounts();

        PredictionMarket.MarketInfo memory m = predictionMarket.getMarketInfo(marketId);

        bool hasRemaining = false;

        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] > 0) {
                if (stake[i] < amounts[i]) revert InsufficientStake();
                stake[i] -= amounts[i];
                if (!IERC20(m.outcomeTokens[i]).transfer(msg.sender, amounts[i])) revert TransferFailed();
            }
            if (stake[i] > 0) hasRemaining = true;
        }

        if (!hasRemaining) {
            delete staked[marketId][msg.sender];
        }

        emit StakeUpdated(marketId, msg.sender, stake);
    }

    // ========= Sponsored locking =========

    /**
     * @notice Purchases and locks complete outcome sets with admin-signed subsidy
     * @dev Uses admin signature to authorize subsidy. Purchases equal amounts of all outcomes
     * @param marketId The market ID to purchase and lock tokens for
     * @param setsAmount Amount of each outcome token to purchase
     * @param subsidyAmount Maximum USDC subsidy allowed from vault
     * @param deadline Timestamp when the signature expires
     * @param nonce Unique nonce to prevent replay attacks
     * @param signature Admin signature authorizing the subsidized purchase
     */
    function sponsoredLock(
        bytes32 marketId,
        uint256 setsAmount,
        uint256 subsidyAmount,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external {
        if (setsAmount == 0) revert InvalidAmounts();
        if (!predictionMarket.marketExists(marketId)) revert InvalidMarket();

        PredictionMarket.MarketInfo memory m = predictionMarket.getMarketInfo(marketId);
        if (m.resolved || m.paused) revert MarketResolved();
        if (block.timestamp > deadline) revert InvalidSignature();

        address buyer = msg.sender;
        if (usedNonces[buyer][nonce]) revert NonceAlreadyUsed();

        bytes32 message = EfficientHashLib.hash(
            abi.encode(TAG, address(this), block.chainid, marketId, setsAmount, subsidyAmount, buyer, deadline, nonce)
        );
        bytes32 digest = SignatureCheckerLib.toEthSignedMessageHash(message);
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(adminSigner, digest, signature)) {
            revert InvalidSignature();
        }
        usedNonces[buyer][nonce] = true;

        if (!usdc.transferFrom(buyer, address(this), setsAmount)) revert TransferFailed();

        uint256 maxCost = setsAmount + subsidyAmount;
        if (usdc.balanceOf(address(this)) < maxCost) revert InsufficientContractFunds();

        uint256 n = m.outcomeTokens.length;
        int256[] memory delta = new int256[](n);
        for (uint256 i = 0; i < n; i++) {
            delta[i] = int256(setsAmount);
        }

        PredictionMarket.Trade memory t = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: delta,
            maxCost: maxCost,
            minPayout: 0,
            deadline: block.timestamp
        });

        int256 costDelta = predictionMarket.trade(t);
        if (costDelta <= 0) revert InvalidTrade();
        uint256 actualCost = uint256(costDelta);

        uint256 actualSubsidy = actualCost > setsAmount ? actualCost - setsAmount : 0;
        if (actualSubsidy > subsidyAmount) revert SubsidyExceeded();

        uint256[] storage lock = locked[marketId][buyer];
        if (lock.length == 0) {
            locked[marketId][buyer] = new uint256[](n);
        }
        for (uint256 i = 0; i < n; i++) {
            lock[i] += setsAmount;
        }

        emit SponsoredLocked(marketId, buyer, setsAmount, setsAmount, actualSubsidy, actualCost, n, nonce);
        emit LockUpdated(marketId, buyer, lock);
    }
}

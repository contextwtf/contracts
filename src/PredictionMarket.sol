// SPDX-License-Identifier: BUSL-1.1
// Read full license and terms at https://github.com/contextwtf/contracts
pragma solidity ^0.8.19;

/*

                                         -@@@@@@#                 
                                        .@@@@@@@.                 
                                        %@@@@@@:                  
           .#*-.                       *@@@@@@=                   
           #@@@@#+:                   +@@@@@@*                    
          *@@@@@@@@@*=.              -@@@@@@%                     
          -+%@@@@@@@@@@%+-.         .@@@@@@@.                     
             .-*%@@@@@@@@@@#=:      %@@@@@@-                      
                 :=#@@@@@@@@@@%*=. *@@@@@@=                       
                     .=*%@@@@@@@@@%@@@@@@*                        
      =*************++++#@@@@@@@@@@@@@@@%                         
     -@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@:                         
    -@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@:                          
    =========================+=%@@@@@@%=+++++++++++++++++++++++++=
                              -@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@:
                             :@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@- 
                             %@@@@@@@@@@@@@@@*++++****++++++++*=  
                            #@@@@@@%@@@@@@@@@%*=.                 
                           +@@@@@@+ .-*%@@@@@@@@@@#=:             
                          -@@@@@@#      :=#@@@@@@@@@@%*-.         
                         .@@@@@@@.         .-+%@@@@@@@@@@%+-      
                         %@@@@@@:              .=*%@@@@@@@@*      
                        *@@@@@@=                   :+#@@@@#       
                       +@@@@@@*                       .-*#        
                      -@@@@@@%                                    
                     .@@@@@@@.                                    
                     #@@@@@@-                                     

    ░█████╗░░█████╗░███╗░░██╗████████╗███████╗██╗░░██╗████████╗
    ██╔══██╗██╔══██╗████╗░██║╚══██╔══╝██╔════╝╚██╗██╔╝╚══██╔══╝
    ██║░░╚═╝██║░░██║██╔██╗██║░░░██║░░░█████╗░░░╚███╔╝░░░░██║░░░
    ██║░░██╗██║░░██║██║╚████║░░░██║░░░██╔══╝░░░██╔██╗░░░░██║░░░
    ╚█████╔╝╚█████╔╝██║░╚███║░░░██║░░░███████╗██╔╝╚██╗░░░██║░░░
    ░╚════╝░░╚════╝░╚═╝░░╚══╝░░░╚═╝░░░╚══════╝╚═╝░░╚═╝░░░╚═╝░░░

    ███╗░░░███╗░█████╗░██████╗░██╗░░██╗███████╗████████╗░██████╗
    ████╗░████║██╔══██╗██╔══██╗██║░██╔╝██╔════╝╚══██╔══╝██╔════╝
    ██╔████╔██║███████║██████╔╝█████═╝░█████╗░░░░░██║░░░╚█████╗░
    ██║╚██╔╝██║██╔══██║██╔══██╗██╔═██╗░██╔══╝░░░░░██║░░░░╚═══██╗
    ██║░╚═╝░██║██║░░██║██║░░██║██║░╚██╗███████╗░░░██║░░░██████╔╝
    ╚═╝░░░░░╚═╝╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░╚═╝╚══════╝░░░╚═╝░░░╚═════╝░

*/

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {OutcomeToken} from "./OutcomeToken.sol";

/**
 * @title Prediction Market
 * @notice A prediction market using liquidity sensitive LMSR for outcome pricing
 */
contract PredictionMarket is OwnableRoles {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    uint256 public constant ONE = 1e6;
    uint256 public constant DEFAULT_TARGET_VIG = 70_000;
    uint256 public constant DEFAULT_INITIAL_SHARES_PER_OUTCOME = 20e6;
    uint256 public constant DEFAULT_FEE_PER_OUTCOME = 30e6;
    uint256 public constant COST_ROUNDING_BUFFER = 1;
    int256 public constant QUOTE_TRADE_ROUNDING_BUFFER = 1;

    uint256 public constant PROTOCOL_MANAGER_ROLE = 1 << 0;
    uint256 public constant MARKET_CREATOR_ROLE = 1 << 1;

    struct CreateMarketParams {
        address oracle;
        uint256 initialBuyMaxCost;
        bytes32 questionId;
        address surplusRecipient;
        bytes metadata;
        int256[] initialBuyShares;
        string[] outcomeNames;
    }

    struct MarketInfo {
        address oracle;
        bool resolved;
        bool paused;
        uint256 alpha;
        uint256 totalUsdcIn;
        address creator;
        bytes32 questionId;
        address surplusRecipient;
        uint256[] outcomeQs;
        address[] outcomeTokens;
        uint256[] payoutPcts;
        uint256 initialSharesPerOutcome;
    }

    struct Trade {
        bytes32 marketId;
        int256[] deltaShares; // Positive = buy, negative = sell
        uint256 maxCost; // Maximum USDC to spend (for net buys)
        uint256 minPayout; // Minimum USDC to receive (for net sells)
        uint256 deadline;
    }

    struct ExponentialTerms {
        uint256[] expTerms;
        uint256 sumExp;
        int256 offset;
    }

    enum MigrationState {
        None,
        Initiated,
        Finalized,
        Aborted
    }

    IERC20 public usdc;
    address public outcomeTokenImplementation;

    uint256 public targetVig;
    uint256 public feePerOutcome;
    uint256 public initialSharesPerOutcome;
    bool public allowAnyMarketCreator;
    bool private _initialized;

    mapping(bytes32 => MarketInfo) public markets;
    mapping(address => bytes32) public tokenToMarketId;
    mapping(address => uint256) public tokenToOutcomeIndex;
    mapping(bytes32 => bytes32) public questionIdToMarketId;
    mapping(address => uint256) public surplus;

    uint256 internal constant MIN_OUTCOMES = 2;
    uint256 internal maxOutcomes;
    address public migrationContract;
    mapping(bytes32 => MigrationState) public marketMigrationState;
    bool public letCreatorsMigrate;

    event MarketCreated(
        bytes32 indexed marketId,
        address indexed oracle,
        bytes32 indexed questionId,
        address surplusRecipient,
        address creator,
        bytes metadata,
        uint256 alpha,
        uint256 marketCreationFee,
        address[] outcomeTokens,
        string[] outcomeNames,
        uint256[] outcomeQs
    );
    event MarketResolved(bytes32 indexed marketId, uint256[] payoutPcts, uint256 surplus);
    event MarketTraded(
        bytes32 indexed marketId,
        address indexed trader,
        uint256 alpha,
        int256 usdcFlow,
        int256[] deltaShares,
        uint256[] outcomeQs
    );
    event TokensRedeemed(
        bytes32 indexed marketId, address indexed redeemer, address token, uint256 shares, uint256 payout
    );
    event SurplusWithdrawn(address indexed to, uint256 amount);
    event AllowAnyMarketCreatorUpdated(bool allow);
    event MarketPausedUpdated(bytes32 indexed marketId, bool paused);
    event FeePerOutcomeUpdated(uint256 oldFee, uint256 newFee);
    event TargetVigUpdated(uint256 oldTargetVig, uint256 newTargetVig);
    event InitialSharesPerOutcomeUpdated(uint256 oldShares, uint256 newShares);
    event MaxOutcomesUpdated(uint256 oldMaxOutcomes, uint256 newMaxOutcomes);
    event MigrationContractSet(address migrationContract);
    event MarketMigrationInitiated(bytes32 indexed marketId);
    event MarketMigrationFinalized(bytes32 indexed marketId, uint256 usdcTransferred);
    event MarketMigrationAborted(bytes32 indexed marketId);
    event LetCreatorsMigrateUpdated(bool allow);

    error CallerNotOracle();
    error CallerNotMarketCreator();
    error CallerNotMigrationContract();
    error DuplicateQuestionId();
    error EmptyOutcomeName();
    error EmptyQuestionId();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error InvalidFee();
    error InvalidMarketState();
    error InvalidOracle();
    error InvalidPayout();
    error InvalidInitialShares();
    error InvalidMaxOutcomes();
    error InvalidTargetVig();
    error InvalidNumOutcomes();
    error MarketInsolvent();
    error InvalidMigrationState();
    error InvalidMigrationContract();
    error ParameterOutOfRange();
    error MarketDoesNotExist();
    error InvalidSurplusRecipient();
    error ZeroSurplus();
    error BuysOnly();
    error InitialFundingInvariantViolation();
    error TradeExpired();
    error QuestionIdCreatorMismatch();
    error UsdcTransferFailed();

    constructor() {
        _initializeOwner(tx.origin);
    }

    function initialize(address _usdc) external onlyOwner {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        usdc = IERC20(_usdc);
        outcomeTokenImplementation = address(new OutcomeToken());

        targetVig = DEFAULT_TARGET_VIG;
        emit TargetVigUpdated(0, targetVig);

        feePerOutcome = DEFAULT_FEE_PER_OUTCOME;
        emit FeePerOutcomeUpdated(0, feePerOutcome);

        initialSharesPerOutcome = DEFAULT_INITIAL_SHARES_PER_OUTCOME;
        emit InitialSharesPerOutcomeUpdated(0, initialSharesPerOutcome);

        emit AllowAnyMarketCreatorUpdated(allowAnyMarketCreator);

        maxOutcomes = 10;
        emit MaxOutcomesUpdated(0, maxOutcomes);

        emit AllowAnyMarketCreatorUpdated(false);

        emit LetCreatorsMigrateUpdated(false);

        emit MigrationContractSet(address(0));
    }

    // ========== MARKETS ==========

    /**
     * @notice Creates a new prediction market with specified outcomes
     * @dev Deploys outcome tokens for each outcome and sets up the market with initial liquidity
     * @param params Market creation parameters including oracle, outcomes, and initial trade
     * @return marketId The unique identifier for the created market
     */
    function createMarket(CreateMarketParams calldata params) external returns (bytes32) {
        if (params.questionId == bytes32(0)) revert EmptyQuestionId();
        if (questionIdToMarketId[params.questionId] != bytes32(0)) revert DuplicateQuestionId();
        if (!allowAnyMarketCreator) _checkRoles(MARKET_CREATOR_ROLE);
        if (params.outcomeNames.length < MIN_OUTCOMES || params.outcomeNames.length > maxOutcomes) {
            revert InvalidNumOutcomes();
        }
        if (params.outcomeNames.length != params.initialBuyShares.length) revert InvalidNumOutcomes();
        if (params.oracle == address(0)) revert InvalidOracle();
        if (address(uint160(bytes20(params.questionId))) != msg.sender) revert QuestionIdCreatorMismatch();
        if (params.surplusRecipient == address(0)) revert InvalidSurplusRecipient();

        uint256 n = params.outcomeNames.length;
        uint256 alpha = calculateAlpha(n, targetVig);

        uint256 totalFee = n * feePerOutcome;

        uint256[] memory outcomeQs = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            outcomeQs[i] = initialSharesPerOutcome;
        }

        validateInitialFundingInvariantForQs(outcomeQs, alpha, totalFee);

        if (!usdc.transferFrom(msg.sender, address(this), totalFee)) revert UsdcTransferFailed();

        bytes32 marketId = EfficientHashLib.hash(abi.encodePacked(msg.sender, params.oracle, params.questionId));

        address[] memory outcomeTokens = new address[](n);

        for (uint256 i = 0; i < n; i++) {
            if (bytes(params.outcomeNames[i]).length == 0) revert EmptyOutcomeName();

            OutcomeToken token = OutcomeToken(
                LibClone.cloneDeterministic(
                    outcomeTokenImplementation, EfficientHashLib.hash(abi.encodePacked(marketId, i))
                )
            );
            token.initialize(
                string.concat(params.outcomeNames[i], ": ", LibString.toHexString(uint256(params.questionId), 32)),
                params.outcomeNames[i],
                address(this)
            );

            outcomeTokens[i] = address(token);
            tokenToMarketId[address(token)] = marketId;
            tokenToOutcomeIndex[address(token)] = i;
        }

        markets[marketId] = MarketInfo({
            oracle: params.oracle,
            resolved: false,
            paused: false,
            alpha: alpha,
            totalUsdcIn: totalFee,
            creator: msg.sender,
            questionId: params.questionId,
            surplusRecipient: params.surplusRecipient,
            outcomeQs: outcomeQs,
            outcomeTokens: outcomeTokens,
            payoutPcts: new uint256[](n),
            initialSharesPerOutcome: initialSharesPerOutcome
        });
        questionIdToMarketId[params.questionId] = marketId;

        emit MarketCreated(
            marketId,
            params.oracle,
            params.questionId,
            params.surplusRecipient,
            msg.sender,
            params.metadata,
            alpha,
            totalFee,
            outcomeTokens,
            params.outcomeNames,
            outcomeQs
        );

        if (params.initialBuyMaxCost > 0) {
            for (uint256 i = 0; i < params.initialBuyShares.length; i++) {
                if (params.initialBuyShares[i] < 0) revert BuysOnly();
            }
            Trade memory initialTrade = Trade({
                marketId: marketId,
                deltaShares: params.initialBuyShares,
                maxCost: params.initialBuyMaxCost,
                minPayout: 0,
                deadline: block.timestamp
            });
            _trade(initialTrade, msg.sender);
        }
        return marketId;
    }

    /**
     * @notice Calculates the alpha parameter for market pricing based on outcomes and target vig
     * @param nOutcomes Number of outcomes in the market
     * @param _targetVig Target vig (see global targetVig) at the time of market creation
     * @return alpha
     */
    function calculateAlpha(uint256 nOutcomes, uint256 _targetVig) public pure returns (uint256) {
        uint256 lnN = uint256(FixedPointMathLib.lnWad(int256(nOutcomes * 1e18)));
        uint256 alpha = FixedPointMathLib.divWad(_targetVig, nOutcomes * lnN);
        return alpha;
    }

    function _calculateB(uint256 totalQ, uint256 alpha) internal pure returns (uint256) {
        return FixedPointMathLib.mulDiv(alpha, totalQ, ONE);
    }

    function _calculateB(uint256[] memory qs, uint256 alpha) internal pure returns (uint256) {
        return _calculateB(_totalQ(qs), alpha);
    }

    function _totalQ(uint256[] memory qs) internal pure returns (uint256 totalQ) {
        for (uint256 i = 0; i < qs.length; i++) {
            if (qs[i] == 0) revert InvalidMarketState();
            totalQ += qs[i];
        }
    }

    /**
     * @notice Calculates the cost function for a given market state
     * @dev Uses liquidity sensitive logarithmic scoring rule
     * @param qs Array of outcome quantities
     * @param alpha Market responsiveness parameter
     * @return c The total cost of the market state
     */
    function cost(uint256[] memory qs, uint256 alpha) public pure returns (uint256 c) {
        uint256 b = _calculateB(qs, alpha);

        uint256 bWad = b * 1e12;
        ExponentialTerms memory terms = computeExponentialTerms(qs, bWad);
        int256 lnSum = FixedPointMathLib.lnWad(int256(terms.sumExp));
        c = FixedPointMathLib.mulDiv(b, uint256(lnSum + terms.offset), FixedPointMathLib.WAD);
    }

    /**
     * @notice Calculates current prices for all outcomes in a market
     * @dev Prices are derived from the softmax distribution with entropy adjustment
     * @param qs Array of outcome quantities
     * @param alpha Market responsiveness parameter
     * @return prices Array of prices for each outcome (in 1e6 units, sum will be in range [1e6, 1e6 + targetVig])
     */
    function calcPrice(uint256[] memory qs, uint256 alpha) public pure returns (uint256[] memory prices) {
        uint256 n = qs.length;
        prices = new uint256[](n);

        // b(q) in 1e6; keep WAD (1e18) version for exp/ln math
        uint256 totalQ = _totalQ(qs);
        uint256 b = _calculateB(totalQ, alpha); // = alpha * totalQ, in 1e6
        if (b == 0) revert InvalidMarketState();
        uint256 bWad = b * 1e12; // 1e18

        // Exponentials of z_i = q_i / b, computed stably inside
        // terms.expTerms[i] ~ exp(z_i - offset)   (WAD)
        // terms.sumExp      ~ Σ exp(z_i - offset) (WAD)
        // terms.offset      ~ max(z_i)            (WAD)
        ExponentialTerms memory terms = computeExponentialTerms(qs, bWad);

        // Softmax s_i = exp(z_i)/Σexp(z)  (WAD)
        uint256[] memory sWad = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            sWad[i] = FixedPointMathLib.divWad(terms.expTerms[i], terms.sumExp);
        }

        // LSE(z) = ln(Σexp(z)) = ln(sumExp) + offset  (WAD)
        int256 logSumExpWadSigned = FixedPointMathLib.lnWad(int256(terms.sumExp)) + terms.offset;
        uint256 logSumExpWad = uint256(logSumExpWadSigned); // sumExp>0

        // s·z = (Σ q_i exp(z_i)) / (b Σ exp(z_i))  (WAD)
        uint256 numWad = 0; // accumulates q_i * exp(z_i) in WAD
        for (uint256 i = 0; i < n; i++) {
            uint256 qWad = qs[i] * 1e12; // 1e18
            numWad += FixedPointMathLib.mulWad(qWad, terms.expTerms[i]); // q_i * exp_i / 1e6
        }
        uint256 ratioWad = FixedPointMathLib.divWad(numWad, terms.sumExp); // q*s in WAD (1e18)
        uint256 sDotZWad = FixedPointMathLib.divWad(ratioWad, bWad); // divide by b

        // Entropy: H(s) = LSE(z) - s·z  (WAD)
        uint256 entropyWad = logSumExpWad - sDotZWad;

        // α·H(s) in 1e6 units
        uint256 alphaWad = alpha * 1e12; // 1e18
        uint256 alphaShiftOne = FixedPointMathLib.mulWad(alphaWad, entropyWad) / 1e12; // -> 1e6

        // Prices: p_i = s_i + α·H(s)
        for (uint256 i = 0; i < n; i++) {
            uint256 siOne = sWad[i] / 1e12; // WAD -> 1e6
            prices[i] = siOne + alphaShiftOne;
        }
    }

    /**
     * @notice Computes exponential terms for stable numerical calculation
     * @dev Uses offset exponentials to prevent overflow in exp calculations
     * @param qs Array of outcome quantities
     * @param bWad Scaled b parameter (alpha * totalQ) in WAD units
     * @return terms Struct containing exponential terms and offset
     */
    function computeExponentialTerms(uint256[] memory qs, uint256 bWad)
        public
        pure
        returns (ExponentialTerms memory terms)
    {
        uint256 n = qs.length;
        if (n < 2) revert InvalidNumOutcomes();

        uint256 maxQ;
        for (uint256 i = 0; i < n; i++) {
            if (qs[i] > maxQ) {
                maxQ = qs[i];
            }
        }

        terms.offset = int256(FixedPointMathLib.divWad(maxQ * 1e12, bWad));
        terms.expTerms = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            uint256 qWad = qs[i] * 1e12;
            int256 exponent = int256(FixedPointMathLib.divWad(qWad, bWad)) - terms.offset;
            uint256 expTerm = uint256(FixedPointMathLib.expWad(exponent));
            terms.expTerms[i] = expTerm;
            terms.sumExp += expTerm;
        }
    }

    /**
     * @notice Quotes the cost of a trade without executing it
     * @dev Positive cost means user pays, negative means user receives
     * @param qs Current outcome quantities
     * @param alpha Market responsiveness parameter
     * @param deltaShares Changes in shares for each outcome (positive=buy, negative=sell)
     * @return costDelta The net USDC cost of the trade
     */
    function quoteTrade(uint256[] memory qs, uint256 alpha, int256[] memory deltaShares)
        public
        pure
        returns (int256 costDelta)
    {
        if (qs.length != deltaShares.length) revert InvalidNumOutcomes();

        uint256[] memory newQs = new uint256[](qs.length);
        for (uint256 i = 0; i < qs.length; i++) {
            if (deltaShares[i] < 0 && uint256(-deltaShares[i]) > qs[i]) {
                revert InvalidMarketState();
            }
            newQs[i] = deltaShares[i] >= 0 ? qs[i] + uint256(deltaShares[i]) : qs[i] - uint256(-deltaShares[i]);
        }

        uint256 costBefore = cost(qs, alpha);
        uint256 costAfter = cost(newQs, alpha);
        costDelta = int256(costAfter) - int256(costBefore);
        if (costDelta > 0) costDelta += QUOTE_TRADE_ROUNDING_BUFFER;
    }

    function _trade(Trade memory tradeData, address trader) internal returns (int256 costDelta) {
        if (!marketExists(tradeData.marketId)) revert MarketDoesNotExist();
        _checkNotMigrated(tradeData.marketId);
        MarketInfo storage m = markets[tradeData.marketId];
        if (m.resolved || m.paused) revert InvalidMarketState();
        if (block.timestamp > tradeData.deadline) revert TradeExpired();

        costDelta = quoteTrade(m.outcomeQs, m.alpha, tradeData.deltaShares);

        if (costDelta > 0) {
            uint256 userPays = uint256(costDelta);
            if (userPays > tradeData.maxCost) revert InsufficientInputAmount();
            m.totalUsdcIn += userPays;
            if (!usdc.transferFrom(trader, address(this), userPays)) revert UsdcTransferFailed();
        } else {
            uint256 payout = uint256(-costDelta);
            if (payout < tradeData.minPayout) revert InsufficientOutputAmount();
            if (payout > 0) {
                m.totalUsdcIn -= payout;
                if (!usdc.transfer(trader, payout)) revert UsdcTransferFailed();
            }
        }

        for (uint256 i = 0; i < tradeData.deltaShares.length; i++) {
            if (tradeData.deltaShares[i] > 0) {
                uint256 buyAmount = uint256(tradeData.deltaShares[i]);
                m.outcomeQs[i] += buyAmount;
                OutcomeToken(m.outcomeTokens[i]).mint(trader, buyAmount);
            } else if (tradeData.deltaShares[i] < 0) {
                uint256 sellAmount = uint256(-tradeData.deltaShares[i]);
                m.outcomeQs[i] -= sellAmount;
                OutcomeToken(m.outcomeTokens[i]).burn(trader, sellAmount);
            }
        }

        emit MarketTraded(tradeData.marketId, msg.sender, m.alpha, costDelta, tradeData.deltaShares, m.outcomeQs);
    }

    /**
     * @notice Executes a trade in a prediction market
     * @dev Mints/burns outcome tokens and transfers USDC based on trade direction
     * @param tradeData Trade parameters including market, shares, and slippage limits
     * @return costDelta the actual USDC cost of the trade (positive=paid, negative=received)
     */
    function trade(Trade memory tradeData) external returns (int256) {
        return _trade(tradeData, msg.sender);
    }

    /**
     * @notice Redeems outcome tokens for USDC after market resolution
     * @dev Burns tokens and pays out based on the resolved payout percentages
     * @param token The outcome token address to redeem
     * @param amount The amount of tokens to redeem
     */
    function redeem(address token, uint256 amount) external {
        bytes32 marketId = tokenToMarketId[token];
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        _checkNotMigrated(marketId);
        MarketInfo storage m = markets[marketId];
        if (!m.resolved) revert InvalidMarketState();
        uint256 outcomeIndex = tokenToOutcomeIndex[token];
        if (outcomeIndex >= m.payoutPcts.length) revert InvalidNumOutcomes();
        uint256 payoutPct = m.payoutPcts[outcomeIndex];
        uint256 payout = FixedPointMathLib.mulDiv(amount, payoutPct, ONE);
        OutcomeToken(token).burn(msg.sender, amount);
        if (!usdc.transfer(msg.sender, payout)) revert UsdcTransferFailed();
        emit TokensRedeemed(marketId, msg.sender, token, amount, payout);
    }

    // ========== ORACLE ==========

    /**
     * @notice Resolves a market with specified payout percentages for each outcome
     * @dev Only callable by the market's oracle. Payouts must sum to 1e6
     * @param marketId The market to resolve
     * @param payoutPcts Payout percentages for each outcome
     */
    function resolveMarketWithPayoutSplit(bytes32 marketId, uint256[] calldata payoutPcts) external {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        _checkNotMigrated(marketId);
        MarketInfo storage m = markets[marketId];
        if (m.resolved) revert InvalidMarketState();
        if (msg.sender != m.oracle) revert CallerNotOracle();
        if (payoutPcts.length != m.outcomeQs.length) revert InvalidPayout();

        uint256 sumPayout = 0;
        for (uint256 i = 0; i < payoutPcts.length; i++) {
            sumPayout += payoutPcts[i];
        }
        if (sumPayout != ONE) revert InvalidPayout();

        m.resolved = true;
        m.payoutPcts = payoutPcts;

        uint256 totalPayout = 0;
        uint256 initialSharesPerOutcomeLocal = m.initialSharesPerOutcome;
        for (uint256 i = 0; i < m.outcomeQs.length; i++) {
            uint256 outstandingShares = m.outcomeQs[i] - initialSharesPerOutcomeLocal;
            totalPayout += FixedPointMathLib.mulDiv(outstandingShares, payoutPcts[i], ONE);
        }

        uint256 totalUsdcIn = m.totalUsdcIn;

        if (totalUsdcIn < totalPayout) revert MarketInsolvent();

        uint256 surplusAmount = totalUsdcIn - totalPayout;

        if (surplusAmount > 0) surplus[m.surplusRecipient] += surplusAmount;

        emit MarketResolved(marketId, payoutPcts, surplusAmount);
    }

    /**
     * @notice Pauses trading in a market
     * @dev Only callable by the market's oracle
     * @param marketId The market to pause
     */
    function pauseMarket(bytes32 marketId) external {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        _checkNotMigrated(marketId);
        MarketInfo storage m = markets[marketId];
        if (msg.sender != m.oracle) revert CallerNotOracle();
        if (m.resolved) revert InvalidMarketState();
        if (m.paused) revert InvalidMarketState();
        m.paused = true;
        emit MarketPausedUpdated(marketId, true);
    }

    /**
     * @notice Resumes trading in a paused market
     * @dev Only callable by the market's oracle
     * @param marketId The market to unpause
     */
    function unpauseMarket(bytes32 marketId) external {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        _checkNotMigrated(marketId);
        MarketInfo storage m = markets[marketId];
        if (msg.sender != m.oracle) revert CallerNotOracle();
        if (m.resolved) revert InvalidMarketState();
        if (!m.paused) revert InvalidMarketState();
        m.paused = false;
        emit MarketPausedUpdated(marketId, false);
    }

    // ========== ADMIN ==========

    function validateInitialFundingInvariantForQs(uint256[] memory qs, uint256 alpha, uint256 totalFee) public pure {
        if (qs.length < MIN_OUTCOMES) revert InvalidNumOutcomes();

        uint256 initialCost = cost(qs, alpha);
        if (totalFee < initialCost + COST_ROUNDING_BUFFER) revert InitialFundingInvariantViolation();
    }

    function validateInitialFundingInvariantForNOutcomes(
        uint256 _targetVig,
        uint256 _initialSharesPerOutcome,
        uint256 _feePerOutcome,
        uint256 nOutcomes
    ) public pure {
        uint256[] memory qs = new uint256[](nOutcomes);
        for (uint256 i = 0; i < nOutcomes; i++) {
            qs[i] = _initialSharesPerOutcome;
        }
        uint256 alpha = calculateAlpha(nOutcomes, _targetVig);
        validateInitialFundingInvariantForQs(qs, alpha, _feePerOutcome * nOutcomes);
    }

    function setInitialSharesAndFeePerOutcome(uint256 newInitialSharesPerOutcome, uint256 _feePerOutcome)
        external
        onlyRoles(PROTOCOL_MANAGER_ROLE)
    {
        if (newInitialSharesPerOutcome == 0) revert InvalidInitialShares();
        if (_feePerOutcome == 0) revert InvalidFee();

        validateInitialFundingInvariantForNOutcomes(targetVig, newInitialSharesPerOutcome, _feePerOutcome, MIN_OUTCOMES);

        uint256 oldShares = initialSharesPerOutcome;
        uint256 oldFee = feePerOutcome;

        initialSharesPerOutcome = newInitialSharesPerOutcome;
        feePerOutcome = _feePerOutcome;

        emit InitialSharesPerOutcomeUpdated(oldShares, newInitialSharesPerOutcome);
        emit FeePerOutcomeUpdated(oldFee, _feePerOutcome);
    }

    function setTargetVig(uint256 newTargetVig) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (newTargetVig == 0) revert InvalidTargetVig();
        validateInitialFundingInvariantForNOutcomes(newTargetVig, initialSharesPerOutcome, feePerOutcome, MIN_OUTCOMES);
        uint256 oldTargetVig = targetVig;
        targetVig = newTargetVig;
        emit TargetVigUpdated(oldTargetVig, newTargetVig);
    }

    function setInitialSharesAndFeePerOutcomeAndTargetVig(
        uint256 newInitialSharesPerOutcome,
        uint256 newFeePerOutcome,
        uint256 newTargetVig
    ) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (newInitialSharesPerOutcome == 0) revert InvalidInitialShares();
        if (newFeePerOutcome == 0) revert InvalidFee();
        if (newTargetVig == 0) revert InvalidTargetVig();

        validateInitialFundingInvariantForNOutcomes(
            newTargetVig, newInitialSharesPerOutcome, newFeePerOutcome, MIN_OUTCOMES
        );

        uint256 oldShares = initialSharesPerOutcome;
        uint256 oldFee = feePerOutcome;
        uint256 oldTargetVig = targetVig;

        initialSharesPerOutcome = newInitialSharesPerOutcome;
        feePerOutcome = newFeePerOutcome;
        targetVig = newTargetVig;

        emit InitialSharesPerOutcomeUpdated(oldShares, newInitialSharesPerOutcome);
        emit FeePerOutcomeUpdated(oldFee, newFeePerOutcome);
        emit TargetVigUpdated(oldTargetVig, newTargetVig);
    }

    function withdrawSurplus() external {
        uint256 amount = surplus[msg.sender];
        if (amount == 0) revert ZeroSurplus();
        surplus[msg.sender] = 0;
        if (!usdc.transfer(msg.sender, amount)) revert UsdcTransferFailed();
        emit SurplusWithdrawn(msg.sender, amount);
    }

    function setAllowAnyMarketCreator(bool allow) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (allow == allowAnyMarketCreator) return;
        allowAnyMarketCreator = allow;
        emit AllowAnyMarketCreatorUpdated(allow);
    }

    function grantMarketCreatorRole(address account) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        _grantRoles(account, MARKET_CREATOR_ROLE);
    }

    function revokeMarketCreatorRole(address account) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        _removeRoles(account, MARKET_CREATOR_ROLE);
    }

    function setMaxOutcomes(uint256 newMaxOutcomes) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (newMaxOutcomes < MIN_OUTCOMES) revert InvalidMaxOutcomes();
        uint256 oldMaxOutcomes = maxOutcomes;
        maxOutcomes = newMaxOutcomes;
        emit MaxOutcomesUpdated(oldMaxOutcomes, newMaxOutcomes);
    }

    function bailoutMarket(bytes32 marketId, uint256 bailoutAmount) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        _checkNotMigrated(marketId);
        MarketInfo storage m = markets[marketId];
        m.totalUsdcIn += bailoutAmount;
        if (!usdc.transferFrom(msg.sender, address(this), bailoutAmount)) revert UsdcTransferFailed();
    }

    function setMigrationContract(address newMigrationContract) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (newMigrationContract == address(0)) revert InvalidMigrationContract();
        migrationContract = newMigrationContract;
        emit MigrationContractSet(newMigrationContract);
    }

    function updateLetCreatorsMigrate(bool allow) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (allow == letCreatorsMigrate) return;
        letCreatorsMigrate = allow;
        emit LetCreatorsMigrateUpdated(allow);
    }

    function initiateMarketMigration(bytes32 marketId) external {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = markets[marketId];
        _checkNotMigrated(marketId);
        if (!letCreatorsMigrate || msg.sender != m.creator) {
            _checkRoles(PROTOCOL_MANAGER_ROLE);
        }
        if (m.resolved || m.paused) revert InvalidMarketState();
        if (migrationContract == address(0)) revert InvalidMigrationState();

        marketMigrationState[marketId] = MigrationState.Initiated;
        emit MarketMigrationInitiated(marketId);

        m.paused = true;
        emit MarketPausedUpdated(marketId, true);

        for (uint256 i = 0; i < m.outcomeTokens.length; i++) {
            OutcomeToken(m.outcomeTokens[i]).setPendingPredictionMarket(migrationContract);
        }
    }

    function finalizeMarketMigration(bytes32 marketId) external {
        MarketInfo storage m = markets[marketId];
        if (m.resolved) revert InvalidMarketState();
        if (marketMigrationState[marketId] != MigrationState.Initiated) revert InvalidMigrationState();
        if (msg.sender != migrationContract) revert CallerNotMigrationContract();

        for (uint256 i = 0; i < m.outcomeTokens.length; i++) {
            if (OutcomeToken(m.outcomeTokens[i]).predictionMarket() != migrationContract) {
                revert InvalidMigrationState();
            }
        }

        uint256 amount = markets[marketId].totalUsdcIn;
        marketMigrationState[marketId] = MigrationState.Finalized;

        if (!usdc.transfer(migrationContract, amount)) revert UsdcTransferFailed();
        emit MarketMigrationFinalized(marketId, amount);
    }

    function abortMigration(bytes32 marketId) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        MarketInfo storage m = markets[marketId];
        if (marketMigrationState[marketId] != MigrationState.Initiated) revert InvalidMigrationState();

        for (uint256 i = 0; i < m.outcomeTokens.length; i++) {
            if (OutcomeToken(m.outcomeTokens[i]).predictionMarket() != address(this)) revert InvalidMigrationState();
        }

        marketMigrationState[marketId] = MigrationState.Aborted;
        emit MarketMigrationAborted(marketId);

        m.paused = false;
        emit MarketPausedUpdated(marketId, false);

        for (uint256 i = 0; i < m.outcomeTokens.length; i++) {
            OutcomeToken(m.outcomeTokens[i]).setPendingPredictionMarket(address(0));
        }
    }

    function _checkNotMigrated(bytes32 marketId) internal view {
        if (
            marketMigrationState[marketId] == MigrationState.Initiated
                || marketMigrationState[marketId] == MigrationState.Finalized
        ) revert InvalidMigrationState();
    }

    // ========== INFO ==========

    /**
     * @notice Returns current prices for all outcomes in a market
     * @param marketId The market to get prices for
     * @return prices Array of current prices for each outcome
     */
    function getPrices(bytes32 marketId) external view returns (uint256[] memory) {
        MarketInfo storage m = markets[marketId];
        return calcPrice(m.outcomeQs, m.alpha);
    }

    /**
     * @notice Returns complete information about a market
     * @param marketId The market to get info for
     * @return MarketInfo struct
     */
    function getMarketInfo(bytes32 marketId) external view returns (MarketInfo memory) {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        return markets[marketId];
    }

    /**
     * @notice Checks if a market exists
     * @param marketId The market ID to check
     * @return exists boolean
     */
    function marketExists(bytes32 marketId) public view returns (bool) {
        return markets[marketId].outcomeTokens.length > 0;
    }
}

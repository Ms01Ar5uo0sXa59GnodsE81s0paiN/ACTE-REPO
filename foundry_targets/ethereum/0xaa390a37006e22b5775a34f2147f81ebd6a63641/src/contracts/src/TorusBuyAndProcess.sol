// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/* === UNIV3 === */
import {TransferHelper} from "../lib/v3-periphery/contracts/libraries/TransferHelper.sol";
import {INonfungiblePositionManager} from "../lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {TickMath} from "../lib/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "./library/OracleLibrary.sol";
import {ISwapRouter} from "../lib/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/* === OZ === */
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/* === CONST === */
import "./const/BuyAndProcessConst.sol";

/* === SYSTEM === */
import {Torus} from "./Torus.sol";
import {TorusCreateAndStake} from "./TorusCreateAndStake.sol";

/**
 * @title TorusBuyAndProcess
 * @dev This contract handles two separate flows:
 *       - The “burn” flow: users can swap TitanX/ETH for Torus and burn the Torus tokens.
 *       - The “build” flow: users can swap funds for TitanX, swap half for Torus and then add liquidity.
 *
 * Both flows use separate interval‐mechanisms, daily allocations, and slippage settings.
 */
contract TorusBuyAndProcess is ReentrancyGuard, Ownable2Step, IERC721Receiver {
    using TransferHelper for IERC20;

    /* ================================================================
                           COMMON CONSTANTS / IMMUTABLE
       ================================================================ */
    INonfungiblePositionManager public constant POSITION_MANAGER =
        INonfungiblePositionManager(UNISWAP_V3_POSITION_MANAGER);

    ERC20Burnable private immutable titanX;
    Torus public immutable torusToken;
    TorusCreateAndStake public torusCreateAndStake;
    uint32 public immutable startTimeStamp;

    /* ================================================================
                           BURN (BuyAndBurn) VARIABLES
       ================================================================ */

    struct IntervalBurn {
        uint128 amountAllocated;
        uint128 amountBurned;
    }

    struct IntervalBuild {
        uint128 amountAllocated;
        uint128 amountBurned;
    }

    struct LP {
        uint248 tokenId;
        bool isTitanXToken0;
    }

    LP public lpToken;

    bool public liquidityAdded;

    uint256 public totalTorusBurnt;
    uint256 public totalTitanXBurnt;
    uint256 public titanXUsedForBurns;
    uint256 public ethUsedForBurns;
    uint256 public titanXUsedForBuilds;
    uint256 public ethUsedForBuilds;

    uint256 public DAILY_ALLOCATION_TITAN_X_BURNING = 100; // in basis points (e.g. 100 = 1%)
    uint256 public DAILY_ALLOCATION_ETH_BURNING = 100;
    uint256 public DAILY_ALLOCATION_TITAN_X_BUILDING = 100; // in basis points (e.g. 100 = 1%)
    uint256 public DAILY_ALLOCATION_ETH_BUILDING = 100;

    uint256 public totalTitanXBurn;
    uint256 public totalETHBurn;
    uint256 public fractalTitanX;
    uint256 public fractalETH;
    uint256 public lastFractalRelease; // timestamp of last fractal funds release

    mapping(uint32 => IntervalBurn) public titanXIntervalsBurn;
    uint32 public lastTitanXBurnIntervalNumber;
    uint32 public lastBurnedTitanXIntervalStartTimestamp;

    mapping(uint32 => IntervalBurn) public ethIntervalsBurn;
    uint32 public lastETHBurnIntervalNumber;
    uint32 public lastBurnedETHIntervalStartTimestamp;


    /* ================================================================
                           BUILD (BuyAndBuild) VARIABLES
       ================================================================ */

    uint8 public titanXToTorusSlippage = 10;
    uint8 public ethToTitanXSlippage = 10;
    uint8 public liquiditySlippage = 10;

    mapping(uint32 => IntervalBuild) public titanXIntervalsBuild; // using same struct shape as burn but renamed for build
    uint32 public lastTitanXBuildIntervalNumber;
    uint32 public lastTitanXBuildIntervalStartTimestamp;

    mapping(uint32 => IntervalBuild) public ethIntervalsBuild;
    uint32 public lastETHBuildIntervalNumber;
    uint32 public lastETHBuildIntervalStartTimestamp;


    bool public liquidityAddedBuild; // for build flow

    uint256 public totalTitanXBuilt; // total TitanX used in build
    uint256 public totalETHBuilt; // total ETH used in build
    uint256 public totalTitanXForBuild; // balance of TitanX for build
    uint256 public totalETHForBuild; // balance of ETH for build

    /* ================================================================
                                Modifiers
       ================================================================ */
    
    modifier burnTitanXIntervalUpdate() {
        _intervalUpdateTitanXForBurning();
        _;
    }

    modifier burnETHIntervalUpdate() {
        _intervalUpdateETHForBurning();
        _;
    }

    modifier buildTitanXIntervalUpdate() {
        _intervalUpdateTitanXForBuilding();
        _;
    }

    modifier buildETHIntervalUpdate() {
        _intervalUpdateETHForBuilding();
        _;
    }

    /* ================================================================
                                  EVENTS
       ================================================================ */
    event BuyAndBurn(
        uint256 indexed titanXAmount,
        uint256 indexed torusBurnt,
        address indexed caller
    );
    event FractalFundsReleased(uint256 releasedTitanX, uint256 releasedETH);
    event BuyAndBuild(
        uint256 indexed tokenAllocated,
        uint256 indexed torusPurchased,
        address indexed caller
    );
    event CreateAndStakeContractUpdated(
        address indexed oldCreateAndStake,
        address indexed newCreateAndStake
    );
    event LiquiditySlippageUpdated(uint8 newSlippage);
    event DailyAllocationTitanXBurningUpdated(uint256 newDailyAllocation);
    event DailyAllocationETHBurningUpdated(uint256 newDailyAllocation);
    event DailyAllocationTitanXBuildingUpdated(uint256 newDailyAllocation);
    event DailyAllocationETHBuildingUpdated(uint256 newDailyAllocation);
    event TitanXToTorusSlippageUpdated(uint8 newSlippage);
    event ETHToTitanXSlippageUpdated(uint8 newSlippage);
    event TorusBurned(uint256 indexed torusBurnt);

    /* ================================================================
                                  ERRORS
       ================================================================ */
    error NotStartedYet();
    error InvalidInput();
    error NotEnoughTitanXForLiquidity();
    error LiquidityAlreadyAdded();
    error IntervalAlreadyBurned();
    error IntervalAlreadyUsed();
    error FractalReleaseNotReady();

    /* ================================================================
                                  CONSTRUCTOR
       ================================================================ */
    constructor(uint32 startTimestamp, address _owner) payable Ownable(_owner) {
        startTimeStamp = startTimestamp;
        torusToken = Torus(msg.sender);
        titanX = ERC20Burnable(TITAN_X_ADDRESS);
        lastFractalRelease = startTimestamp;
        lastBurnedETHIntervalStartTimestamp = startTimestamp;
        lastBurnedTitanXIntervalStartTimestamp = startTimestamp;
        lastETHBuildIntervalStartTimestamp = startTimestamp;
        lastTitanXBuildIntervalStartTimestamp = startTimestamp;
        titanX.approve(address(this), type(uint256).max);
    }

    function setCreateAndStakeContract(
        address _torusCreateAndStake
    ) external {
        require(address(torusCreateAndStake) == address(0), "Already set");
        address oldCreateAndStake = address(torusCreateAndStake);
        torusCreateAndStake = TorusCreateAndStake(_torusCreateAndStake);

        emit CreateAndStakeContractUpdated(
            oldCreateAndStake,
            address(torusCreateAndStake)
        );
    }

    function setLiquiditySlippage(uint8 _newSlippage) external onlyOwner {
        if (_newSlippage > 100 || _newSlippage < 2) revert InvalidInput();
        liquiditySlippage = _newSlippage;

        emit LiquiditySlippageUpdated(_newSlippage);
    }

    /* ================================================================
                           BURN (BuyAndBurn) FUNCTIONS
       ================================================================ */

    /**
     * @notice Swaps TitanX for Torus and burns the Torus tokens (burn flow).
     * @param _deadline The deadline for the swap.
     */
    function swapTitanXForTorusAndBurn(uint32 _deadline) external nonReentrant burnTitanXIntervalUpdate {
        if (!liquidityAdded) revert NotStartedYet();
        IntervalBurn storage currInterval = titanXIntervalsBurn[
            lastTitanXBurnIntervalNumber
        ];
        if (currInterval.amountBurned != 0) revert IntervalAlreadyBurned();

        uint256 amountAllocated = currInterval.amountAllocated;

        currInterval.amountBurned = currInterval.amountAllocated;
        uint256 incentive = (currInterval.amountAllocated * INCENTIVE_FEE) /
            BPS_DENOM;
        uint256 titanXToSwapAndBurn = amountAllocated - incentive;

        uint256 torusAmount = _swapTitanXForTorus(
            titanXToSwapAndBurn,
            _deadline
        );

        titanXUsedForBurns += titanXToSwapAndBurn;
        totalTorusBurnt += torusAmount;
        totalTitanXBurn -= currInterval.amountAllocated;

        if (block.timestamp >= lastFractalRelease + FRACTAL_RELEASE_INTERVAL) {
            releaseFractalFunds();
        }
        
        burnTorus();
        TransferHelper.safeTransfer(TITAN_X_ADDRESS, msg.sender, incentive);

        emit BuyAndBurn(titanXToSwapAndBurn, torusAmount, msg.sender);
    }

    /**
     * @notice Swaps ETH for Torus and burns the Torus tokens (burn flow).
     * @param _deadline The deadline for the swap.
     */
    function swapETHForTorusAndBurn(uint32 _deadline) external nonReentrant burnETHIntervalUpdate {
        if (!liquidityAdded) revert NotStartedYet();
        IntervalBurn storage currInterval = ethIntervalsBurn[
            lastETHBurnIntervalNumber
        ];
        if (currInterval.amountBurned != 0) revert IntervalAlreadyBurned();

        currInterval.amountBurned = currInterval.amountAllocated;

        uint256 amountAllocated = currInterval.amountAllocated;
        uint256 incentive = (amountAllocated * INCENTIVE_FEE) / BPS_DENOM;

        currInterval.amountBurned = currInterval.amountAllocated;

        uint256 ethToSwapAndBurn = currInterval.amountAllocated - incentive;
        uint256 titanXAmount = _swapETHForTitanX(
            ethToSwapAndBurn,
            _deadline
        );

        uint256 torusAmount = _swapTitanXForTorus(titanXAmount, _deadline);

        ethUsedForBurns += ethToSwapAndBurn;
        totalTorusBurnt += torusAmount;
        totalETHBurn -= currInterval.amountAllocated;

        if (block.timestamp >= lastFractalRelease + FRACTAL_RELEASE_INTERVAL) {
            releaseFractalFunds();
        }

        burnTorus();
        (bool success, ) = payable(msg.sender).call{
            value: incentive,
            gas: 30000
        }("");
        require(success, "Transfer failed");

        emit BuyAndBurn(ethToSwapAndBurn, torusAmount, msg.sender);
    }

    /**
     * @notice Creates a Uniswap V3 pool and adds liquidity for the burn process.
     * @param _deadline The deadline for liquidity addition.
     */
    /// @notice Creates the TitanX/TORUS pool and seeds initial liquidity
    function addLiquidityToTorusTitanXPool(uint32 _deadline) external {
        if (liquidityAdded) revert LiquidityAlreadyAdded();
        if (totalTitanXBurn < INITIAL_TITAN_X_FOR_LIQ)
            revert NotEnoughTitanXForLiquidity();

        liquidityAdded = true;
        liquidityAddedBuild = true;
        torusToken.mintTokensForLP();

        (
        uint256 amount0,
        uint256 amount1,
        address token0,
        address token1
        ) = _sortAmounts(INITIAL_TITAN_X_FOR_LIQ, INITIAL_LP_MINT);

        TransferHelper.safeApprove(token0, address(POSITION_MANAGER), amount0);
        TransferHelper.safeApprove(token1, address(POSITION_MANAGER), amount1);

        uint256 amount0Min = (amount0 * (100 - liquiditySlippage)) / 100;
        uint256 amount1Min = (amount1 * (100 - liquiditySlippage)) / 100;

        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0:         token0,
                token1:         token1,
                fee:            POOL_FEE,
                tickLower:      (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING,
                tickUpper:      (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min:     amount0Min,
                amount1Min:     amount1Min,
                recipient:      address(this),
                deadline:       _deadline
            });

        (uint256 tokenId, , uint256 used0, uint256 used1) =
            POSITION_MANAGER.mint(params);

        if (amount0 > used0) {
            TransferHelper.safeTransfer(token0, torusToken.genesisWallet(), amount0 - used0);
        }
        if (amount1 > used1) {
            TransferHelper.safeTransfer(token1, torusToken.genesisWallet(), amount1 - used1);
        }

        TransferHelper.safeApprove(token0, address(POSITION_MANAGER), 0);
        TransferHelper.safeApprove(token1, address(POSITION_MANAGER), 0);

        lpToken = LP({
            tokenId:        uint248(tokenId),
            isTitanXToken0: token0 == TITAN_X_ADDRESS
        });

        totalTitanXBurn -= INITIAL_TITAN_X_FOR_LIQ;
    }

    /**
     * @notice Sets daily allocation for TitanX (burn flow).
     */
    function setDailyAllocationTitanXBurning(
        uint256 _newDailyAllocation
    ) external onlyOwner {
        DAILY_ALLOCATION_TITAN_X_BURNING = _newDailyAllocation;
        require(
            DAILY_ALLOCATION_TITAN_X_BURNING >= 100 &&
                DAILY_ALLOCATION_TITAN_X_BURNING <= 1000,
            "Min 1%, max 10%"
        );
        _intervalUpdateTitanXForBurning();

        emit DailyAllocationTitanXBurningUpdated(
            _newDailyAllocation
        );
    }

    /**
     * @notice Sets daily allocation for ETH (burn flow).
     */
    function setDailyAllocationETHBurning(
        uint256 _newDailyAllocation
    ) external onlyOwner {
        DAILY_ALLOCATION_ETH_BURNING = _newDailyAllocation;
        require(
            DAILY_ALLOCATION_ETH_BURNING >= 100 &&
                DAILY_ALLOCATION_ETH_BURNING <= 1000,
            "Min 1%, max 10%"
        );
        _intervalUpdateETHForBurning();

        emit DailyAllocationETHBurningUpdated(
            _newDailyAllocation
        );
    }

    /**
     * @notice Sets daily allocation for TitanX (build flow).
     */
    function setDailyAllocationTitanXBuilding(
        uint256 _newDailyAllocation
    ) external onlyOwner {
        DAILY_ALLOCATION_TITAN_X_BUILDING = _newDailyAllocation;
        require(
            DAILY_ALLOCATION_TITAN_X_BUILDING >= 100 &&
                DAILY_ALLOCATION_TITAN_X_BUILDING <= 1000,
            "Min 1%, max 10%"
        );
        _intervalUpdateTitanXForBuilding();

        emit DailyAllocationTitanXBuildingUpdated(
            _newDailyAllocation
        );
    }

    /**
     * @notice Sets daily allocation for ETH (build flow).
     */
    function setDailyAllocationETHBuilding(
        uint256 _newDailyAllocation
    ) external onlyOwner {
        DAILY_ALLOCATION_ETH_BUILDING = _newDailyAllocation;
        require(
            DAILY_ALLOCATION_ETH_BUILDING >= 100 &&
                DAILY_ALLOCATION_ETH_BUILDING <= 1000,
            "Min 1%, max 10%"
        );
        _intervalUpdateETHForBuilding();

        emit DailyAllocationETHBuildingUpdated(
            _newDailyAllocation
        );
    }

    /**
     * @notice Burns all Torus tokens held by the contract.
     */
    function burnTorus() public {
        uint256 torusToBurn = torusToken.balanceOf(address(this));
        totalTorusBurnt += torusToBurn;
        torusToken.burn(torusToBurn);

        emit TorusBurned(
            torusToBurn
        );
    }

    function setSlippageForTitanXToTorus(
        uint8 _newSlippage
    ) external onlyOwner {
        if (_newSlippage > 100 || _newSlippage < 2) revert InvalidInput();
        titanXToTorusSlippage = _newSlippage;

        emit TitanXToTorusSlippageUpdated(_newSlippage);
    }

    function setSlippageForETHToTitanX(uint8 _newSlippage) external onlyOwner {
        if (_newSlippage > 100 || _newSlippage < 2) revert InvalidInput();
        ethToTitanXSlippage = _newSlippage;

        emit ETHToTitanXSlippageUpdated(_newSlippage);
    }

    function burnFees() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        LP memory _lp = lpToken;
        INonfungiblePositionManager.CollectParams
            memory params = INonfungiblePositionManager.CollectParams({
                tokenId: _lp.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        (amount0, amount1) = POSITION_MANAGER.collect(params);
        (uint256 titanXAmount, ) = _lp.isTitanXToken0
            ? (amount0, amount1)
            : (amount1, amount0);
        
        if (titanXAmount > 0) {
            TransferHelper.safeTransfer(TITAN_X_ADDRESS, torusToken.genesisWallet(), titanXAmount);
        }

        if (torusToken.balanceOf(address(this)) > 0) {
            burnTorus();
        }
    }

    /**
     * @notice Distributes TitanX for burning (burn flow).
     */
    function distributeTitanXForBurning(uint256 _amount) external {
        if (_amount == 0) revert InvalidInput();

        if (
            block.timestamp > startTimeStamp &&
            block.timestamp - lastBurnedTitanXIntervalStartTimestamp >
            INTERVAL_TIME
        ) {
            _intervalUpdateTitanXForBurning();
        }

        TransferHelper.safeTransferFrom(
            TITAN_X_ADDRESS,
            msg.sender,
            address(this),
            _amount
        );

        uint256 fractalPortion    = (_amount * FRACTAL_SPLIT) / 100;
        uint256 titanXBurnPortion = _amount - fractalPortion;
        
        totalTitanXBurn += titanXBurnPortion;
        fractalTitanX += fractalPortion;

        if (block.timestamp >= lastFractalRelease + FRACTAL_RELEASE_INTERVAL) {
            releaseFractalFunds();
        }
    }

    /**
     * @notice Distributes ETH for burning (burn flow).
     */
    function distributeETHForBurning() external payable {
        if (msg.value == 0) revert InvalidInput();

        if (
            block.timestamp > startTimeStamp &&
            block.timestamp - lastBurnedETHIntervalStartTimestamp >
            INTERVAL_TIME
        ) {
            _intervalUpdateETHForBurning();
        }

        uint256 fractalPortion  = (msg.value * FRACTAL_SPLIT) / 100;
        uint256 immediatePortion = msg.value - fractalPortion;

        totalETHBurn += immediatePortion;
        fractalETH   += fractalPortion;

        if (block.timestamp >= lastFractalRelease + FRACTAL_RELEASE_INTERVAL) {
            releaseFractalFunds();
        }
    }

    /**
     * @notice Releases fractal funds (burn flow).
     */
    function releaseFractalFunds() public {
        if (block.timestamp < lastFractalRelease + FRACTAL_RELEASE_INTERVAL)
            revert FractalReleaseNotReady();
        totalTitanXBurn += fractalTitanX;
        totalETHBurn += fractalETH;
        emit FractalFundsReleased(fractalTitanX, fractalETH);
        fractalTitanX = 0;
        fractalETH = 0;
        lastFractalRelease = block.timestamp;
    }

    function _calculateIntervalsTitanXBurn(
        uint256 timeElapsed
    )
        internal
        view
        returns (
            uint32 _lastIntervalNumber,
            uint128 _totalAmountForInterval,
            uint32 missedIntervals
        )
    {
        missedIntervals = lastBurnedTitanXIntervalStartTimestamp == 0
            ? (
                timeElapsed <= INTERVAL_TIME
                    ? 0
                    : uint32(timeElapsed / INTERVAL_TIME)
            )
            : (
                timeElapsed <= INTERVAL_TIME
                    ? 0
                    : uint32(timeElapsed / INTERVAL_TIME) - 1
            );
        _lastIntervalNumber =
            lastTitanXBurnIntervalNumber +
            missedIntervals +
            1;
        uint256 dailyAllocation = (totalTitanXBurn *
            DAILY_ALLOCATION_TITAN_X_BURNING) / BPS_DENOM;
        uint128 amountPerInterval = uint128(
            dailyAllocation / INTERVALS_PER_DAY
        );
        uint128 additionalAmount = amountPerInterval * missedIntervals;
        _totalAmountForInterval = amountPerInterval + additionalAmount;
        if (_totalAmountForInterval > totalTitanXBurn) {
            _totalAmountForInterval = uint128(totalTitanXBurn);
        }
    }

    function _calculateIntervalsETHBurn(
        uint256 timeElapsed
    )
        internal
        view
        returns (
            uint32 _lastIntervalNumber,
            uint128 _totalAmountForInterval,
            uint32 missedIntervals
        )
    {
        missedIntervals = lastBurnedETHIntervalStartTimestamp == 0
            ? (
                timeElapsed <= INTERVAL_TIME
                    ? 0
                    : uint32(timeElapsed / INTERVAL_TIME)
            )
            : (
                timeElapsed <= INTERVAL_TIME
                    ? 0
                    : uint32(timeElapsed / INTERVAL_TIME) - 1
            );
        _lastIntervalNumber = lastETHBurnIntervalNumber + missedIntervals + 1;
        uint256 dailyAllocation = (totalETHBurn *
            DAILY_ALLOCATION_ETH_BURNING) / BPS_DENOM;
        uint128 amountPerInterval = uint128(
            dailyAllocation / INTERVALS_PER_DAY
        );
        uint128 additionalAmount = amountPerInterval * missedIntervals;
        _totalAmountForInterval = amountPerInterval + additionalAmount;
        if (_totalAmountForInterval > totalETHBurn) {
            _totalAmountForInterval = uint128(totalETHBurn);
        }
    }

    function _intervalUpdateTitanXForBurning() private {
        if (block.timestamp < startTimeStamp) revert NotStartedYet();
        uint32 timeElapsed = lastBurnedTitanXIntervalStartTimestamp == 0
            ? uint32(block.timestamp - startTimeStamp)
            : uint32(block.timestamp - lastBurnedTitanXIntervalStartTimestamp);
        uint32 _lastInterval;
        uint128 _amountAllocated;
        uint32 _missedIntervals;
        uint32 _intervalStart;
        bool updated = false;
        if (lastBurnedTitanXIntervalStartTimestamp == 0) {
            (
                _lastInterval,
                _amountAllocated,
                _missedIntervals
            ) = _calculateIntervalsTitanXBurn(timeElapsed);
            _intervalStart = startTimeStamp;
            updated = true;
        } else if (timeElapsed > INTERVAL_TIME) {
            (
                _lastInterval,
                _amountAllocated,
                _missedIntervals
            ) = _calculateIntervalsTitanXBurn(timeElapsed);
            _intervalStart = lastBurnedTitanXIntervalStartTimestamp;
            updated = true;
            _missedIntervals++;
        }
        if (updated) {
            lastBurnedTitanXIntervalStartTimestamp =
                _intervalStart +
                (_missedIntervals * INTERVAL_TIME);
            titanXIntervalsBurn[_lastInterval] = IntervalBurn({
                amountAllocated: _amountAllocated,
                amountBurned: 0
            });
            lastTitanXBurnIntervalNumber = _lastInterval;
        }
    }

    function _intervalUpdateTitanXForBuilding() private {
        if (block.timestamp < startTimeStamp) revert NotStartedYet();
        uint32 timeElapsed = lastTitanXBuildIntervalStartTimestamp == 0
            ? uint32(block.timestamp - startTimeStamp)
            : uint32(block.timestamp - lastTitanXBuildIntervalStartTimestamp);
        uint32 _lastInterval;
        uint128 _amountAllocated;
        uint32 _missedIntervals;
        uint32 _intervalStart;
        bool updated = false;
        if (lastTitanXBuildIntervalStartTimestamp == 0) {
            (
                _lastInterval,
                _amountAllocated,
                _missedIntervals
            ) = _calculateIntervalsTitanXBuild(timeElapsed);
            _intervalStart = startTimeStamp;
            updated = true;
        } else if (timeElapsed > INTERVAL_TIME) {
            (
                _lastInterval,
                _amountAllocated,
                _missedIntervals
            ) = _calculateIntervalsTitanXBuild(timeElapsed);
            _intervalStart = lastTitanXBuildIntervalStartTimestamp;
            updated = true;
            _missedIntervals++;
        }
        if (updated) {
            lastTitanXBuildIntervalStartTimestamp =
                _intervalStart +
                (_missedIntervals * INTERVAL_TIME);
            titanXIntervalsBuild[_lastInterval] = IntervalBuild({
                amountAllocated: _amountAllocated,
                amountBurned: 0
            });
            lastTitanXBuildIntervalNumber = _lastInterval;
        }
    }

    function _intervalUpdateETHForBurning() private {
        if (block.timestamp < startTimeStamp) revert NotStartedYet();
        uint32 timeElapsed = lastBurnedETHIntervalStartTimestamp == 0
            ? uint32(block.timestamp - startTimeStamp)
            : uint32(block.timestamp - lastBurnedETHIntervalStartTimestamp);
        uint32 _lastInterval;
        uint128 _amountAllocated;
        uint32 _missedIntervals;
        uint32 _intervalStart;
        bool updated = false;
        if (lastBurnedETHIntervalStartTimestamp == 0) {
            (
                _lastInterval,
                _amountAllocated,
                _missedIntervals
            ) = _calculateIntervalsETHBurn(timeElapsed);
            _intervalStart = startTimeStamp;
            updated = true;
        } else if (timeElapsed > INTERVAL_TIME) {
            (
                _lastInterval,
                _amountAllocated,
                _missedIntervals
            ) = _calculateIntervalsETHBurn(timeElapsed);
            _intervalStart = lastBurnedETHIntervalStartTimestamp;
            updated = true;
            _missedIntervals++;
        }
        if (updated) {
            lastBurnedETHIntervalStartTimestamp =
                _intervalStart +
                (_missedIntervals * INTERVAL_TIME);
            ethIntervalsBurn[_lastInterval] = IntervalBurn({
                amountAllocated: _amountAllocated,
                amountBurned: 0
            });
            lastETHBurnIntervalNumber = _lastInterval;
        }
    }

    function _intervalUpdateETHForBuilding() private {
        if (block.timestamp < startTimeStamp) revert NotStartedYet();
        uint32 timeElapsed = lastETHBuildIntervalStartTimestamp == 0
            ? uint32(block.timestamp - startTimeStamp)
            : uint32(block.timestamp - lastETHBuildIntervalStartTimestamp);
        uint32 _lastInterval;
        uint128 _amountAllocated;
        uint32 _missedIntervals;
        uint32 _intervalStart;
        bool updated = false;
        if (lastETHBuildIntervalStartTimestamp == 0) {
            (
                _lastInterval,
                _amountAllocated,
                _missedIntervals
            ) = _calculateIntervalsETHBuild(timeElapsed);
            _intervalStart = startTimeStamp;
            updated = true;
        } else if (timeElapsed > INTERVAL_TIME) {
            (
                _lastInterval,
                _amountAllocated,
                _missedIntervals
            ) = _calculateIntervalsETHBuild(timeElapsed);
            _intervalStart = lastETHBuildIntervalStartTimestamp;
            updated = true;
            _missedIntervals++;
        }
        if (updated) {
            lastETHBuildIntervalStartTimestamp =
                _intervalStart +
                (_missedIntervals * INTERVAL_TIME);
            ethIntervalsBuild[_lastInterval] = IntervalBuild({
                amountAllocated: _amountAllocated,
                amountBurned: 0
            });
            lastETHBuildIntervalNumber = _lastInterval;
        }
    }

    function _sortAmounts(
        uint256 titanXAmount,
        uint256 torusAmount
    )
        internal
        view
        returns (
            uint256 amount0,
            uint256 amount1,
            address token0,
            address token1
        )
    {
        address _titanX = TITAN_X_ADDRESS;
        address _torus = address(torusToken);
        (token0, token1) = _titanX < _torus
            ? (_titanX, _torus)
            : (_torus, _titanX);
        (amount0, amount1) = token0 == _titanX
            ? (titanXAmount, torusAmount)
            : (torusAmount, titanXAmount);
    }

    function _swapTitanXForTorus(
        uint256 amountTitanX,
        uint256 _deadline
    ) private returns (uint256 _torusAmount) {
        titanX.approve(UNISWAP_V3_ROUTER, amountTitanX);
        bytes memory path = abi.encodePacked(TITAN_X_ADDRESS, POOL_FEE, address(torusToken));

        uint256 expectedTorusAmount = getTorusQuoteForTitanX(amountTitanX);
        uint256 adjustedTorusAmount = (expectedTorusAmount * (100 - titanXToTorusSlippage)) / 100;

        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: _deadline,
                amountIn: amountTitanX,
                amountOutMinimum: adjustedTorusAmount
            });
        return ISwapRouter(UNISWAP_V3_ROUTER).exactInput(params);
    }

    /* ================================================================
                           BUILD (BuyAndBuild) FUNCTIONS
       ================================================================ */

    /**
     * @notice Distributes TitanX for building (build flow).
     */
    function distributeTitanXForBuilding(uint256 _amount) external {
        if (_amount == 0) revert InvalidInput();

        if (
            block.timestamp > startTimeStamp &&
            block.timestamp - lastTitanXBuildIntervalStartTimestamp >
            INTERVAL_TIME
        ) {
            _intervalUpdateTitanXForBuilding();
        }

        TransferHelper.safeTransferFrom(
            TITAN_X_ADDRESS,
            msg.sender,
            address(this),
            _amount
        );

        totalTitanXForBuild += _amount;

        if (block.timestamp >= lastFractalRelease + FRACTAL_RELEASE_INTERVAL) {
            releaseFractalFunds();
        }
    }

    /**
     * @notice Distributes ETH for building (build flow).
     */
    function distributeETHForBuilding() external payable {
        if (msg.value == 0) revert InvalidInput();

        if (
            block.timestamp > startTimeStamp &&
            block.timestamp - lastETHBuildIntervalStartTimestamp >
            INTERVAL_TIME
        ) {
            _intervalUpdateETHForBuilding();
        }

        totalETHForBuild += msg.value;

        if (block.timestamp >= lastFractalRelease + FRACTAL_RELEASE_INTERVAL) {
            releaseFractalFunds();
        }
    }

    /**
     * @notice Swaps ETH for TitanX, then swaps half of the TitanX for Torus and adds liquidity (build flow).
     * @param _deadline The deadline for the swaps.
     */
    function swapETHForTorusAndBuild(uint32 _deadline) external nonReentrant buildETHIntervalUpdate{
        if (!liquidityAddedBuild) revert NotStartedYet();

        IntervalBuild storage currInterval = ethIntervalsBuild[
            lastETHBuildIntervalNumber
        ];
        if (currInterval.amountBurned != 0) revert IntervalAlreadyUsed();

        currInterval.amountBurned = currInterval.amountAllocated;
        uint256 incentive = (currInterval.amountAllocated *
            INCENTIVE_FEE_BUILD) / BPS_DENOM;

        uint256 ethToSwapAndBuild = currInterval.amountAllocated - incentive;
        uint256 titanXAmount = _swapETHForTitanX(ethToSwapAndBuild, _deadline);

        totalETHBuilt += ethToSwapAndBuild;
        totalETHForBuild -= ethToSwapAndBuild + incentive;
        ethUsedForBuilds += ethToSwapAndBuild;

        uint256 half = titanXAmount / 2;
        uint256 remainder = titanXAmount - half;
        uint256 torusPurchased = _swapTitanXForTorus(half, _deadline);

        _addLiquidityBuild(remainder, torusPurchased, _deadline);

        if (block.timestamp >= lastFractalRelease + FRACTAL_RELEASE_INTERVAL) {
            releaseFractalFunds();
        }

        burnTorus();
        (bool success, ) = payable(msg.sender).call{
            value: incentive,
            gas: 30000
        }("");
        require(success, "Transfer failed");

        emit BuyAndBuild(ethToSwapAndBuild, torusPurchased, msg.sender);
    }

    /**
     * @notice Swaps TitanX for Torus and adds liquidity (build flow).
     * @param _deadline The deadline for the swap.
     */
    function swapTitanXForTorusAndBuild(
        uint32 _deadline
    ) external nonReentrant buildTitanXIntervalUpdate{
        if (!liquidityAddedBuild) revert NotStartedYet();

        IntervalBuild storage currInterval = titanXIntervalsBuild[
            lastTitanXBuildIntervalNumber
        ];
        if (currInterval.amountBurned != 0) revert IntervalAlreadyUsed();

        currInterval.amountBurned = currInterval.amountAllocated;
        uint256 incentive = (currInterval.amountAllocated *
            INCENTIVE_FEE_BUILD) / BPS_DENOM;

        uint256 titanXToUse = currInterval.amountAllocated - incentive;
        uint256 half = titanXToUse / 2;
        uint256 remainder = titanXToUse - half;

        totalTitanXBuilt += titanXToUse;
        totalTitanXForBuild -= titanXToUse + incentive;
        titanXUsedForBuilds += titanXToUse;

        uint256 torusPurchased = _swapTitanXForTorus(half, _deadline);

        _addLiquidityBuild(remainder, torusPurchased, _deadline);

        if (block.timestamp >= lastFractalRelease + FRACTAL_RELEASE_INTERVAL) {
            releaseFractalFunds();
        }

        burnTorus();
        TransferHelper.safeTransfer(address(titanX), msg.sender, incentive);

        emit BuyAndBuild(titanXToUse, torusPurchased, msg.sender);
    }

    /// @notice Adds more liquidity in the “build” flow, refunding any slippage leftovers
    function _addLiquidityBuild(
        uint256 titanXAmount,
        uint256 torusAmount,
        uint256 _deadline
    ) internal {
        (
        uint256 amount0,
        uint256 amount1,
        address token0,
        address token1
        ) = _sortAmounts(titanXAmount, torusAmount);

        TransferHelper.safeApprove(token0, address(POSITION_MANAGER), amount0);
        TransferHelper.safeApprove(token1, address(POSITION_MANAGER), amount1);

        uint256 amount0Min = (amount0 * (100 - liquiditySlippage)) / 100;
        uint256 amount1Min = (amount1 * (100 - liquiditySlippage)) / 100;

        INonfungiblePositionManager.IncreaseLiquidityParams memory params =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId:         lpToken.tokenId,
                amount0Desired:  amount0,
                amount1Desired:  amount1,
                amount0Min:      amount0Min,
                amount1Min:      amount1Min,
                deadline:        _deadline
            });

        (, uint256 used0, uint256 used1) =
            POSITION_MANAGER.increaseLiquidity(params);

        if (amount0 > used0) {
            TransferHelper.safeTransfer(token0, torusToken.genesisWallet(), amount0 - used0);
        }
        if (amount1 > used1) {
            TransferHelper.safeTransfer(token1, torusToken.genesisWallet(), amount1 - used1);
        }

        TransferHelper.safeApprove(token0, address(POSITION_MANAGER), 0);
        TransferHelper.safeApprove(token1, address(POSITION_MANAGER), 0);
    }

    // --- Internal interval update functions for build flow ---

    function _calculateIntervalsTitanXBuild(
        uint256 timeElapsed
    )
        internal
        view
        returns (
            uint32 _lastIntervalNumber,
            uint128 _totalAmountForInterval,
            uint32 missedIntervals
        )
    {
        if (lastTitanXBuildIntervalStartTimestamp == 0) {
            missedIntervals = timeElapsed <= INTERVAL_TIME
                ? 0
                : uint32(timeElapsed / INTERVAL_TIME);
        } else {
            missedIntervals = timeElapsed <= INTERVAL_TIME
                ? 0
                : uint32(timeElapsed / INTERVAL_TIME) - 1;
        }
        _lastIntervalNumber =
            lastTitanXBuildIntervalNumber +
            missedIntervals +
            1;
        uint256 dailyAllocation = (totalTitanXForBuild *
            DAILY_ALLOCATION_TITAN_X_BUILDING) / BPS_DENOM;
        uint128 amountPerInterval = uint128(
            dailyAllocation / INTERVALS_PER_DAY
        );
        uint128 additionalAmount = amountPerInterval * missedIntervals;
        _totalAmountForInterval = amountPerInterval + additionalAmount;
        if (_totalAmountForInterval > totalTitanXForBuild) {
            _totalAmountForInterval = uint128(totalTitanXForBuild);
        }
    }

    function _calculateIntervalsETHBuild(
        uint256 timeElapsed
    )
        internal
        view
        returns (
            uint32 _lastIntervalNumber,
            uint128 _totalAmountForInterval,
            uint32 missedIntervals
        )
    {
        if (lastETHBuildIntervalStartTimestamp == 0) {
            missedIntervals = timeElapsed <= INTERVAL_TIME
                ? 0
                : uint32(timeElapsed / INTERVAL_TIME);
        } else {
            missedIntervals = timeElapsed <= INTERVAL_TIME
                ? 0
                : uint32(timeElapsed / INTERVAL_TIME) - 1;
        }
        _lastIntervalNumber = lastETHBuildIntervalNumber + missedIntervals + 1;
        uint256 dailyAllocation = (totalETHForBuild *
            DAILY_ALLOCATION_ETH_BUILDING) / BPS_DENOM;
        uint128 amountPerInterval = uint128(
            dailyAllocation / INTERVALS_PER_DAY
        );
        uint128 additionalAmount = amountPerInterval * missedIntervals;
        _totalAmountForInterval = amountPerInterval + additionalAmount;
        if (_totalAmountForInterval > totalETHForBuild) {
            _totalAmountForInterval = uint128(totalETHForBuild);
        }
    }

    function _swapETHForTitanX(
        uint256 ethAmount,
        uint256 _deadline
    ) internal returns (uint256 titanXReceived) {
        bytes memory path = abi.encodePacked(
            WETH_ADDRESS,
            POOL_FEE,
            TITAN_X_ADDRESS
        );
        uint256 expectedTitanXAmount = getTitanXQuoteForETH(ethAmount);
        uint256 adjustedTitanXAmount = (expectedTitanXAmount *
            (100 - ethToTitanXSlippage)) / 100;
        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: _deadline,
                amountIn: ethAmount,
                amountOutMinimum: adjustedTitanXAmount
            });

        return
            ISwapRouter(UNISWAP_V3_ROUTER).exactInput{value: ethAmount}(params);
    }

    /* ================================================================
                           PUBLIC GETTERS
       ================================================================ */
    function getTorusQuoteForTitanX(
        uint256 baseAmount
    ) public view returns (uint256 quote) {
        address poolAddress = torusToken.titanXTorusPool();
        uint32 secondsAgo = 15 * 60;
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(
            poolAddress
        );
        if (oldestObservation < secondsAgo) secondsAgo = oldestObservation;
        (int24 arithmeticMeanTick, ) = OracleLibrary.consult(
            poolAddress,
            secondsAgo
        );
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        quote = OracleLibrary.getQuoteForSqrtRatioX96(
            sqrtPriceX96,
            baseAmount,
            TITAN_X_ADDRESS,
            address(torusToken)
        );
    }

    function getTitanXQuoteForETH(
        uint256 baseAmount
    ) public view returns (uint256 quote) {
        address poolAddress = TITAN_X_ETH_POOL;
        uint32 secondsAgo = 15 * 60;
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(
            poolAddress
        );
        if (oldestObservation < secondsAgo) {
            secondsAgo = oldestObservation;
        }
        (int24 arithmeticMeanTick, ) = OracleLibrary.consult(
            poolAddress,
            secondsAgo
        );
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        quote = OracleLibrary.getQuoteForSqrtRatioX96(
            sqrtPriceX96,
            baseAmount,
            WETH_ADDRESS,
            TITAN_X_ADDRESS
        );
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

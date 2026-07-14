// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/* === OZ === */
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/* === SYSTEM === */
import {Torus} from "./Torus.sol";
import {TorusBuyAndProcess} from "./TorusBuyAndProcess.sol";

/* === CONST === */
import "./const/BuyAndProcessConst.sol";

/* === UNISWAP V3 === */
import {TransferHelper} from "../lib/v3-periphery/contracts/libraries/TransferHelper.sol";
import {FullMath} from "../lib/v3-core/contracts/libraries/FullMath.sol";
import {OracleLibrary} from "./library/OracleLibrary.sol";
import {TickMath} from "../lib/v3-core/contracts/libraries/TickMath.sol";
import {ISwapRouter} from "../lib/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/**
 * @title TorusCreateAndStake
 * @dev This contract allows users to (1) create Torus tokens by depositing TitanX/ETH,
 *      and (2) stake their Torus to earn newly minted Torus. Both actions become more
 *      expensive over time, following the difficulty factor.
 */
contract TorusCreateAndStake is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ================================================================
                        CONSTANTS / IMMUTABLE / VARIABLES
       ================================================================ */
    TorusBuyAndProcess public immutable buyAndProcess;
    Torus public immutable torus;

    uint256 public protocolStart;
    uint256 public totalTitanXBurnt;

    mapping(uint24 => uint) public totalShares;
    mapping(uint24 => uint) public rewardPool;
    mapping(uint24 => uint) public penaltiesInRewardPool;

    /* ================================================================
                                STAKE STRUCT
       ================================================================ */

    /**
     * @notice Stores info about a user’s stake: how many TORUS were staked,
     *         for how many days, the start/end times, the user’s shares, etc.
     */
    struct StakeTorus {
        uint256 principal; // The amount of TORUS staked.
        uint power;
        uint24 stakingDays; // Duration in days (1..88).
        uint256 startTime; // Timestamp of stake start.
        uint24 startDayIndex; // The day index of the start of the stake.
        uint256 endTime; // startTime + (stakingDays * CREATE_CYCLE_DURATION).
        uint256 shares; // Used for distributing newly minted TORUS.
        bool claimedCreate; // Whether this creation has been fully claimed.
        bool claimedStake; // Whether this stake has been fully claimed.
        uint costTitanX; // The cost of titanX for the position.
        uint costETH; // The cost of ETH for the position.
        uint rewards; // Total amount of rewards paid.
        uint penalties; // Total penalties incurred.
        uint claimedAt; // Timestamp the stake was claimed at.
        bool isCreate; // Is the position from a create torus.
    }

    /// @dev Tracks each user’s "stake" positions.
    mapping(address => StakeTorus[]) public stakePositions;

    /* ================================================================
                                   ERRORS
       ================================================================ */
    error InvalidLength();
    error InvalidPower();
    error NotReadyToClaim(uint256 endTime, uint256 current);
    error AlreadyClaimed();
    error OnlyBuyAndProcess();
    error InsufficientETH();
    error CannotStakeZero();
    error NotEligibleForEarlyClaim();

    /* ================================================================
                                  EVENTS
       ================================================================ */

    // ---------------- CREATE EVENTS ----------------
    event Created(
        address indexed user,
        uint256 stakeIndex,
        uint256 torusAmount,
        uint256 endTime
    );
    event Claimed(
        address indexed user,
        uint256 stakeIndex,
        uint256 torusAmount
    );
    event ClaimedBatch(
        address indexed user,
        uint256[] stakeIndices,
        uint256 totalMinted,
        uint256 totalReturned
    );

    // ---------------- STAKE EVENTS -----------------
    event Staked(
        address indexed user,
        uint256 stakeIndex,
        uint256 principal,
        uint256 stakingDays,
        uint256 shares
    );
    event StakeClaimed(
        address indexed user,
        uint256 stakeIndex,
        uint256 principal,
        uint256 rewards
    );
    event EarlyStakeClaimed(
        address indexed user,
        uint256 stakeIndex,
        uint256 principal,
        uint256 partialRewards
    );

    /* ================================================================
                                 CONSTRUCTOR
       ================================================================ */
    constructor(
        address _buyAndProcess,
        address _torus,
        uint256 _startTimestamp
    ) {
        buyAndProcess = TorusBuyAndProcess(_buyAndProcess);
        torus = Torus(_torus);
        protocolStart = _startTimestamp;
        rewardPool[1] = INITIAL_DAILY_REWARD;
    }

    /* ================================================================
                                USER FUNCTIONS
       ================================================================ */

    /**
     * @notice Create a new torus create period that lasts "lengthInDays", using "power" from 1..10000.
     * @param power How many "power" units from 1..10000.
     * @param lengthInDays Duration in days (1..88).
     */
    function createTorus(
        uint256 power,
        uint24 lengthInDays
    ) external payable nonReentrant {
        if (block.timestamp < protocolStart) revert InvalidLength();
        if (lengthInDays < MIN_DAYS || lengthInDays > MAX_DAYS) {
            revert InvalidLength();
        }
        if (power < MIN_POWER || power > MAX_POWER) {
            revert InvalidPower();
        }

        uint256 ethBalanceBefore = address(this).balance - msg.value;
        uint256 titanXBalanceBefore = IERC20(TITAN_X_ADDRESS).balanceOf(address(this));

        uint24 currentDay = _checkAndUpdateRewardPool();
        uint256 costTitanX = (COST_100_POWER_TITANX * power) / 100;
        uint costETH = _distributeFees(costTitanX);

        uint256 partialForLength = (BASE_FOR_88_DAYS_100_POWER_DAY1 *
            lengthInDays) / 88;
        uint256 partialForPower = (partialForLength * power) / 100;
        uint256 difficulty = getDifficultyFactor();
        uint256 mintedTorus = (partialForPower * 1e18) / difficulty;

        uint256 endTime = block.timestamp + (lengthInDays * CREATE_CYCLE_DURATION);

        uint shares = _calculateShares(mintedTorus, lengthInDays);

        StakeTorus memory stakePos;
        stakePos.startDayIndex = currentDay;
        stakePos.principal = mintedTorus;
        stakePos.stakingDays = lengthInDays;
        stakePos.startTime = block.timestamp;
        stakePos.endTime = block.timestamp + (lengthInDays * CREATE_CYCLE_DURATION);
        stakePos.shares = shares;
        stakePos.claimedCreate = false;
        stakePos.claimedStake = false;
        stakePos.power = power;
        stakePos.costETH = costETH;
        stakePos.costTitanX = costTitanX;
        stakePos.isCreate = true;

        stakePositions[msg.sender].push(stakePos);
        uint256 stakeIndex = stakePositions[msg.sender].length - 1;

        _addShares(currentDay, lengthInDays, shares);

        if (
            !buyAndProcess.liquidityAdded() &&
            buyAndProcess.totalTitanXBurn() >= INITIAL_TITAN_X_FOR_LIQ
        ) {
            buyAndProcess.addLiquidityToTorusTitanXPool(
                uint32(block.timestamp + 60)
            );
        }

        uint256 ethBalanceAfter = address(this).balance;
        uint256 ethBalanceRemaining = 0;
        uint256 titanXBalanceAfter = IERC20(TITAN_X_ADDRESS).balanceOf(address(this));
        uint256 titanXBalanceRemaining = 0;
        if (ethBalanceAfter > ethBalanceBefore) {
            ethBalanceRemaining = address(this).balance - ethBalanceBefore;
        }
        if (titanXBalanceAfter > titanXBalanceBefore) {
            titanXBalanceRemaining = IERC20(TITAN_X_ADDRESS).balanceOf(address(this)) - titanXBalanceBefore;
        }

        // Refund any remaining ETH or TitanX dust to the genesis wallet to maintain good accounting.
        if (ethBalanceRemaining > 0) {
            (bool success, ) = payable(torus.genesisWallet()).call{
                value: ethBalanceRemaining
            }("");
            require(success, "Refund transfer failed");
        }
        if (titanXBalanceRemaining > 0) {
            IERC20(TITAN_X_ADDRESS).safeTransfer(
                torus.genesisWallet(),
                titanXBalanceRemaining
            );
        }

        emit Created(msg.sender, stakeIndex, mintedTorus, endTime);
    }

    /**
     * @notice Stake an amount of already owned TORUS for a chosen duration, paying
     *         a fee = 5% of “the cost to create that many tokens for the same duration”.
     * @param torusAmount The amount of TORUS to stake.
     * @param stakingDays The duration (1..88).
     */
    function stakeTorus(
        uint256 torusAmount,
        uint24 stakingDays
    ) external payable nonReentrant {
        if (block.timestamp < protocolStart) revert InvalidLength();
        if (stakingDays < MIN_DAYS || stakingDays > MAX_DAYS)
            revert InvalidLength();
        if (torusAmount == 0) revert CannotStakeZero();

        uint256 ethBalanceBefore = address(this).balance - msg.value;
        uint256 titanXBalanceBefore = IERC20(TITAN_X_ADDRESS).balanceOf(address(this));

        uint24 currentDay = _checkAndUpdateRewardPool();

        // pay fee
        uint256 partialForLength = (BASE_FOR_88_DAYS_100_POWER_DAY1 *
            stakingDays) / 88;
        uint256 difficulty = getDifficultyFactor();
        uint partialForPower = (torusAmount * difficulty);
        uint power = (partialForPower * 100) / partialForLength;
        uint256 costTitanX = (COST_100_POWER_TITANX * power) / (100 * 20 * 1e18); // 5% fee
        uint costETH = _distributeFees(costTitanX);

        TransferHelper.safeTransferFrom(
            address(torus),
            msg.sender,
            address(this),
            torusAmount
        );

        uint shares = _calculateShares(torusAmount, stakingDays);

        StakeTorus memory stakePos;
        stakePos.startDayIndex = currentDay;
        stakePos.principal = torusAmount;
        stakePos.stakingDays = stakingDays;
        stakePos.startTime = block.timestamp;
        stakePos.endTime = block.timestamp + (stakingDays * CREATE_CYCLE_DURATION);
        stakePos.shares = shares;
        stakePos.claimedCreate = true;
        stakePos.power = 0;
        stakePos.costETH = costETH;
        stakePos.costTitanX = costTitanX;

        stakePositions[msg.sender].push(stakePos);
        uint256 stakeIndex = stakePositions[msg.sender].length - 1;

        _addShares(currentDay, stakingDays, shares);

        if (
            !buyAndProcess.liquidityAdded() &&
            buyAndProcess.totalTitanXBurn() >= INITIAL_TITAN_X_FOR_LIQ
        ) {
            buyAndProcess.addLiquidityToTorusTitanXPool(
                uint32(block.timestamp + 60)
            );
        }

        uint256 ethBalanceAfter = address(this).balance;
        uint256 ethBalanceRemaining = 0;
        uint256 titanXBalanceAfter = IERC20(TITAN_X_ADDRESS).balanceOf(address(this));
        uint256 titanXBalanceRemaining = 0;
        if (ethBalanceAfter > ethBalanceBefore) {
            ethBalanceRemaining = address(this).balance - ethBalanceBefore;
        }
        if (titanXBalanceAfter > titanXBalanceBefore) {
            titanXBalanceRemaining = IERC20(TITAN_X_ADDRESS).balanceOf(address(this)) - titanXBalanceBefore;
        }

        // Refund any remaining ETH or TitanX dust to the genesis wallet to maintain good accounting.
        if (ethBalanceRemaining > 0) {
            (bool success, ) = payable(torus.genesisWallet()).call{
                value: ethBalanceRemaining
            }("");
            require(success, "Refund transfer failed");
        }
        if (titanXBalanceRemaining > 0) {
            IERC20(TITAN_X_ADDRESS).safeTransfer(
                torus.genesisWallet(),
                titanXBalanceRemaining
            );
        }

        emit Staked(
            msg.sender,
            stakeIndex,
            torusAmount,
            stakingDays,
            stakePos.shares
        );
    }

    /**
     * @notice Claim your stake in full after its end time, receiving principal + all earned rewards.
     * @param stakeIndex Which stake to claim.
     */
    function claim(uint256 stakeIndex) external nonReentrant {
        StakeTorus storage stakePos = stakePositions[msg.sender][stakeIndex];
        if (stakePos.claimedStake && stakePos.claimedCreate) revert AlreadyClaimed();
        if (block.timestamp < stakePos.endTime) {
            revert NotReadyToClaim(stakePos.endTime, block.timestamp);
        }

        _checkAndUpdateRewardPool();

        uint256 rewards = calculateStakingRewards(stakePos);
        uint256 penalty = 0;

        uint256 graceSecs = GRACE_PERIOD * CREATE_CYCLE_DURATION;
        if (block.timestamp > stakePos.endTime + graceSecs) {
            uint256 lateSecs = block.timestamp - (stakePos.endTime + graceSecs);
            uint256 daysLate = lateSecs / CREATE_CYCLE_DURATION;
            if (daysLate > PENALTY_DAYS) daysLate = PENALTY_DAYS;

            penalty = (rewards * daysLate) / PENALTY_DAYS;
            rewards -= penalty;
            stakePos.penalties = penalty;

            uint24 nextDay = getCurrentDayIndex() + 1;
            penaltiesInRewardPool[nextDay] += penalty / 2;
        }

        uint256 totalAmount;
        if (!stakePos.claimedCreate) {
            totalAmount = stakePos.principal + rewards;
            stakePos.claimedCreate = true;
            stakePos.claimedStake  = true;
            stakePos.rewards       = rewards;
            stakePos.claimedAt     = block.timestamp;
            emit Claimed(msg.sender, stakeIndex, totalAmount);
        } else {
            totalAmount = rewards;
            stakePos.claimedStake = true;
            stakePos.rewards      = rewards;
            stakePos.claimedAt    = block.timestamp;
            TransferHelper.safeTransfer(address(torus), msg.sender, stakePos.principal);
            emit StakeClaimed(msg.sender, stakeIndex, stakePos.principal, rewards);
        }

        torus.mint(msg.sender, totalAmount);
    }

    /**
     * @notice Claim multiple matured stakes in one transaction.
     * @param stakeIndexes The list of stake positions to claim.
     */
    function claimBatch(uint256[] calldata stakeIndexes) external nonReentrant {
        uint256 totalMintAmount;
        uint256 totalReturnPrincipal;

        _checkAndUpdateRewardPool();

        for (uint256 i = 0; i < stakeIndexes.length; i++) {
            uint256 idx = stakeIndexes[i];
            StakeTorus storage stakePos = stakePositions[msg.sender][idx];

            if (stakePos.claimedStake && stakePos.claimedCreate) {
                revert AlreadyClaimed();
            }
            if (block.timestamp < stakePos.endTime) {
                revert NotReadyToClaim(stakePos.endTime, block.timestamp);
            }

            uint256 rewards = calculateStakingRewards(stakePos);
            uint256 penalty = 0;

            uint256 graceSecs = GRACE_PERIOD * CREATE_CYCLE_DURATION;
            if (block.timestamp > stakePos.endTime + graceSecs) {
                uint256 lateSecs = block.timestamp - (stakePos.endTime + graceSecs);
                uint256 daysLate = lateSecs / CREATE_CYCLE_DURATION;
                if (daysLate > PENALTY_DAYS) daysLate = PENALTY_DAYS;

                penalty = (rewards * daysLate) / PENALTY_DAYS;
                rewards -= penalty;
                stakePos.penalties = penalty;

                uint24 nextDay = getCurrentDayIndex() + 1;
                penaltiesInRewardPool[nextDay] += penalty / 2;
            }

            if (!stakePos.claimedCreate) {
                totalMintAmount += stakePos.principal + rewards;
                stakePos.claimedCreate = true;
                stakePos.claimedStake  = true;
                stakePos.rewards       = rewards;
                stakePos.claimedAt     = block.timestamp;
            } else {
                totalMintAmount      += rewards;
                totalReturnPrincipal += stakePos.principal;
                stakePos.claimedStake = true;
                stakePos.rewards      = rewards;
                stakePos.claimedAt    = block.timestamp;
            }
        }

        if (totalReturnPrincipal > 0) {
            TransferHelper.safeTransfer(
                address(torus),
                msg.sender,
                totalReturnPrincipal
            );
        }

        if (totalMintAmount > 0) {
            torus.mint(msg.sender, totalMintAmount);
        }

        emit ClaimedBatch(
            msg.sender,
            stakeIndexes,
            totalMintAmount,
            totalReturnPrincipal
        );
    }

    /**
     * @notice Allows ending the stake early (after at least 50% of duration),
     *         returning principal + partial rewards.
     * @param stakeIndex Which stake to end early.
     */
    function earlyEndStake(uint256 stakeIndex) external nonReentrant {
        StakeTorus storage stakePos = stakePositions[msg.sender][stakeIndex];
        if (stakePos.claimedStake) revert AlreadyClaimed();
        if (!stakePos.claimedCreate) revert NotEligibleForEarlyClaim();

        if (stakePos.stakingDays == 1) revert NotEligibleForEarlyClaim();

        uint256 totalDuration = stakePos.endTime - stakePos.startTime;
        uint256 elapsed       = block.timestamp - stakePos.startTime;

        if (elapsed < (totalDuration / 2)) revert NotEligibleForEarlyClaim();
        if (elapsed >= totalDuration) revert NotEligibleForEarlyClaim();

        _checkAndUpdateRewardPool();
        stakePos.claimedStake = true;

        uint256 principal = stakePos.principal;
        uint24 startDay   = stakePos.startDayIndex;
        uint24 todayIndex = getCurrentDayIndex();

        uint256 daysElapsed = todayIndex > startDay
            ? todayIndex - startDay
            : 0;
        if (daysElapsed > stakePos.stakingDays) {
            daysElapsed = stakePos.stakingDays;
        }

        uint256 totalRewards = 0;
        for (uint8 i = 0; i < daysElapsed; i++) {
            uint24 dayIdx = startDay + i;
            uint256 ts = totalShares[dayIdx];
            if (ts == 0) continue;
            totalRewards += (rewardPool[dayIdx]            * stakePos.shares) / ts;
            totalRewards += (penaltiesInRewardPool[dayIdx] * stakePos.shares) / ts;
        }

        for (uint8 i = uint8(daysElapsed); i < stakePos.stakingDays; i++) {
            totalShares[startDay + i] -= stakePos.shares;
        }

        uint256 pctDone = (elapsed * 100) / totalDuration;
        uint256 claimablePct = pctDone >= 50
            ? Math.min((pctDone - 50) * 2, 100)
            : 0;

        uint256 partialRewards = (totalRewards * claimablePct) / 100;
        stakePos.penalties = totalRewards - partialRewards;
        stakePos.rewards   = partialRewards;
        stakePos.claimedAt = block.timestamp;

        penaltiesInRewardPool[todayIndex + 1] += (totalRewards - partialRewards) / 2;

        TransferHelper.safeTransfer(address(torus), msg.sender, principal);
        torus.mint(msg.sender, partialRewards);

        emit EarlyStakeClaimed(
            msg.sender,
            stakeIndex,
            principal,
            partialRewards
        );
    }

    /* ================================================================
                           VIEW / HELPER FUNCTIONS
       ================================================================ */
    function getStakePositions(
        address user
    ) external view returns (StakeTorus[] memory) {
        return stakePositions[user];
    }

    /**
     * @notice Returns the day index (starting at 1) since protocol start.
     */
    function getCurrentDayIndex() public view returns (uint24 dayIndex) {
        if (block.timestamp < protocolStart) return 1;

        return getDayIndex(block.timestamp);
    }

    function getDayIndex(
        uint timestamp
    ) internal view returns (uint24 dayIndex) {
        uint256 delta = timestamp - protocolStart;
        dayIndex = uint24((delta / CREATE_CYCLE_DURATION) + 1);
    }

    /**
     * @notice Returns the difficulty factor, which grows exponentially with time (in years) since protocol start.
     */
    function getDifficultyFactor() public view returns (uint256) {
        if (block.timestamp < protocolStart) return 1e18;
        uint256 delta = block.timestamp - protocolStart;
        uint deltaDays = delta / CREATE_CYCLE_DURATION;
        delta = deltaDays * CREATE_CYCLE_DURATION;

        int256 tWad = int256((delta * 1e18) / SECONDS_PER_YEAR);
        int256 exponent = (B * tWad) / 1e18;
        int256 diff = expWad(exponent);
        if (diff < 1e18) diff = 1e18;
        return uint256(diff);
    }

    /**
     * @notice Calculates the exponential function in wad (1e18 fixed point).
     */
    function expWad(int256 x) public pure returns (int256) {
        if (x < -41e18) return 0;
        if (x > 130e18) revert("expWad: overflow");
        int256 sum = 1e18;
        int256 term = 1e18;
        for (int256 i = 1; i < 20; i++) {
            term = (term * x) / int256(i * 1e18);
            if (term == 0) break;
            sum += term;
        }
        return sum;
    }

    /**
     * @notice Returns the ETH amount required to get a given amount of TitanX tokens.
     */
    function getEthAmountForTitanX(uint256 titanXAmount) public view returns (uint256 ethAmount) {
        address pool = TITAN_X_ETH_POOL;
        uint32 secondsAgo = 15 * 60;
        uint32 oldest = OracleLibrary.getOldestObservationSecondsAgo(pool);
        if (oldest < secondsAgo) secondsAgo = oldest;

        (int24 arithmeticMeanTick, ) = OracleLibrary.consult(pool, secondsAgo);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);

        ethAmount = OracleLibrary.getQuoteForSqrtRatioX96(
            sqrtPriceX96,
            titanXAmount,
            TITAN_X_ADDRESS,
            WETH_ADDRESS
        );
    }

    /**
     * @notice Distributes the fees for building and burning.
     */
    function _distributeFees(
        uint256 costTitanX
    ) internal returns (uint requiredETH) {
        if (msg.value > 0) {
            requiredETH = getEthAmountForTitanX(costTitanX);
            if (msg.value < requiredETH) revert InsufficientETH();

            uint256 requiredGenesisETH = (requiredETH * torus.genesisFee()) /
                BPS_DENOM;
            uint256 requiredBurnETH = (requiredETH * torus.burnFee()) /
                BPS_DENOM;
            uint256 requiredBuildETH = (requiredETH * torus.buildFee()) /
                BPS_DENOM;
            uint256 requiredTitanXBurn = (requiredETH * torus.titanXBurnFee()) /
                BPS_DENOM;

            (bool success, ) = payable(torus.genesisWallet()).call{
                value: requiredGenesisETH
            }("");
            require(success, "Transfer failed");

            buyAndProcess.distributeETHForBurning{value: requiredBurnETH}();
            buyAndProcess.distributeETHForBuilding{value: requiredBuildETH}();

            uint256 bought = _swapETHForTitanX(requiredTitanXBurn, block.timestamp);
            TransferHelper.safeTransfer(address(TITAN_X_ADDRESS), TITAN_X_BURN_ADDRESS, bought);
            totalTitanXBurnt += bought;
            
            if (msg.value > requiredETH) {
                uint256 refund = msg.value - requiredETH;
                (bool refundSuccess, ) = payable(msg.sender).call{
                    value: refund,
                    gas: 30000
                }("");
                require(refundSuccess, "Refund transfer failed");
            }

            return requiredETH;
        } else {
            uint256 requiredGenesisTitanX = (costTitanX * torus.genesisFee()) /
                BPS_DENOM;
            uint256 requiredBurnTitanX = (costTitanX * torus.burnFee()) /
                BPS_DENOM;
            uint256 requiredBuildTitanX = (costTitanX * torus.buildFee()) /
                BPS_DENOM;
            uint256 requiredTitanXBurn = (costTitanX * torus.titanXBurnFee()) /
                BPS_DENOM;

            IERC20(TITAN_X_ADDRESS).safeTransferFrom(
                msg.sender,
                address(this),
                costTitanX
            );

            IERC20(TITAN_X_ADDRESS).safeTransfer(
                address(torus.genesisWallet()),
                requiredGenesisTitanX
            );

            IERC20(TITAN_X_ADDRESS).approve(address(buyAndProcess), costTitanX - requiredGenesisTitanX);

            buyAndProcess.distributeTitanXForBurning(
                requiredBurnTitanX
            );
            buyAndProcess.distributeTitanXForBuilding(
                requiredBuildTitanX
            );

            TransferHelper.safeTransfer(address(TITAN_X_ADDRESS), TITAN_X_BURN_ADDRESS, requiredTitanXBurn);
            totalTitanXBurnt += requiredTitanXBurn;

            requiredETH = 0;
        }
    }

    /**
        fill in empty rewardPool values of previous days and the next day
     */
    function _checkAndUpdateRewardPool() private returns (uint24 currentDay) {
        currentDay = getCurrentDayIndex();

        uint24 lastFilled = currentDay;
        while (lastFilled > 0 && rewardPool[lastFilled] == 0) {
            lastFilled--;
        }

        if (lastFilled == currentDay) {
            return currentDay;
        }

        for (uint24 d = lastFilled + 1; d <= currentDay; d++) {
            uint256 nextPool = FullMath.mulDiv(
                rewardPool[d - 1],
                BPS_DENOM - DAILY_REDUCTION_RATE,
                BPS_DENOM
            );
            rewardPool[d] = nextPool;

            if (d != currentDay && totalShares[d] == 0) {
                penaltiesInRewardPool[currentDay] += nextPool;
                penaltiesInRewardPool[currentDay] += penaltiesInRewardPool[d];
                penaltiesInRewardPool[d] = 0;
            }
        }

        return currentDay;
    }

    /**
     * @dev Calculates how many TORUS rewards a user’s shares are entitled to.
     *      The formula is:
     *          userRewards = (rewardPool * userShares) / totalShares[dayIndex]
     */
    function calculateStakingRewards(
        StakeTorus memory stakePos
    ) public view returns (uint256) {
        uint reward = 0;

        // and then continue reward reduction day by day
        for (uint8 i = 0; i < stakePos.stakingDays; i++) {
            if (totalShares[stakePos.startDayIndex + i] == 0) continue;

            reward += ((rewardPool[stakePos.startDayIndex + i] *
                stakePos.shares) / totalShares[stakePos.startDayIndex + i]);
            reward += ((penaltiesInRewardPool[stakePos.startDayIndex + i] *
                stakePos.shares) / totalShares[stakePos.startDayIndex + i]);
        }

        return reward;
    }

    function _calculateShares(
        uint amount,
        uint24 lengthInDays
    ) internal pure returns (uint) {
        return amount * lengthInDays * lengthInDays;
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
        uint256 expectedTitanXAmount = buyAndProcess.getTitanXQuoteForETH(ethAmount);
        uint256 adjustedTitanXAmount = (expectedTitanXAmount *
            (100 - buyAndProcess.ethToTitanXSlippage())) / 100;
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
    

    /**
     * @dev Adds up shares per create/stake to totalShares array
     */
    function _addShares(
        uint24 startDayIndex,
        uint lengthInDays,
        uint shares
    ) internal {
        for (uint8 i = 0; i < lengthInDays; i++) {
            totalShares[startDayIndex + i] += shares;
        }
    }
}

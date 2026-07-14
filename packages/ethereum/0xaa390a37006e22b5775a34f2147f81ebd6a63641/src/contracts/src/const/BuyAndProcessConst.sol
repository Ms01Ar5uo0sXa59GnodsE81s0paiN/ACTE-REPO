// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

uint256 constant INCENTIVE_FEE = 150;
uint256 constant INCENTIVE_FEE_BUILD = 150;

address constant TITAN_X_ADDRESS = 0xF19308F923582A6f7c465e5CE7a9Dc1BEC6665B1;
address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant TITAN_X_BURN_ADDRESS = 0x410e10C33a49279f78CB99c8d816F18D5e7D5404;

int256 constant B = 292400000000000000;
uint256 constant SECONDS_PER_YEAR = 31536000;
uint32 constant CREATE_CYCLE_DURATION = 24 hours;

uint256 constant COST_100_POWER_TITANX = 100_000_000e18;

uint24 constant GRACE_PERIOD = 14;
uint256 constant PENALTY_DAYS = 7;

uint256 constant MIN_DAYS = 1;
uint256 constant MAX_DAYS = 88;

uint256 constant MIN_POWER = 1;
uint256 constant MAX_POWER = 1000000;

uint256 constant BASE_FOR_88_DAYS_100_POWER_DAY1 = 10e18;

uint256 constant FRACTAL_RELEASE_INTERVAL = 110 days;
uint256 constant FRACTAL_SPLIT = 28; // 28%
uint256 constant IMMEDIATE_SPLIT = 72; // 72%

uint256 constant BPS_DENOM = 10_000;

/// @dev 48 * 30 = 24 hours
uint256 constant INTERVALS_PER_DAY = 144;
uint32 constant INTERVAL_TIME = 10 minutes;

/* === UNIV3 === */
address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
address constant UNISWAP_V3_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
address constant TITAN_X_ETH_POOL = 0xc45A81BC23A64eA556ab4CdF08A86B61cdcEEA8b;
address constant GENESIS_WALLET = 0x5A1e1d944a8dEaFd532881dEf19CA019Eafc0F3b;

uint24 constant POOL_FEE = 10_000; //1%
uint24 constant DAILY_REDUCTION_RATE = 8; // 0.08%
uint constant INITIAL_DAILY_REWARD = 100_000e18; // Reward begins at 100,000 tokens on day one and reduces by 0.08% of the previous days total, perpetually

int24 constant TICK_SPACING = 200; // Uniswap's tick spacing for 1% pools is 200

uint constant INITIAL_TITAN_X_FOR_LIQ = 200_000_000_000e18;
uint constant INITIAL_LP_MINT = 20_000e18;

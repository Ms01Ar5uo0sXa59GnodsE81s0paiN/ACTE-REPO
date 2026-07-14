// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/* === OZ === */
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/* = SYSTEM */
import {TorusCreateAndStake} from "./TorusCreateAndStake.sol";
import {TorusBuyAndProcess} from "./TorusBuyAndProcess.sol";

/* = LIBS =  */
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/* = UNIV3 = */
import {IUniswapV3Pool} from "../lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "../lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

import "./const/BuyAndProcessConst.sol";

/**
 * @title Torus.win
 * @author BuildTheTech.com
 * @dev ERC20 token contract for Torus tokens.
 * @notice It can be minted by TorusCreate during cycles
 */
contract Torus is ERC20Burnable, Ownable {
    /* ==== IMMUTABLES ==== */

    TorusCreateAndStake public immutable create;
    TorusBuyAndProcess public immutable buyAndProcess;
    address public titanXTorusPool;

    address public genesisWallet;
    uint256 public genesisFee = 369;
    uint256 public burnFee = 6400;
    uint256 public buildFee = 2800;
    uint256 public titanXBurnFee = 431;

    /* ==== ERRORS ==== */

    error OnlyCreate();
    error OnlyBuyAndProcess();

    /* ==== CONSTRUCTOR ==== */

    /**
     * @dev Sets the create and buy and process contract address.
     * @param _torusCreateStartTimestamp The start of the first create cycle
     * @param _torusBuyAndProcessStartTimestamp The start of the buy and process contract
     * @param _owner The owner
     */
    constructor(
        uint32 _torusCreateStartTimestamp,
        uint32 _torusBuyAndProcessStartTimestamp,
        address _owner
    ) payable ERC20("Torus", "TORUS") Ownable(msg.sender) {
        buyAndProcess = new TorusBuyAndProcess(
            _torusBuyAndProcessStartTimestamp,
            _owner
        );
        create = new TorusCreateAndStake(
            address(buyAndProcess),
            address(this),
            _torusCreateStartTimestamp
        );

        buyAndProcess.setCreateAndStakeContract(address(create));
        genesisWallet = GENESIS_WALLET;

        createTitanXTorusPool(
            TITAN_X_ADDRESS,
            INITIAL_TITAN_X_FOR_LIQ
        );
    }

    /* == MODIFIERS == */

    /// @dev Modifier to ensure the function is called only by the create contract.
    modifier onlyCreate() {
        _onlyCreate();
        _;
    }

    /// @dev Modifier to ensure the function is called only by the buy and process contract.
    modifier onlyBuyAndProcess() {
        _onlyBuyAndProcess();
        _;
    }

    /* == EXTERNAL == */

    /**
     * @notice Creates(mints) TORUS tokens to a specified address.
     * @notice This is only callable by the TorusCreate contract
     * @param _to The address to mint the tokens to.
     * @param _amount The amount of tokens to mint.
     */
    function mint(address _to, uint256 _amount) external onlyCreate {
        _mint(_to, _amount);
    }

    /// @notice Mints torus tokens for the initial LP creation
    function createTokensForLP() external onlyBuyAndProcess {
        _mint(address(buyAndProcess), INITIAL_LP_MINT);
    }

    /* == INTERNAL == */

    function _onlyBuyAndProcess() internal view {
        if (msg.sender != address(buyAndProcess)) revert OnlyBuyAndProcess();
    }

    function _onlyCreate() internal view {
        if (msg.sender != address(create)) revert OnlyCreate();
    }

    ///@notice - Creates the TitanX/TORUS Pool on uniswapV3
    ///@notice - Only called once when liquidity is added from BuyAndProcess
    function createTitanXTorusPool(
        address _titanX,
        uint256 _titanXReceived
    ) internal returns (address _titanXTorusPool) {
        address _torus = address(this);

        uint160 sqrtPriceX96;

        (address token0, address token1) = _titanX < _torus
            ? (_titanX, _torus)
            : (_torus, _titanX);

        uint256 titanXAmount = _titanXReceived;
        uint256 torusAmount = INITIAL_LP_MINT;

        (uint256 amount0, uint256 amount1) = token0 == _titanX
            ? (titanXAmount, torusAmount)
            : (torusAmount, titanXAmount);

        sqrtPriceX96 = uint160(
            (Math.sqrt((amount1 * 1e18) / amount0) * 2 ** 96) / 1e9
        );

        INonfungiblePositionManager manager = INonfungiblePositionManager(
            UNISWAP_V3_POSITION_MANAGER
        );

        titanXTorusPool = manager.createAndInitializePoolIfNecessary(
            token0,
            token1,
            POOL_FEE,
            sqrtPriceX96
        );

        _titanXTorusPool = titanXTorusPool;

        IUniswapV3Pool(titanXTorusPool).increaseObservationCardinalityNext(
            uint16(100)
        );

    }

    function mintTokensForLP() external onlyBuyAndProcess {
        _mint(address(buyAndProcess), INITIAL_LP_MINT);
    }

    /* ================================================================
                                ADMIN FUNCTIONS
       ================================================================ */
    function setFees(uint256 _genesisFee, uint256 _burnFee, uint256 _buildFee, uint256 _titanXBurnFee) external onlyOwner {
        genesisFee = _genesisFee;
        burnFee = _burnFee;
        buildFee = _buildFee;
        titanXBurnFee = _titanXBurnFee;
        require(genesisFee <= 369, "Maximum genesis fee is 3.69%");
        require(buildFee <= 2800, "Maximum build fee is 28%");
        require(titanXBurnFee <= 431, "Maximum TitanX burn fee is 4.31%");
        require(genesisFee + burnFee + buildFee + titanXBurnFee == 10000, "Must equal 100%.");
    }

    function setGenesisWallet(address _newGenesis) external onlyOwner {
        require(_newGenesis != address(0), "Invalid address");
        genesisWallet = _newGenesis;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./interface/IERC20BurnMint.sol";
import {IBridge} from "./interface/IBridge.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import {IBotGasOracle} from "./interface/IBotGasOracle.sol";
import {IBotBridge} from "./interface/IBotBridge.sol";
import {IVote} from "./interface/IVote.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract BotBridge is AccessControl, IBotBridge, Initializable {
    using Address for address;
    using SafeERC20 for IERC20;

    error ErrAssetsType(uint8 assetsType);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 public constant FINANCE_ROLE = keccak256("FINANCE_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    uint8 public constant CROSS_CHAIN_EXT_BOT_GAS = 1;

    IBridge public Bridge; // bridge 合约
    uint256 public localNonce; // 跨链nonce
    address private feeAddress;
    address public serverAddress;
    uint256 private withdrawNonce; // 提款nonce
    mapping(uint256 => Withdrawal) private withdrawals;
    address private superAdminAddress;
    mapping(address => bool) public blacklist; // 用户地址 => 是否在黑名单
    mapping(uint256 => DepositRecord) public depositRecords; // user => (depositNonce=> Deposit Record)
    /// @notice public mapping 自动生成 getter `refundDatas(uint256)`，返回字段顺序见 IBotBridge.RefundData，与 relayernode refundDatasABI 一致
    mapping(uint256 => RefundData) public refundDatas; // nonce=>RefundData
    /// @dev BCR-03: 源链记录「目标链已执行」，供 adminRefund 与 markExecutionConfirmed 互斥
    mapping(uint256 => bool) public executionConfirmed;
    /// @notice 本链 Vote；非零时 execute 复核 Vote.sourceRefunded（与 RELAYER markSourceRefunded 对齐）
    address public voteRef;
    BotGasConfig private botGasConfig;
    bool private botGasEnabled;


    event Refunded(uint256 indexed localNonce, address indexed sender, uint256 amount, uint256 fee, uint256 originAmount);
    event ExecutionConfirmed(uint256 indexed localNonce, address indexed confirmer);
    /// @dev BCR-17: 关键环境地址变更事件
    event EnvUpdated(address indexed feeAddress, address indexed serverAddress, address indexed bridgeAddress);
    /// @dev BCR-03/BCR-17: 记录用于执行前复核 sourceRefunded 的 Vote 地址
    event VoteRefUpdated(address indexed voteRef);
    /// @dev BCR-17: BOT Gas 配置变更（含决定资金拆分的 oracle 地址），供链下监控/事后审计
    event BotGasConfigUpdated(
        uint256 destinationChainId,
        bytes32 resourceId,
        uint256 amount,
        address oracle,
        address baseToken,
        address quoteToken,
        uint32 twapWindow,
        bool enabled
    );
    error MissingRefundOperatorRole();

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev BCR-10: 防止实现合约被外部初始化
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
        @notice 设置
        @param bridgeAddress_ bridge合约地址
        @param serverAddress_ 服务端价格签名地址
        @param feeAddress_ 跨链费接受地址
     */
    function adminSetEnv(
        address feeAddress_,
        address serverAddress_,
        address bridgeAddress_
    ) external onlyRole(ADMIN_ROLE) {
        require(feeAddress_ != address(0), "feeAddress_ error");
        // BCR-14: 补齐关键地址非零校验
        require(serverAddress_ != address(0), "serverAddress_ error");
        require(bridgeAddress_ != address(0), "bridgeAddress_ error");
        feeAddress = feeAddress_;
        serverAddress = serverAddress_;
        Bridge = IBridge(bridgeAddress_);
        emit EnvUpdated(feeAddress_, serverAddress_, bridgeAddress_);
    }

    /// @notice 绑定本链 Vote；部署后应设为当前链 Vote 代理地址以启用 execute 侧 BCR-03 校验
    function adminSetVoteRef(address vote_) external onlyRole(ADMIN_ROLE) {
        voteRef = vote_;
        emit VoteRefUpdated(vote_);
    }

    /**
        @notice 添加用户黑名单
        @param user 用户地址
     */
    function adminAddBlacklist(address user) external onlyRole(ADMIN_ROLE) {
        blacklist[user] = true;
        emit AddBlacklist(user);
    }

    /**
        @notice 移除用户黑名单
        @param user 用户地址
     */
    function adminRemoveBlacklist(address user) external onlyRole(ADMIN_ROLE) {
        blacklist[user] = false;
        emit RemoveBlacklist(user);
    }

    /**
        @notice 发起跨链
        @param destinationChainId 目标链ID
        @param resourceId 跨链桥设置的resourceId
        @param recipient 目标链资产接受者地址
        @param amount 跨链金额
     */
    function deposit(
        uint256 destinationChainId,
        bytes32 resourceId,
        address recipient,
        uint256 amount
    ) external payable {
        _deposit(destinationChainId, resourceId, recipient, amount, 0, 0);
    }

    function depositWithBotGas(
        uint256 destinationChainId,
        bytes32 resourceId,
        address recipient,
        uint256 amount
    ) external payable {
        uint256 botGasAmountSnapshot = botGasConfig.amount;
        _deposit(
            destinationChainId,
            resourceId,
            recipient,
            amount,
            CROSS_CHAIN_EXT_BOT_GAS,
            botGasAmountSnapshot
        );
    }

    function adminSetBotGasConfig(
        BotGasConfig calldata cfg,
        bool enabled
    ) external onlyRole(ADMIN_ROLE) {
        require(
            cfg.destinationChainId != 0 && cfg.resourceId != bytes32(0) && cfg.amount != 0,
            "invalid bot gas config"
        );
        // 仅当本实例是「BOT Gas 目标链」时，execute 才会询价拆主币，故此时强制询价字段齐备；
        // 源链实例不强制（oracle/baseToken/quoteToken/twapWindow 在源链不被使用）。
        if (block.chainid == cfg.destinationChainId) {
            require(cfg.oracle != address(0), "oracle required on dest");
            require(cfg.baseToken != address(0) && cfg.quoteToken != address(0), "tokens required on dest");
            require(cfg.twapWindow > 0, "twap window required on dest");
        }
        botGasConfig = cfg;
        botGasEnabled = enabled;
        emit BotGasConfigUpdated(
            cfg.destinationChainId,
            cfg.resourceId,
            cfg.amount,
            cfg.oracle,
            cfg.baseToken,
            cfg.quoteToken,
            cfg.twapWindow,
            enabled
        );
    }

    function getBotGasConfig()
        external
        view
        returns (BotGasConfig memory cfg, bool enabled)
    {
        return (botGasConfig, botGasEnabled);
    }

    function _deposit(
        uint256 destinationChainId,
        bytes32 resourceId,
        address recipient,
        uint256 amount,
        uint8 crossChainExtType,
        uint256 botGasAmountSnapshot
    ) internal {
        DepositData memory depositData;
        depositData.amount = amount;
        depositData.recipient = recipient;
        depositData.resourceId = resourceId;
        depositData.destinationChainId = destinationChainId;
        depositData.chainId = block.chainid;
        // 检查黑名单
        require(
            !blacklist[msg.sender] && !blacklist[recipient],
            "you or recipient is blocked"
        );
        // 检测resource ID是否设置
        (
        uint8 assetsType,
        address tokenAddress, // bool pause,
        bool pause,
        uint256 decimal,
        bool burnable, // bool mintable

        ) = Bridge.getTokenInfoByResourceId(depositData.resourceId);
        require(!pause, "token id paused");
        // decimal 为 Token 小数位对应的 scale 因子（如 1e6、1e18），非指数，不做 10**dec 转换
        require(decimal > 0, "invalid decimal scale");
        _requireDepositAmountUsdBounds(amount, decimal);
        depositData.fee = Bridge.chainAndTokenFee(depositData.destinationChainId, depositData.resourceId);
        //        require(depositData.fee >= 0, "fee error");
        depositData.burnable = burnable;
        depositData.assetsType = assetsType;
        depositData.tokenAddress = tokenAddress;
        require(depositData.assetsType > 0, "resourceId not exist");
        // 检测目标链ID
        require(
            depositData.destinationChainId != depositData.chainId,
            "destinationChainId error"
        );
        // BCR-08: BotBridge 侧按 sourceChainId -> destinationChainId 提前拦截未启用路线
        require(Bridge.isSupportedRoute(depositData.chainId, depositData.destinationChainId), "route not supported");
        if (crossChainExtType == CROSS_CHAIN_EXT_BOT_GAS) {
            _requireBotGasDeposit(
                destinationChainId,
                resourceId,
                botGasAmountSnapshot
            );
        }
        // BCR-11: fee 未配置时 mapping 默认 0，必须禁止免费绕过 ,手续费就是要=0，这个是需求
       // require(depositData.fee > 0, "fee not configured");
        // 实际到账额度
        (uint256 finalFeeAmount, uint256 receiveAmount) = _computeFeeAmounts(
            depositData.amount,
            depositData.fee,
            decimal
        );
        depositData.feeAmount = finalFeeAmount;
        depositData.receiveAmount = receiveAmount;

        _collectDepositFunds(
            assetsType,
            tokenAddress,
            burnable,
            depositData.amount,
            receiveAmount,
            finalFeeAmount
        );

        _recordAndBridgeDeposit(
            depositData,
            assetsType,
            tokenAddress,
            decimal,
            crossChainExtType,
            botGasAmountSnapshot
        );
    }

    function _requireBotGasDeposit(
        uint256 destinationChainId,
        bytes32 resourceId,
        uint256 botGasAmountSnapshot
    ) private view {
        require(botGasEnabled, "bot gas disabled");
        require(
            destinationChainId == botGasConfig.destinationChainId &&
                resourceId == botGasConfig.resourceId &&
                botGasAmountSnapshot > 0,
            "invalid bot gas deposit"
        );
    }

    function _computeFeeAmounts(
        uint256 amount,
        uint256 feeBps,
        uint256 scale
    ) internal view returns (uint256 finalFeeAmount, uint256 receiveAmount) {
        uint256 feeAmount = (amount * feeBps) / 10000;
        if (feeAmount > 0) {
            uint256 minRequired = Bridge.minFee() * scale;
            finalFeeAmount = feeAmount > minRequired ? feeAmount : minRequired;
        }
        require(amount > finalFeeAmount, "amount is too small");
        receiveAmount = amount - finalFeeAmount;
    }

    function _collectDepositFunds(
        uint8 assetsType,
        address tokenAddress,
        bool burnable,
        uint256 amount,
        uint256 receiveAmount,
        uint256 finalFeeAmount
    ) internal {
        if (assetsType == uint8(AssetsType.Coin)) {
            require(msg.value == amount, "incorrect value supplied .");
            Address.sendValue(payable(feeAddress), finalFeeAmount);
            return;
        }
        if (assetsType == uint8(AssetsType.Erc20)) {
            IERC20 erc20 = IERC20(tokenAddress);
            if (burnable) {
                IERC20BurnMint(tokenAddress).burnFrom(msg.sender, receiveAmount);
            } else {
                erc20.safeTransferFrom(msg.sender, address(this), receiveAmount);
            }
            erc20.safeTransferFrom(msg.sender, feeAddress, finalFeeAmount);
            return;
        }
        revert ErrAssetsType(assetsType);
    }

    function _recordAndBridgeDeposit(
        DepositData memory depositData,
        uint8 assetsType,
        address tokenAddress,
        uint256 decimal,
        uint8 crossChainExtType,
        uint256 botGasAmountSnapshot
    ) internal {
        localNonce++;

        depositRecords[localNonce] = DepositRecord(
            tokenAddress,
            msg.sender,
            depositData.recipient,
            depositData.amount,
            depositData.feeAmount,
            depositData.destinationChainId
        );

        refundDatas[localNonce] = RefundData(
            msg.sender,
            depositData.receiveAmount,
            !depositData.burnable,
            false,
            assetsType,
            tokenAddress,
            depositData.fee,
            depositData.amount
        );

        bytes memory data;
        if (crossChainExtType == CROSS_CHAIN_EXT_BOT_GAS) {
            data = abi.encode(
                depositData.resourceId,
                depositData.chainId,
                msg.sender,
                depositData.recipient,
                depositData.amount,
                depositData.receiveAmount,
                decimal,
                localNonce,
                crossChainExtType,
                botGasAmountSnapshot
            );
        } else {
            data = abi.encode(
                depositData.resourceId,
                depositData.chainId,
                msg.sender,
                depositData.recipient,
                depositData.amount,
                depositData.receiveAmount,
                decimal,
                localNonce
            );
        }

        Bridge.deposit(depositData.destinationChainId, depositData.resourceId, data);

        emit DepositEvent(
            msg.sender,
            depositData.recipient,
            depositData.amount,
            depositData.receiveAmount,
            tokenAddress,
            localNonce,
            depositData.destinationChainId
        );
    }

    function _requireVoteSourceNotRefundedByHash(
        uint256 originChainId,
        uint256 originNonce,
        bytes32 dataHash
    ) private view {
        address v = voteRef;
        if (v == address(0)) {
            return;
        }
        require(originNonce < (1 << 224), "origin nonce too big");
        uint256 nonceAndID = (originNonce << 32) |
            (originChainId & 0xFFFFFFFF);
        require(!IVote(v).sourceRefunded(nonceAndID, dataHash), "source already refunded");
    }

    /**
        @notice 目标链执行到帐操作（唯一入口）。普通跨链 crossChainExtType=0；
                到账附带 BOT Gas crossChainExtType=1。由 Vote.executeProposal 调用。
     */
    function execute(
        bytes32 resourceId,
        uint256 originChainId,
        address caller,
        address recipient,
        uint256 amount,
        uint256 receiveAmount,
        uint256 decimalOrigin,
        uint256 originNonce,
        bytes32 dataHash,
        uint8 crossChainExtType,
        uint256 botGasAmountSnapshot
    ) external onlyRole(BRIDGE_ROLE) {
        _requireVoteSourceNotRefundedByHash(originChainId, originNonce, dataHash);
        require(crossChainExtType == 0 || crossChainExtType == CROSS_CHAIN_EXT_BOT_GAS, "invalid ext type");

        ExecuteData memory executeData;
        executeData.resourceId = resourceId;
        executeData.originChainId = originChainId;
        executeData.caller = caller;
        executeData.recipient = recipient;
        executeData.amount = amount;
        executeData.receiveAmount = receiveAmount;
        executeData.decimalOrigin = decimalOrigin;
        executeData.originNonce = originNonce;

        (
            uint8 assetsType,
            address tokenAddress, // bool pause
            ,
            uint256 decimalLocal, // uint256 fee // bool burnable
            ,
            bool mintable // mintable
        ) = Bridge.getTokenInfoByResourceId(executeData.resourceId);
        // 源/目的 Token 的 scale 因子（如 1e6、1e18）
        require(executeData.decimalOrigin > 0 && decimalLocal > 0, "invalid decimal scale");
        if (executeData.decimalOrigin > decimalLocal) {
            executeData.receiveAmount =
                executeData.receiveAmount /
                (executeData.decimalOrigin / decimalLocal);
        } else if (executeData.decimalOrigin < decimalLocal) {
            executeData.receiveAmount =
                executeData.receiveAmount *
                (decimalLocal / executeData.decimalOrigin);
        }

        if (crossChainExtType == CROSS_CHAIN_EXT_BOT_GAS) {
            // 仅当「本链 == 配置的 BOT Gas 目标链(BOT Chain)」时才拆主币；
            // 否则（如目标链是 BSC/ETH 等非 botchain）即使带了 botGasAmount 也不兑换主币，
            // 默认回退到普通到账（只发 USDT），不 revert。
            if (block.chainid == botGasConfig.destinationChainId) {
                _executeWithBotGas(executeData, assetsType, tokenAddress, mintable, dataHash, botGasAmountSnapshot);
            } else {
                _executeNormal(executeData, assetsType, tokenAddress, mintable, dataHash);
            }
        } else {
            require(botGasAmountSnapshot == 0, "unexpected bot gas amount");
            _executeNormal(executeData, assetsType, tokenAddress, mintable, dataHash);
        }
    }

    function _executeNormal(
        ExecuteData memory executeData,
        uint8 assetsType,
        address tokenAddress,
        bool mintable,
        bytes32 dataHash
    ) private {
        if (assetsType == 1) {
            Address.sendValue(
                payable(executeData.recipient),
                executeData.receiveAmount
            );
        } else if (assetsType == 2) {
            if (mintable) {
                IERC20BurnMint erc20 = IERC20BurnMint(tokenAddress);
                erc20.mint(executeData.recipient, executeData.receiveAmount);
            } else {
                IERC20 erc20 = IERC20(tokenAddress);
                erc20.safeTransfer(
                    executeData.recipient,
                    executeData.receiveAmount
                );
            }
        } else {
            revert ErrAssetsType(assetsType);
        }
        emit ExecuteEvent(
            executeData.caller,
            executeData.recipient,
            executeData.receiveAmount,
            tokenAddress,
            executeData.originNonce,
            executeData.originChainId,
            dataHash,
            0,
            0,
            0
        );
    }

    function _executeWithBotGas(
        ExecuteData memory executeData,
        uint8 assetsType,
        address tokenAddress,
        bool mintable,
        bytes32 dataHash,
        uint256 botGasAmountSnapshot
    ) private {
        require(botGasEnabled, "bot gas disabled");
        require(executeData.resourceId == botGasConfig.resourceId, "only bot gas resource");
        require(assetsType == uint8(AssetsType.Erc20), "only erc20 bot gas");
        require(botGasAmountSnapshot > 0, "invalid bot gas amount");
        require(address(this).balance >= botGasAmountSnapshot, "insufficient bot gas reserve");

        // 真实 TWAP 询价：把 botGasAmountSnapshot 数量的 BOT 折算成 USDT 成本。
        // 任何询价异常（池子无流动性 / 观察窗口不足 / 未配置）都会 revert，使整笔 execute 回滚（可重试/退款）。
        BotGasConfig memory cfg = botGasConfig;
        require(cfg.oracle != address(0), "bot gas oracle not set");
        require(cfg.baseToken != address(0) && cfg.quoteToken != address(0), "bot gas token not set");
        require(cfg.twapWindow > 0, "invalid twap window");
        require(botGasAmountSnapshot <= type(uint128).max, "bot gas amount overflow");
        uint256 botCostUsdt = IBotGasOracle(cfg.oracle).quoteWithWindow(
            cfg.baseToken,
            cfg.quoteToken,
            uint128(botGasAmountSnapshot),
            cfg.twapWindow
        );
        require(botCostUsdt > 0, "invalid bot gas cost");
        require(executeData.receiveAmount > botCostUsdt, "receive amount too small");
        uint256 usdtAmount = executeData.receiveAmount - botCostUsdt;

        if (mintable) {
            IERC20BurnMint(tokenAddress).mint(executeData.recipient, usdtAmount);
        } else {
            IERC20(tokenAddress).safeTransfer(executeData.recipient, usdtAmount);
        }
        Address.sendValue(payable(executeData.recipient), botGasAmountSnapshot);

        emit ExecuteEvent(
            executeData.caller,
            executeData.recipient,
            usdtAmount,
            tokenAddress,
            executeData.originNonce,
            executeData.originChainId,
            dataHash,
            CROSS_CHAIN_EXT_BOT_GAS,
            botGasAmountSnapshot,
            botCostUsdt
        );
    }

    /// @notice BCR-03: 由 relayer 在源链调用，在目标链 execute 成功后回写，阻止源链 adminRefund
    function markExecutionConfirmed(uint256 refundNonce) external onlyRole(RELAYER_ROLE) {
        require(refundDatas[refundNonce].sender != address(0), "invalid record");
        executionConfirmed[refundNonce] = true;
        emit ExecutionConfirmed(refundNonce, msg.sender);
    }

    /**
        @notice 提取跨链桥资产，创建
        @param _tokenAddress 币种地址，coin为0地址
        @param _to 资产接受地址
        @param _amount 提取数量
     */
    function withdrawalCreate(
        address _tokenAddress,
        address payable _to,
        uint256 _amount
    ) public onlyRole(FINANCE_ROLE) returns (uint256 id) {
        id = ++withdrawNonce;
        Withdrawal storage w = withdrawals[id];
        w.withdrawalNonce = id;
        w.tokenAddress = _tokenAddress;
        w.to = _to;
        w.amount = _amount;
        w.executed = false;
        w.approved[msg.sender] = true;
        w.approvals = 1;

        emit CreatedWithdrawal(id, msg.sender, _tokenAddress, _to, _amount);
        emit ApprovedWithdrawal(w.withdrawalNonce, msg.sender);
    }

    /**
        @notice 提取跨链桥资产,授权，授权到一定数量(>=2)就通过
     */
    function withdrawalApprove(
        uint256 withdrawalId
    ) public onlyRole(FINANCE_ROLE) {
        Withdrawal storage w = withdrawals[withdrawalId];
        require(withdrawalId <= withdrawNonce, "invalid withdrawalId");
        require(!w.executed, "already executed");
        require(!w.approved[msg.sender], "already approved");
        w.approved[msg.sender] = true;
        w.approvals += 1;
        if (w.approvals >= 2) {
            w.executed = true;
            if (w.tokenAddress == address(0)) {
                Address.sendValue(w.to, w.amount);
            } else {
                IERC20 erc20 = IERC20(w.tokenAddress);
                erc20.safeTransfer(w.to, w.amount);
            }
            emit ExecutedWithdrawal(w.withdrawalNonce, msg.sender);
        }
        emit ApprovedWithdrawal(w.withdrawalNonce, msg.sender);
    }

    receive() external payable {
        emit ReceivedEth(msg.sender, msg.value);
    }


    /// @notice
    function adminRefund(uint256 refundNonce) external {
        if (
             !hasRole(RELAYER_ROLE, msg.sender) &&
             !hasRole(ADMIN_ROLE, msg.sender)
        ) {
            revert MissingRefundOperatorRole();
        }
        RefundData memory refundData = refundDatas[refundNonce];
        require(!refundData.refunded, "already refunded");
        // BCR-03: 已确认目标链执行成功的单据禁止再退款，防止双重兑付
        require(!executionConfirmed[refundNonce], "already executed on destination");
        uint256 amount = refundData.depositReceiveAmount;
        require(amount > 0, "zero amount");
        require(refundData.sender != address(0), "invalid record");
        refundDatas[refundNonce].refunded = true;
        if (refundData.assetsType == uint8(AssetsType.Coin)) {
            Address.sendValue(payable(refundData.sender), amount);
        } else {
            // BCR-05: lock 模式 transfer；burn 模式 mint，避免挪用合约库存退款
            if (refundData.depositIsLock) {
                IERC20(refundData.tokenAddress).safeTransfer(refundData.sender, amount);
            } else {
                IERC20BurnMint(refundData.tokenAddress).mint(refundData.sender, amount);
            }
        }
        emit Refunded(refundNonce, refundData.sender, amount, refundData.fee, refundData.originAmount);
    }

    /**
     * @notice 查询指定 resourceId 对应 token 是否已暂停跨链（供前端展示）
     * @param resourceId 跨链资源 ID
     * @return 是否暂停：true=已暂停，false=未暂停
     */
    /**升级修改*/
    function getTokenPauseByResourceId(bytes32 resourceId) public view returns (bool) {
        (, , bool pause, , ,) = Bridge.getTokenInfoByResourceId(resourceId);
        return pause;
    }

    /**
     * @notice 查询全桥是否暂停（供前端展示）
     * @return 是否暂停：true=已暂停，false=未暂停
     */
    /**升级修改*/
    function getBridgePause() public view returns (bool) {
        return Bridge.getPause();
    }

    /**
     * @notice Bridge 全局单笔跨链最小 USD 参照值（与 deposit 中 min 校验同源）
     * @return 与 IBridge.minAmountUsd() 相同
     */
    function getMinAmountUsd() public view returns (uint256) {
        return Bridge.minAmountUsd();
    }

    /**
     * @notice Bridge 全局单笔跨链最大 USD 参照值（与 deposit 中 max 校验同源）
     * @return 与 IBridge.maxAmountUsd() 相同
     */
    function getMaxAmountUsd() public view returns (uint256) {
        return Bridge.maxAmountUsd();
    }

    function getMinFee() public view returns (uint256) {
        return Bridge.minFee();
    }

    /// @dev 单独函数避免 deposit 栈过深（string.concat + 多局部变量）
    function _requireDepositAmountUsdBounds(uint256 amount, uint256 scale) private view {
        uint256 minUsd = Bridge.minAmountUsd();
        uint256 maxUsd = Bridge.maxAmountUsd();
        uint256 minScaled = minUsd * scale;
        uint256 maxScaled = maxUsd * scale;
        require(
            amount >= minScaled,
            string.concat(
                "The value of cross-chain assets must be greater than $",
                Strings.toString(minUsd),
                "!"
            )
        );
        if(block.chainid == 677 || block.chainid == 968) {
            require(
                amount <= maxScaled,
                string.concat(
                    "The value of cross-chain assets must be less than $",
                    Strings.toString(maxUsd),
                    "!"
                )
            );
        }
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

interface IBotBridge {
    enum AssetsType {
        None,
        Coin,
        Erc20,
        Erc721,
        Erc1155
    }

    event AddBlacklist(address indexed user);
    event RemoveBlacklist(address indexed user);
    event ReceivedEth(address sender, uint256 amount);
    event CreatedWithdrawal(
        uint256 withdrawNonce,
        address caller,
        address indexed tokenAddress,
        address indexed to,
        uint256 indexed amount
    );
    event ApprovedWithdrawal(uint256 withdrawNonce, address caller);
    event ExecutedWithdrawal(uint256 withdrawNonce, address caller);

    event DepositEvent(
        address indexed depositer,
        address indexed recipient,
        uint256 indexed amount,
        uint256 receiveAmount,
        address tokenAddress,
        uint256 depositNonce,
        uint256 destinationChainId
    );

    event SetTokenEvent(
        bytes32 indexed resourceID,
        AssetsType assetsType,
        address tokenAddress,
        bool burnable,
        bool mintable,
        bool pause // 该token是否暂停跨链
    );

    event ExecuteEvent(
        address indexed depositer,
        address indexed recipient,
        uint256 indexed receiveamount,
        address tokenAddress,
        uint256 originDepositNonce,
        uint256 originChainId,
        bytes32 dataHash,
        uint8 crossChainExtType,
        uint256 botAmount,
        uint256 botCostUsdt
    );

    struct DepositRecord {
        address tokenAddress;
        address sender;
        address recipient;
        uint256 amount;
        uint256 fee;
        uint256 destinationChainId;
    }

    struct DepositData {
        uint256 chainId;
        uint256 destinationChainId;
        bytes32 resourceId;
        address recipient;
        uint256 amount;
        uint256 value; // msg.value
        address sender; // msg.sender
        address tokenAddress;
        //        uint256 price;
        uint256 fee; // 跨链需要折合U的数量
        uint256 feeAmount;
        uint256 receiveAmount;
        bool burnable;
        uint8 assetsType;
    }

    struct ExecuteData {
        uint256 dataLength;
        bytes32 resourceId;
        uint256 originChainId;
        address caller;
        address recipient;
        uint256 amount;
        uint256 receiveAmount;
        uint256 decimalOrigin;
        uint256 originNonce;
    }

    struct Withdrawal {
        uint256 withdrawalNonce;
        address payable to;
        address tokenAddress;
        uint256 amount;
        bool executed;
        mapping(address => bool) approved;
        uint8 approvals; // number of approvals
    }

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
    ) external;

    function depositWithBotGas(
        uint256 destinationChainId,
        bytes32 resourceId,
        address recipient,
        uint256 amount
    ) external payable;

    /// @notice BOT Gas 配置（不含开关）；字段顺序即 storage slot 顺序，上主网后不可重排。
    /// @dev 后 4 个字段（oracle/baseToken/quoteToken/twapWindow）仅目标链 execute 询价用，源链可留空。
    struct BotGasConfig {
        uint256 destinationChainId; // 源链：目标必须是 BOT Chain（968/677）
        bytes32 resourceId;         // 源链+目标链：USDT resourceId
        uint256 amount;             // 源链：发放 BOT 数量，初始 0.1 BOT
        address oracle;             // 目标链：TWAP 报价合约（源链可为 0）
        address baseToken;          // 目标链：TWAP base = BOT 包装地址（源链可为 0）
        address quoteToken;         // 目标链：TWAP quote = USDT 地址（源链可为 0）
        uint32  twapWindow;         // 目标链：TWAP 窗口秒数，默认 1800（源链可为 0）
    }

    function adminSetBotGasConfig(
        BotGasConfig calldata cfg,
        bool enabled
    ) external;

    function getBotGasConfig() external view returns (
        BotGasConfig memory cfg,
        bool enabled
    );

    /// @dev 字段顺序与 relayernode `bridge/chains/ethereum/refund.go` 中 `refundDatasABI` 必须一致
    struct RefundData {
        address sender;
        uint256 depositReceiveAmount;
        bool depositIsLock;
        bool refunded;
        uint8 assetsType;
        address tokenAddress;
        uint256 fee;
        uint256 originAmount;
    }

    /// @notice 查询某笔 deposit（localNonce）的退款侧记录；由实现合约 `mapping(uint256 => RefundData) public refundDatas` 生成，ABI 与链下 `refundDatasABI` 一致
    function refundDatas(uint256 localNonce) external view returns (
        address sender,
        uint256 depositReceiveAmount,
        bool depositIsLock,
        bool refunded,
        uint8 assetsType,
        address tokenAddress,
        uint256 fee,
        uint256 originAmount
    );
}

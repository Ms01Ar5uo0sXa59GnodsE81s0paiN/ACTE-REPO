// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IBridge {
    enum AssetsType {
        None,
        Coin,
        Erc20,
        Erc721,
        Erc1155
    }

    event Deposit(
        uint256 indexed destinationChainId,
        bytes32 indexed resourceID,
        uint256 indexed depositNonce,
        bytes data
    );

    event SetResource(
        bytes32 indexed resourceID,
        address tokenAddress,
        uint256 decimal,
        bool pause, // 该resourceID是否被暂停交易
        bool burnable, // true burn;false lock
        bool mintable
    );

    // 跨链币种信息
    struct TokenInfo {
        AssetsType assetsType; // 跨链币种
        address tokenAddress; // 币种地址。coin的话，值为0地址
        bool pause; // 该token是否暂停跨链
        uint256 decimal; // 该token的精度
        bool burnable; // true burn;false lock
        bool mintable; // true mint;false release
    }

    struct DepositRecord {
        uint256 destinationChainId;
        address sender; // 某个业务合约的地址，可以有多个业务合约
        bytes32 resourceID;
        uint256 ctime;
        bytes data;
    }

    struct ChainTokenFee {
        uint256 destinationChainId;
        bytes32 resourceId;
        uint256 fee;
    }

    /// @dev BCR-08/BCR-17: sourceChainId 的目标链列表整体更新事件
    event SupportedRoutesUpdated(
        uint256 indexed sourceChainId,
        uint256[] destinationChainIds
    );

    function deposit(
        uint256 destinationChainId,
        bytes32 resourceID,
        bytes calldata data
    ) external;

    function fee(uint256 destinationChainId) external view returns (uint256);

    function getTokenInfoByResourceId(
        bytes32 resourceId
    ) external view returns (uint8, address, bool, uint256, bool, bool);

    /// @return 全桥是否暂停：true=已暂停，false=未暂停
    function getPause() external view returns (bool);

    function chainAndTokenFee(uint256 destinationChainId, bytes32 resourceId)  external view returns (uint256);

    /// @dev BCR-08: 从 sourceChainId 的目标链列表中查询 destinationChainId 是否已启用
    function isSupportedRoute(uint256 sourceChainId, uint256 destinationChainId) external view returns (bool);

    /// @dev BCR-08: 按 sourceChainId 返回全部已启用目标链
    function getSupportedDestinationChains(uint256 sourceChainId) external view returns (uint256[] memory);

    function minFee() external view returns (uint256);
    function minAmountUsd() external view returns (uint256);
    function maxAmountUsd() external view returns (uint256);
}

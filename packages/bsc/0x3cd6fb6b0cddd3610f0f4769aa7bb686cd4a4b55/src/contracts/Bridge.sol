// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./utils/Pausable.sol";
import {IBridge} from "./interface/IBridge.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Bridge is IBridge, Pausable, AccessControl, Initializable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    mapping(uint256 => uint256) public fee;  /* deprecated */ // destinationChainId => fee 该币的跨链费用,折合U的数量
    mapping(uint256 => uint256) public depositCounts; // destinationChainID => number of deposits
    mapping(bytes32 => TokenInfo) public resourceIdToTokenInfo; //  resourceID => 设置的Token信息
    mapping(uint256 => mapping(uint256 => DepositRecord)) public depositRecords; // depositNonce => (destinationChainId => Deposit Record)
    /**升级修改*/
    mapping(uint256 => mapping(bytes32 => uint256)) public chainAndTokenFee;
    uint256 public minFee;
    uint256 public minAmountUsd;
    uint256 public maxAmountUsd;
    /// @dev BCR-08: sourceChainId => destinationChainId list，供前端/后端按源链查询目标链，并作为唯一路线存储
    mapping(uint256 => uint256[]) private supportedDestinationChains;

    event TradeFeeUpdated(uint256 minFee, uint256 minAmountUsd, uint256 maxAmountUsd);
    event ChainTokenFeeUpdated(uint256 destinationChainId, bytes32 indexed resourceId, uint256 fee);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev BCR-10: 防止实现合约被外部初始化
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // 获取跨链费用
    function adminSetFee(
        uint256[] calldata destinationChainId_,
        uint256[] calldata fee_
    ) public view onlyRole(ADMIN_ROLE) {
        destinationChainId_;
        fee_;
        // BCR-12: 废弃旧 fee 映射入口，防止运维误以为已生效
        revert("deprecated: use adminSetChainAndTokenFee");
    }
    /**升级修改*/
    function adminSetChainAndTokenFee(ChainTokenFee[] calldata fees) public onlyRole(ADMIN_ROLE) {
        require(fees.length > 0, "array is null");
        uint256 len = fees.length;
        for (uint256 i = 0; i < len; i++) {
            ChainTokenFee memory chainTokenFee = fees[i];
            chainAndTokenFee[chainTokenFee.destinationChainId][chainTokenFee.resourceId] = chainTokenFee.fee;
            emit ChainTokenFeeUpdated(chainTokenFee.destinationChainId, chainTokenFee.resourceId, chainTokenFee.fee);
        }
    }

    /// @dev BCR-08/BCR-17: 设置 sourceChainId 对应的完整目标链列表，并记录事件
    function adminSetSupportedRoutes(
        uint256 sourceChainId,
        uint256[] calldata destinationChainIds
    ) public onlyRole(ADMIN_ROLE) {
        require(sourceChainId > 0, "sourceChainId error");
        delete supportedDestinationChains[sourceChainId];
        uint256 len = destinationChainIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 destinationChainId = destinationChainIds[i];
            require(destinationChainId > 0, "destinationChainId error");
            require(destinationChainId != sourceChainId, "destinationChainId error");
            require(!_isSupportedRoute(sourceChainId, destinationChainId), "duplicate destinationChainId");
            supportedDestinationChains[sourceChainId].push(destinationChainId);
        }
        emit SupportedRoutesUpdated(sourceChainId, destinationChainIds);
    }

    /// @dev BCR-08: 从 sourceChainId 的目标链列表中查询 destinationChainId 是否已启用
    function isSupportedRoute(uint256 sourceChainId, uint256 destinationChainId) external view returns (bool) {
        return _isSupportedRoute(sourceChainId, destinationChainId);
    }

    /// @dev BCR-08: 返回某条源链已启用的全部目标链
    function getSupportedDestinationChains(uint256 sourceChainId) external view returns (uint256[] memory) {
        return supportedDestinationChains[sourceChainId];
    }

    function _isSupportedRoute(uint256 sourceChainId, uint256 destinationChainId) private view returns (bool) {
        uint256[] storage destinations = supportedDestinationChains[sourceChainId];
        uint256 len = destinations.length;
        for (uint256 i = 0; i < len; i++) {
            if (destinations[i] == destinationChainId) {
                return true;
            }
        }
        return false;
    }

    /**升级修改*/
    function adminSetTradeFee(uint256 _minFee, uint256 _minAmountUsd, uint256 _maxAmountUsd) public onlyRole(ADMIN_ROLE) {
        // BCR-15: 防止配置互相矛盾导致
        require(_maxAmountUsd > 0, "maxAmountUsd is zero");
        require(_minAmountUsd < _maxAmountUsd, "invalid amount bounds");
        require(_minFee <= 10_000, "minFee too high");
        minFee = _minFee;
        minAmountUsd = _minAmountUsd;
        maxAmountUsd = _maxAmountUsd;
        emit TradeFeeUpdated(_minFee, _minAmountUsd, _maxAmountUsd);
    }

    /**
        @notice 暂停跨链、提案的的创建与投票和目标链执行操作
     */
    function adminPauseTransfers() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
        @notice 开启跨链、提案的的创建与投票和目标链执行操作
     */
    function adminUnpauseTransfers() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
        @notice resource设置
        @param resourceID 跨链的resourceID
        @param assetsType 该币的类型
        @param tokenAddress 对应的token合约地址，coin为0地址
        @param decimal 该币数量级缩放因子（如 1e6、1e18），与 minAmountUsd*decimal 同量纲
        @param pause 该币种是否在黑名单中/是否允许跨链。币种黑名单/禁止该币种跨链
        @param burnable 该币是否burn
        @param mintable 该币是否mint
     */
    function adminSetResource(
        bytes32 resourceID,
        AssetsType assetsType,
        address tokenAddress,
        uint256 decimal,
        bool pause,
        bool burnable,
        bool mintable
    ) external onlyRole(ADMIN_ROLE) {
        require(uint8(assetsType) > 0, "invalid asset type");
        // decimal 存 scale（如 10**6），非指数位；仅要求非零且避免明显异常极大值造成溢出观感
        require(decimal > 0 && decimal <= 10 ** 40, "invalid decimal scale");
        // BCR-14: 资源配置时补齐资产地址语义校验
        if (assetsType == AssetsType.Coin) {
            require(tokenAddress == address(0), "coin tokenAddress must be zero");
        } else {
            require(tokenAddress != address(0), "tokenAddress is zero");
        }
        resourceIdToTokenInfo[resourceID] = TokenInfo(
            assetsType,
            tokenAddress,
            pause,
            decimal,
            burnable,
            mintable
        );

        emit SetResource(
            resourceID,
            tokenAddress,
            decimal,
            pause,
            burnable,
            mintable
        );
    }

    /**
        @notice 资产跨链
        @param destinationChainId 目标链ID
        @param resourceId 跨链的resourceID
        @param data   跨链data
     */
    function deposit(
        uint256 destinationChainId,
        bytes32 resourceId,
        bytes calldata data
    ) external whenNotPaused onlyRole(BRIDGE_ROLE) {
        // 检测resource ID是否设置
        TokenInfo memory tokenInfo = resourceIdToTokenInfo[resourceId];
        require(uint8(tokenInfo.assetsType) > 0, "resourceId not exist");
        // BCR-08: 防止用户把资产锁定/销毁到未部署或未支持的目标链路线
        require(_isSupportedRoute(block.chainid, destinationChainId), "route not supported");
        // 检测resourceId/token是否被暂停跨链
        require(!tokenInfo.pause, "service suspended");

        uint256 depositNonce = ++depositCounts[destinationChainId];

        depositRecords[destinationChainId][depositNonce] = DepositRecord(
            destinationChainId,
            msg.sender,
            resourceId,
            block.timestamp,
            data
        );

        emit Deposit(destinationChainId, resourceId, depositNonce, data);
    }

    // 由resourceId获取token信息
    function getTokenInfoByResourceId(
        bytes32 resourceId
    ) public view returns (uint8, address, bool, uint256, bool, bool) {
        TokenInfo memory token = resourceIdToTokenInfo[resourceId];
        return (
            uint8(token.assetsType),
            token.tokenAddress,
            token.pause,
            token.decimal,
            token.burnable,
            token.mintable
        );
    }
    /**升级修改*/
    function getPause() public view returns (bool){
        return paused();
    }

}

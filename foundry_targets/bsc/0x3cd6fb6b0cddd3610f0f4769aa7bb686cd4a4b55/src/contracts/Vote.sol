// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./interface/IVote.sol";
import "./interface/IBridge.sol";
import "./interface/IBotBridge.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Vote is IVote, AccessControl, Initializable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    error ErrAssetsType(uint8 assetsType);

    IBridge public Bridge; // bridge 合约
    IBotBridge public BotBridge; // BotBridge 合约
    uint256 public expiry; // 开始投票后经过 expiry 的块数量后投票过期
    uint256 public totalProposal; // 提案数量
    uint256 public relayerThreshold; // 提案可以通过的最少投票数量
    address private superAdminAddress;
    mapping(uint256 => mapping(bytes32 => Proposal)) public proposals; // destinationChainID + depositNonce => dataHash => Proposal
    mapping(uint256 => mapping(bytes32 => mapping(address => bool)))
        public hasVotedOnProposal; // destinationChainID + depositNonce => dataHash => relayerAddress => bool
    /// @dev BCR-03：源链已退款（或即将退款）时置位，阻塞目标链执行
    mapping(uint256 => mapping(bytes32 => bool)) public sourceRefunded;
    /// @dev BCR-17: Vote 环境参数变更事件
    event EnvUpdated(address indexed bridgeAddress, address indexed botBridgeAddress, uint256 expiry, uint256 relayerThreshold);

    struct LegacyExecutePayload {
        bytes32 resourceId;
        uint256 originChainId;
        address caller;
        address recipient;
        uint256 amount;
        uint256 receiveAmount;
        uint256 decimalOrigin;
        uint256 originNonce;
    }

    struct ExtendedExecutePayload {
        bytes32 resourceId;
        uint256 originChainId;
        address caller;
        address recipient;
        uint256 amount;
        uint256 receiveAmount;
        uint256 decimalOrigin;
        uint256 originNonce;
        uint8 crossChainExtType;
        uint256 botGasAmountSnapshot;
    }

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
        @param bridgeAddress_ Bridge合约地址
        @param expiry_ 提案过期的块高差
        @param relayerThreshold_ 提案通过的投票数量
     */
    function adminSetEnv(
        address bridgeAddress_,
        address botBridgeAddress_,
        uint256 expiry_,
        uint256 relayerThreshold_
    ) external onlyRole(ADMIN_ROLE) {
        // BCR-14: 关键合约地址禁止配置为零地址
        require(bridgeAddress_ != address(0), "bridgeAddress_ error");
        require(botBridgeAddress_ != address(0), "botBridgeAddress_ error");
        expiry = expiry_;
        Bridge = IBridge(bridgeAddress_);
        BotBridge = IBotBridge(botBridgeAddress_);
        relayerThreshold = relayerThreshold_;
        emit EnvUpdated(bridgeAddress_, botBridgeAddress_, expiry_, relayerThreshold_);
    }

    /**
        @notice 设置投票可通过时的最小投票数量
        @param newThreshold 投票可通过时的最小投票数量
     */
    function adminChangeRelayerThreshold(
        uint256 newThreshold
    ) external onlyRole(ADMIN_ROLE) {
        relayerThreshold = newThreshold;
        emit RelayerThresholdChanged(newThreshold);
    }

    /**
        @notice 添加relayer账户
        @notice Only callable by an address that currently has the admin role.
        @param relayerAddress Address of relayer to be added.
        @notice Emits {RelayerAdded} event.
     */
    function adminAddRelayer(
        address relayerAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(
            !hasRole(RELAYER_ROLE, relayerAddress),
            "addr already has relayer role!"
        );
        grantRole(RELAYER_ROLE, relayerAddress);
        emit RelayerAdded(relayerAddress);
    }

    /**
        @notice 删除relayer账户
        @notice Only callable by an address that currently has the admin role.
        @param relayerAddress Address of relayer to be removed.
        @notice Emits {RelayerRemoved} event.
     */
    function adminRemoveRelayer(
        address relayerAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(
            hasRole(RELAYER_ROLE, relayerAddress),
            "addr doesn't have relayer role!"
        );
        revokeRole(RELAYER_ROLE, relayerAddress);
        emit RelayerRemoved(relayerAddress);
    }

    /**
        @notice relayer执行投票通过后的到帐操作
        @param originChainId 源链ID
        @param originDepositNonce 源链nonce
        @param resourceId 跨链的resourceID
        @param dataHash dataHash
     */
    function voteProposal(
        uint256 originChainId,
        uint256 originDepositNonce,
        bytes32 resourceId,
        bytes32 dataHash
    ) external onlyRole(RELAYER_ROLE) {
        // BCR-16: 紧急暂停期间禁止继续投票推进提案
        require(!Bridge.getPause(), "bridge paused");
        require(
            originDepositNonce < (1 << 224),
            "origin deposit nonce too big"
        );
        uint256 nonceAndID = (originDepositNonce << 32) |
            (originChainId & 0xFFFFFFFF); // 补0保证唯一性
        require(!sourceRefunded[nonceAndID][dataHash], "source already refunded");
        Proposal storage proposal = proposals[nonceAndID][dataHash];
        require(
            uint8(proposal.status) <= 1,
            "proposal already passed/executed/cancelled"
        );
        require(
            !hasVotedOnProposal[nonceAndID][dataHash][msg.sender],
            "relayer already voted"
        );

        if (uint8(proposal.status) == 0) {
            // 第一次对提案投票
            ++totalProposal;
            proposals[nonceAndID][dataHash] = Proposal(
                resourceId,
                dataHash,
                new address[](1),
                new address[](0),
                ProposalStatus.Active,
                block.number
            );

            proposal.yesVotes[0] = msg.sender; // 索引 0 是创建提案的relayer
            emit ProposalEvent(
                originChainId,
                originDepositNonce,
                ProposalStatus.Active,
                resourceId,
                dataHash
            );
        } else {
            // 非第一次对提案投票
            if (block.number - proposal.proposedBlock > expiry) {
                // 如果块高差达到设定阀值，就取消提案,可以设置1～2天，更短时间可以增加安全性
                proposal.status = ProposalStatus.Cancelled;
                emit ProposalEvent(
                    originChainId,
                    originDepositNonce,
                    ProposalStatus.Cancelled,
                    resourceId,
                    dataHash
                );
            } else {
                require(dataHash == proposal.dataHash, "datahash mismatch");
                proposal.yesVotes.push(msg.sender);
            }
        }
        if (proposal.status != ProposalStatus.Cancelled) {
            // 提案非过期状态
            hasVotedOnProposal[nonceAndID][dataHash][msg.sender] = true;
            emit ProposalVote(
                originChainId,
                originDepositNonce,
                proposal.status,
                resourceId
            );

            // 检测投票后的提案状态
            // 如果投票数量达到设定阀值，或者阀值设置为1，就通过提案
            if (
                relayerThreshold <= 1 ||
                proposal.yesVotes.length >= relayerThreshold
            ) {
                proposal.status = ProposalStatus.Passed;
                emit ProposalEvent(
                    originChainId,
                    originDepositNonce,
                    ProposalStatus.Passed,
                    resourceId,
                    dataHash
                );
            }
        }
    }

    /**
        @notice relayer执行投票通过后的到帐操作
        @param originChainId 源链ID
        @param originDepositNonce 源链nonce
        @param dataHash dataHash
     */
    function cancelProposal(
        uint256 originChainId,
        uint256 originDepositNonce,
        bytes32 dataHash
    ) public onlyRole(RELAYER_ROLE) {
        // BCR-16: 紧急暂停期间禁止 relayer 改变提案状态
        require(!Bridge.getPause(), "bridge paused");
        require(
            originDepositNonce < (1 << 224),
            "origin deposit nonce too big"
        );
        uint256 nonceAndID = (originDepositNonce << 32) |
            (originChainId & 0xFFFFFFFF);
        Proposal storage proposal = proposals[nonceAndID][dataHash];

        require(proposal.proposedBlock > 0, "Proposal inactive");
        // BCR-06: 只能取消过期的 Active 提案，避免 Passed/Executed 提案被永久取消
        require(
            proposal.status == ProposalStatus.Active,
            "Can only cancel active proposals"
        );
        require(
            block.number - proposal.proposedBlock > expiry,
            "Proposal not at expiry threshold"
        );

        proposal.status = ProposalStatus.Cancelled;
        emit ProposalEvent(
            originChainId,
            originDepositNonce,
            ProposalStatus.Cancelled,
            proposal.resourceId,
            proposal.dataHash
        );
    }

    /// @inheritdoc IVote
    function markSourceRefunded(
        uint256 originChainId,
        uint256 originDepositNonce,
        bytes32 dataHash
    ) external onlyRole(RELAYER_ROLE) {
        require(
            originDepositNonce < (1 << 224),
            "origin deposit nonce too big"
        );
        uint256 nonceAndID = (originDepositNonce << 32) |
            (originChainId & 0xFFFFFFFF);
        Proposal storage proposal = proposals[nonceAndID][dataHash];

        sourceRefunded[nonceAndID][dataHash] = true;
        if (proposal.proposedBlock > 0) {
            require(proposal.status != ProposalStatus.Executed, "proposal already executed");
            if (
                proposal.status == ProposalStatus.Active ||
                proposal.status == ProposalStatus.Passed
            ) {
                proposal.status = ProposalStatus.Cancelled;
                emit ProposalEvent(
                    originChainId,
                    originDepositNonce,
                    ProposalStatus.Cancelled,
                    proposal.resourceId,
                    proposal.dataHash
                );
            }
        }
        emit SourceRefundMarked(originChainId, originDepositNonce, dataHash, msg.sender);
    }

    /**
        @notice relayer执行投票通过后的到帐操作
        @param originChainId 源链ID
        @param originDepositNonce 源链nonce
        @param data 跨链data
     */
    function executeProposal(
        uint256 originChainId,
        uint256 originDepositNonce,
        bytes calldata data
    ) external onlyRole(RELAYER_ROLE) {
        // BCR-16: 紧急暂停期间禁止目标链执行放款
        require(!Bridge.getPause(), "bridge paused");
        require(
            originDepositNonce < (1 << 224),
            "origin deposit nonce too big"
        );
        uint256 nonceAndID = (originDepositNonce << 32) |
            (originChainId & 0xFFFFFFFF);
        bytes32 dataHash = keccak256(abi.encodePacked(originChainId, data));
        Proposal storage proposal = proposals[nonceAndID][dataHash];

        require(!sourceRefunded[nonceAndID][dataHash], "source already refunded");
        require(
            proposal.status == ProposalStatus.Passed,
            "the proposal must have passed"
        );
        require(
            block.number - proposal.proposedBlock <= expiry,
            "proposal execution expired"
        );
        require(dataHash == proposal.dataHash, "data doesn't match datahash");

        proposal.status = ProposalStatus.Executed;
        (
            ExecuteData memory executeData,
            uint8 crossChainExtType,
            uint256 botGasAmountSnapshot
        ) = _decodeExecuteData(data);
        BotBridge.execute(
            executeData.resourceId,
            executeData.originChainId,
            executeData.caller,
            executeData.recipient,
            executeData.amount,
            executeData.receiveAmount,
            executeData.decimalOrigin,
            executeData.originNonce,
            dataHash,
            crossChainExtType,
            botGasAmountSnapshot
        );

        emit ProposalEvent(
            originChainId,
            originDepositNonce,
            proposal.status,
            proposal.resourceId,
            proposal.dataHash
        );
    }

    function _decodeExecuteData(bytes calldata data)
        private
        pure
        returns (
            ExecuteData memory executeData,
            uint8 crossChainExtType,
            uint256 botGasAmountSnapshot
        )
    {
        if (data.length == 32 * 8) {
            LegacyExecutePayload memory payload = abi.decode(data, (LegacyExecutePayload));
            executeData = _toExecuteData(payload);
        } else if (data.length == 32 * 10) {
            ExtendedExecutePayload memory payload = abi.decode(data, (ExtendedExecutePayload));
            executeData = _toExecuteData(
                LegacyExecutePayload({
                    resourceId: payload.resourceId,
                    originChainId: payload.originChainId,
                    caller: payload.caller,
                    recipient: payload.recipient,
                    amount: payload.amount,
                    receiveAmount: payload.receiveAmount,
                    decimalOrigin: payload.decimalOrigin,
                    originNonce: payload.originNonce
                })
            );
            crossChainExtType = payload.crossChainExtType;
            botGasAmountSnapshot = payload.botGasAmountSnapshot;
        } else {
            revert("invalid deposit data length");
        }
        require(crossChainExtType == 0 || crossChainExtType == 1, "invalid ext type");
        if (crossChainExtType == 0) {
            require(botGasAmountSnapshot == 0, "unexpected bot gas amount");
        } else {
            require(botGasAmountSnapshot > 0, "empty bot gas amount");
        }
    }

    function _toExecuteData(LegacyExecutePayload memory payload)
        private
        pure
        returns (ExecuteData memory executeData)
    {
        executeData.resourceId = payload.resourceId;
        executeData.originChainId = payload.originChainId;
        executeData.caller = payload.caller;
        executeData.recipient = payload.recipient;
        executeData.amount = payload.amount;
        executeData.receiveAmount = payload.receiveAmount;
        executeData.decimalOrigin = payload.decimalOrigin;
        executeData.originNonce = payload.originNonce;
    }

    // 获取投票信息
    function getProposal(
        uint256 originChainId,
        uint256 originDepositNonce,
        bytes32 dataHash
    ) external view returns (Proposal memory) {
        require(
            originDepositNonce < (1 << 224),
            "origin deposit nonce too big"
        );
        uint256 nonceAndID = (originDepositNonce << 32) |
            (originChainId & 0xFFFFFFFF);
        return proposals[nonceAndID][dataHash];
    }
}

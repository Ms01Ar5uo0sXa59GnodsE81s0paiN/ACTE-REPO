// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IVote {
    enum Vote {
        No,
        Yes
    }

    enum ProposalStatus {
        Inactive,
        Active,
        Passed,
        Executed,
        Cancelled
    }

    event RelayerThresholdChanged(uint indexed newThreshold);
    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);

    event ProposalEvent(
        uint256 indexed originChainID,
        uint256 indexed depositNonce,
        ProposalStatus indexed status,
        bytes32 resourceID,
        bytes32 dataHash
    );

    event ProposalVote(
        uint256 indexed originChainID,
        uint256 indexed depositNonce,
        ProposalStatus indexed status,
        bytes32 resourceID
    );

    event SourceRefundMarked(
        uint256 indexed originChainId,
        uint256 indexed originDepositNonce,
        bytes32 indexed dataHash,
        address marker
    );

    struct Proposal {
        bytes32 resourceId;
        bytes32 dataHash;
        address[] yesVotes;
        address[] noVotes;
        ProposalStatus status;
        uint256 proposedBlock;
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

    function voteProposal(
        uint256 originChainID,
        uint256 originDepositNonce,
        bytes32 resourceID,
        bytes32 dataHash
    ) external;

    function cancelProposal(
        uint256 originChainID,
        uint256 originDepositNonce,
        bytes32 dataHash
    ) external;

    function executeProposal(
        uint256 originChainID,
        uint256 originDepositNonce,
        bytes calldata data
    ) external;

    /// @notice BCR-03：目标链登记「源链已/将退款」，阻塞投票与 execute
    function markSourceRefunded(
        uint256 originChainId,
        uint256 originDepositNonce,
        bytes32 dataHash
    ) external;

    function getProposal(
        uint256 originChainID,
        uint256 depositNonce,
        bytes32 dataHash
    ) external returns (Proposal memory);

    /// @dev 与 Vote 合约 public mapping `sourceRefunded` 一致，供 BotBridge 在执行前复核 BCR-03
    function sourceRefunded(uint256 nonceAndID, bytes32 dataHash)
        external
        view
        returns (bool);
}

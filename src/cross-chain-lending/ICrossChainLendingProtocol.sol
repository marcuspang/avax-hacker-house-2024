// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ITeleporterMessenger, TeleporterMessageInput, TeleporterFeeInfo} from "@teleporter/ITeleporterMessenger.sol";

interface ICrossChainLendingProtocol {
    struct LoanRequest {
        address borrower;
        uint256 amount;
        uint256 duration;
        uint256 interestRate;
        address collateralToken;
        uint256 collateralAmount;
    }

    struct Loan {
        uint256 id;
        address borrower;
        address lender;
        uint256 amount;
        uint256 duration;
        uint256 interestRate;
        uint256 startTime;
        address collateralToken;
        uint256 collateralAmount;
        bool isActive;
    }

    event LoanRequested(bytes32 indexed sourceBlockchainID, uint256 indexed loanId, address indexed borrower, uint256 amount);
    event LoanFunded(bytes32 indexed sourceBlockchainID, uint256 indexed loanId, address indexed lender);
    event LoanRepaid(bytes32 indexed sourceBlockchainID, uint256 indexed loanId);
    event CollateralClaimed(bytes32 indexed sourceBlockchainID, uint256 indexed loanId, address indexed lender);

    function requestLoan(
        bytes32 destinationBlockchainID,
        address destinationLendingAddress,
        uint256 amount,
        uint256 duration,
        uint256 interestRate,
        address collateralToken,
        uint256 collateralAmount,
        address messageFeeAsset,
        uint256 messageFeeAmount
    ) external;

    function fundLoan(
        bytes32 sourceBlockchainID,
        uint256 loanId,
        address messageFeeAsset,
        uint256 messageFeeAmount
    ) external;

    function repayLoan(
        uint256 loanId,
        address messageFeeAsset,
        uint256 messageFeeAmount
    ) external;

    function claimCollateral(
        uint256 loanId,
        address messageFeeAsset,
        uint256 messageFeeAmount
    ) external;

    function getLoan(bytes32 sourceBlockchainID, uint256 loanId) external view returns (Loan memory);
}

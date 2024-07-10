// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ICrossChainLendingProtocol} from "./ICrossChainLendingProtocol.sol";
import {ITeleporterMessenger, TeleporterMessageInput, TeleporterFeeInfo} from "@teleporter/ITeleporterMessenger.sol";
import {TeleporterOwnerUpgradeable} from "@teleporter/upgrades/TeleporterOwnerUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts@4.8.1/token/ERC20/utils/SafeERC20.sol";
import {InterestRateLibrary} from "./InterestRateLibrary.sol";

/// @title CrossChainLendingProtocol
/// @author Marcus Pang
/// @notice This contract facilitates a simple loaning system for ERC20 tokens, essentially a marketplace for loaners to supply collateral to borrowers.
/// @dev This contract does not create new ERC20 tokens, and requires the collateral and loan tokens to be valid ERC20 tokens.
contract CrossChainLendingProtocol is ICrossChainLendingProtocol, TeleporterOwnerUpgradeable {
    using SafeERC20 for IERC20;

    uint256 private constant REQUIRED_GAS = 300_000;
    bytes32 public immutable currentBlockchainID;

    mapping(bytes32 destinationBlockchainID => mapping(uint256 loanID => Loan)) private loans;
    mapping(bytes32 destinationBlockchainID => uint256 loanCount) private loanCounters;

    constructor(address teleporterRegistryAddress) TeleporterOwnerUpgradeable(teleporterRegistryAddress, msg.sender) {
        currentBlockchainID = bytes32(block.chainid);
    }

    /// @notice Requests a loan from the lending contract on the destination chain.
    /// @dev Requires the borrower to approve the lending contract to transfer the collateral token on their behalf.
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
    ) external override {
        require(destinationBlockchainID != currentBlockchainID, "Invalid destination blockchain");
        require(destinationLendingAddress != address(0), "Invalid destination address");

        // Transfer collateral to this contract
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);

        LoanRequest memory request = LoanRequest({
            borrower: msg.sender,
            amount: amount,
            duration: duration,
            interestRate: interestRate,
            collateralToken: collateralToken,
            collateralAmount: collateralAmount
        });
        bytes memory messageData = abi.encode(LendingAction.RequestLoan, request);

        // Send cross-chain message
        ITeleporterMessenger teleporterMessenger = _getTeleporterMessenger();
        _sendCrossChainMessage(teleporterMessenger, destinationBlockchainID, destinationLendingAddress, messageData, messageFeeAsset, messageFeeAmount);

        emit LoanRequested(destinationBlockchainID, loanCounters[destinationBlockchainID], msg.sender, amount);
    }

    /// @notice Funds a loan in the lending contract on the borrower's chain.
    function fundLoan(
        bytes32 sourceBlockchainID,
        uint256 loanId,
        address messageFeeAsset,
        uint256 messageFeeAmount
    ) external override {
        Loan storage loan = loans[sourceBlockchainID][loanId];
        require(loan.isActive && loan.lender == address(0), "Invalid loan");

        // Transfer funds from lender to this contract
        IERC20(loan.collateralToken).safeTransferFrom(msg.sender, address(this), loan.amount);

        loan.lender = msg.sender;
        loan.startTime = block.timestamp;

        // Prepare loan funding data
        bytes memory messageData = abi.encode(LendingAction.FundLoan, loanId, msg.sender);

        // Send cross-chain message
        ITeleporterMessenger teleporterMessenger = _getTeleporterMessenger();
        _sendCrossChainMessage(teleporterMessenger, sourceBlockchainID, loan.borrower, messageData, messageFeeAsset, messageFeeAmount);

        emit LoanFunded(sourceBlockchainID, loanId, msg.sender);
    }

    function repayLoan(
        uint256 loanId,
        address messageFeeAsset,
        uint256 messageFeeAmount
    ) external override {
        Loan storage loan = loans[currentBlockchainID][loanId];
        require(loan.isActive && loan.borrower == msg.sender, "Invalid loan");

        uint256 repaymentAmount = loan.amount + (loan.amount * InterestRateLibrary.calculateInterestRate(block.timestamp - loan.startTime, loan.interestRate));

        // Transfer repayment from borrower to this contract
        IERC20(loan.collateralToken).safeTransferFrom(msg.sender, address(this), repaymentAmount);

        loan.isActive = false;

        // Prepare loan repayment data
        bytes memory messageData = abi.encode(LendingAction.RepayLoan, loanId, repaymentAmount);

        // Send cross-chain message
        ITeleporterMessenger teleporterMessenger = _getTeleporterMessenger();
        _sendCrossChainMessage(teleporterMessenger, currentBlockchainID, loan.lender, messageData, messageFeeAsset, messageFeeAmount);

        emit LoanRepaid(currentBlockchainID, loanId);
    }

    function claimCollateral(
        uint256 loanId,
        address messageFeeAsset,
        uint256 messageFeeAmount
    ) external override {
        Loan storage loan = loans[currentBlockchainID][loanId];
        require(loan.isActive && loan.lender == msg.sender, "Invalid loan");
        require(block.timestamp > loan.startTime + loan.duration, "Loan not yet defaulted");

        loan.isActive = false;

        // Prepare collateral claim data
        bytes memory messageData = abi.encode(LendingAction.ClaimCollateral, loanId);

        // Send cross-chain message
        ITeleporterMessenger teleporterMessenger = _getTeleporterMessenger();
        _sendCrossChainMessage(teleporterMessenger, currentBlockchainID, loan.borrower, messageData, messageFeeAsset, messageFeeAmount);

        emit CollateralClaimed(currentBlockchainID, loanId, msg.sender);
    }

    function getLoan(bytes32 sourceBlockchainID, uint256 loanId) external view override returns (Loan memory) {
        return loans[sourceBlockchainID][loanId];
    }

    function _receiveTeleporterMessage(
        bytes32 sourceBlockchainID,
        address originSenderAddress,
        bytes memory message
    ) internal override {
        (LendingAction action, bytes memory actionData) = abi.decode(message, (LendingAction, bytes));

        if (action == LendingAction.RequestLoan) {
            _handleLoanRequest(sourceBlockchainID, originSenderAddress, actionData);
        } else if (action == LendingAction.FundLoan) {
            _handleLoanFunding(sourceBlockchainID, originSenderAddress, actionData);
        } else if (action == LendingAction.RepayLoan) {
            _handleLoanRepayment(sourceBlockchainID, originSenderAddress, actionData);
        } else if (action == LendingAction.ClaimCollateral) {
            _handleCollateralClaim(sourceBlockchainID, originSenderAddress, actionData);
        } else {
            revert("Invalid lending action");
        }
    }

    function _handleLoanRequest(bytes32 sourceBlockchainID, address originSenderAddress, bytes memory actionData) private {
        LoanRequest memory request = abi.decode(actionData, (LoanRequest));
        uint256 loanId = loanCounters[sourceBlockchainID]++;

        loans[sourceBlockchainID][loanId] = Loan({
            id: loanId,
            borrower: request.borrower,
            lender: address(0),
            amount: request.amount,
            duration: request.duration,
            interestRate: request.interestRate,
            startTime: 0,
            collateralToken: request.collateralToken,
            collateralAmount: request.collateralAmount,
            isActive: true
        });

        emit LoanRequested(sourceBlockchainID, loanId, request.borrower, request.amount);
    }

    function _handleLoanFunding(bytes32 sourceBlockchainID, address originSenderAddress, bytes memory actionData) private {
        (uint256 loanId, address lender) = abi.decode(actionData, (uint256, address));
        Loan storage loan = loans[sourceBlockchainID][loanId];
        require(loan.isActive && loan.lender == address(0), "Invalid loan");

        loan.lender = lender;
        loan.startTime = block.timestamp;

        // Transfer loan amount to the borrower
        IERC20(loan.collateralToken).safeTransfer(loan.borrower, loan.amount);

        emit LoanFunded(sourceBlockchainID, loanId, lender);
    }

    function _handleLoanRepayment(bytes32 sourceBlockchainID, address originSenderAddress, bytes memory actionData) private {
        (uint256 loanId, uint256 repaymentAmount) = abi.decode(actionData, (uint256, uint256));
        Loan storage loan = loans[sourceBlockchainID][loanId];
        require(loan.isActive, "Invalid loan");

        loan.isActive = false;

        // Transfer repayment to the lender
        IERC20(loan.collateralToken).safeTransfer(loan.lender, repaymentAmount);

        // Return collateral to the borrower
        IERC20(loan.collateralToken).safeTransfer(loan.borrower, loan.collateralAmount);

        emit LoanRepaid(sourceBlockchainID, loanId);
    }

    function _handleCollateralClaim(bytes32 sourceBlockchainID, address originSenderAddress, bytes memory actionData) private {
        uint256 loanId = abi.decode(actionData, (uint256));
        Loan storage loan = loans[sourceBlockchainID][loanId];
        require(loan.isActive, "Invalid loan");

        loan.isActive = false;

        // Transfer collateral to the lender
        IERC20(loan.collateralToken).safeTransfer(loan.lender, loan.collateralAmount);

        emit CollateralClaimed(sourceBlockchainID, loanId, loan.lender);
    }

    function _manageFee(ITeleporterMessenger teleporterMessenger, address messageFeeAsset, uint256 messageFeeAmount)
        private
    {
        // For non-zero fee amounts, first transfer the fee to this contract, and then
        // allow the Teleporter contract to spend it.
        if (messageFeeAmount > 0) {
            IERC20(messageFeeAsset).safeTransferFrom(msg.sender, address(this), messageFeeAmount);
            IERC20(messageFeeAsset).safeIncreaseAllowance(address(teleporterMessenger), messageFeeAmount);
        }
    }

    function _sendCrossChainMessage(
        ITeleporterMessenger teleporterMessenger,
        bytes32 destinationBlockchainID,
        address destinationBridgeAddress,
        bytes memory messageData,
        address messageFeeAsset,
        uint256 messageFeeAmount
    ) private {
        _manageFee(teleporterMessenger, messageFeeAsset, messageFeeAmount);

        teleporterMessenger.sendCrossChainMessage(
            TeleporterMessageInput({
                destinationBlockchainID: destinationBlockchainID,
                destinationAddress: destinationBridgeAddress,
                feeInfo: TeleporterFeeInfo({
                    feeTokenAddress: messageFeeAsset,
                    amount: messageFeeAmount
                }),
                requiredGasLimit: REQUIRED_GAS,
                allowedRelayerAddresses: new address[](0),
                message: messageData
            })
        );
    }

    enum LendingAction { RequestLoan, FundLoan, RepayLoan, ClaimCollateral }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

library InterestRateLibrary {
    function calculateInterestRate(uint256 duration, uint256 interestRate) internal pure returns (uint256) {
        return (interestRate * duration) / 365 days;
    }
}

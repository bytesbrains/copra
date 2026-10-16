// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICopraOracle {
    /// @notice Returns the benchmark commodity price of 1 unit of Copra in USD (8 decimals)
    function getCopraPriceUSD() external view returns (uint256 price, uint256 updatedAt);

    /// @notice Decimals used by the price feed (standard 8 decimals)
    function decimals() external view returns (uint8);
}

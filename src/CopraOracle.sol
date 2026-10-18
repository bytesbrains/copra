// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ICopraOracle.sol";

/**
 * @title CopraOracle
 * @author Copra Protocol (https://copra.dev)
 * @notice Oracle contract holding the copra price in USD per kg (8 decimals) used by CopraVault.
 *         It reads no external source: one immutable address, feedUpdater, posts every price, within
 *         the 20% and one-per-day limits below. On testnet that is scripts/oracle-feeder.sh, which
 *         posts a declared source or a manual override. The intended source of truth is GCPI, the
 *         open copra index specified in docs/specs/GCPI-001.md, which does not publish a price yet.
 */
contract CopraOracle is ICopraOracle {
    address public immutable feedUpdater;
    uint256 private copraPriceUSD; // 8 decimals (e.g. $1.42 = 142000000)
    uint256 private lastUpdatedAt;

    uint8 public constant override decimals = 8;
    uint256 public constant MAX_PRICE_CHANGE_BPS = 2000; // 20% max single shift safeguard
    uint256 public constant HEARTBEAT = 7 days;
    // Spaces updates out so the 20% collar bounds movement over time, not just per transaction.
    // Must stay below HEARTBEAT, or a fresh price could not be posted before the old one goes stale.
    uint256 public constant MIN_UPDATE_INTERVAL = 1 days;

    event PriceUpdated(uint256 indexed oldPrice, uint256 indexed newPrice, uint256 timestamp);

    error OnlyUpdater();
    error StalePrice();
    error PriceTooLow();
    error PriceChangeExceeded();
    error UpdateTooSoon();

    modifier onlyUpdater() {
        if (msg.sender != feedUpdater) revert OnlyUpdater();
        _;
    }

    /**
     * @param _feedUpdater Address of the automated oracle feeder bot or Chainlink relay.
     * @param _initialPrice Initial Copra benchmark price in USD with 8 decimals (e.g. 140000000 = $1.40).
     */
    constructor(address _feedUpdater, uint256 _initialPrice) {
        if (_initialPrice == 0) revert PriceTooLow();
        feedUpdater = _feedUpdater;
        copraPriceUSD = _initialPrice;
        lastUpdatedAt = block.timestamp;
        emit PriceUpdated(0, _initialPrice, block.timestamp);
    }

    /**
     * @notice Updates the copra commodity benchmark price, at most once per MIN_UPDATE_INTERVAL.
     * @param _newPrice New price with 8 decimals.
     */
    function updatePrice(uint256 _newPrice) external onlyUpdater {
        if (_newPrice == 0) revert PriceTooLow();
        // The constructor sets lastUpdatedAt, so the first update also waits a full interval.
        if (block.timestamp < lastUpdatedAt + MIN_UPDATE_INTERVAL) revert UpdateTooSoon();

        // Safeguard against oracle flash crashes / manipulation (max 20% shift per update unless initialized)
        if (copraPriceUSD > 0) {
            uint256 diff = _newPrice > copraPriceUSD ? _newPrice - copraPriceUSD : copraPriceUSD - _newPrice;
            if ((diff * 10000) / copraPriceUSD > MAX_PRICE_CHANGE_BPS) {
                revert PriceChangeExceeded();
            }
        }

        uint256 oldPrice = copraPriceUSD;
        copraPriceUSD = _newPrice;
        lastUpdatedAt = block.timestamp;

        emit PriceUpdated(oldPrice, _newPrice, block.timestamp);
    }

    /**
     * @notice Returns the latest validated copra commodity price.
     */
    function getCopraPriceUSD() external view override returns (uint256 price, uint256 updatedAt) {
        if (block.timestamp - lastUpdatedAt > HEARTBEAT) revert StalePrice();
        return (copraPriceUSD, lastUpdatedAt);
    }
}

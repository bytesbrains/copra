// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../gcpi/GCPITypes.sol";

/**
 * @title IGCPI
 * @author Copra Protocol (https://copra.dev)
 * @notice COPRA-001 §4.1: the period records the reserve protocol reads. Forward-priced
 *         settlement must name a specific future period, so the v1 price-plus-timestamp
 *         interface is not enough. The manager binds one adapter immutably at deployment;
 *         adopting another GCPI version is another deployment (§14).
 * @dev Price is USD per reference kilogram at 8 decimals (COPRA-001 §3). The GCPI contracts
 *      record it at 1e-18, so a mainnet adapter divides by 1e10; the mock used here quotes
 *      8 decimals natively. Only VALID carries a price; every other status is an explicit
 *      non-price and reads 0. Period ids increase by one per calculation period from 0.
 */
interface IGCPI {
    /// @notice A bounded scan crossed `maxScan` periods without answering. The manager treats
    ///         it as "too far to tell", which past any plausible outage means a dead index.
    error ScanTooLong();

    /// @notice The period whose time window contains `timestamp`, defined by time alone so
    ///         that a redemption request lands in its period before anything finalizes.
    function periodOf(uint256 timestamp) external view returns (uint256);

    /// @notice The finalized record of `periodId`: price (8 decimals, 0 unless VALID),
    ///         status, and finalization timestamp. Unfinalized periods read as NONE.
    function record(uint256 periodId) external view returns (uint256 price, Status status, uint256 finalizedAt);

    /// @notice One past the highest finalized period id. Every id below `count` has a
    ///         final record (VALID or an explicit non-price); ids at or above it are NONE.
    function count() external view returns (uint256);

    /// @notice The latest finalized VALID period at or below `count - 1`, scanning back at
    ///         most `maxScan`. Reverts ScanTooLong past the cap. Age is the caller's check:
    ///         COPRA-001 usability also needs MAX_PRICE_AGE, which is the manager's rule.
    function latestValid(uint256 maxScan)
        external
        view
        returns (bool found, uint256 id, uint256 price, uint256 finalizedAt);

    /// @notice The first finalized VALID period at or after `from`, scanning forward at most
    ///         `maxScan`. Reverts ScanTooLong past the cap. `found` false means no later
    ///         period has finalized VALID yet — settle later, or cancel past expiry.
    function firstValidAtOrAfter(uint256 from, uint256 maxScan)
        external
        view
        returns (bool found, uint256 id, uint256 price);
}

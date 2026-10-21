// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IGCPI.sol";
import "../gcpi/GCPITypes.sol";

/**
 * @title MockGCPI
 * @author Copra Protocol (https://copra.dev)
 * @notice COPRA-001 §4.1 test double, for Forge tests and the Base Sepolia sandbox.
 *         Periods are fixed-length windows from genesis; only the trusted updater
 *         finalizes the next period once its window has ended, with any price and any
 *         final status. There is no aggregation and no challenge window: it is a mock,
 *         and a deployment script must refuse every chain but testnets for that reason.
 */
contract MockGCPI is IGCPI {
    /// @notice First second of period 0.
    uint256 public immutable genesis;
    /// @notice Seconds per calculation period (30 days on the testnet deployment).
    uint256 public immutable periodDuration;
    /// @notice The only address that may finalize periods: the test contract in Forge,
    ///         a trusted updater on testnet. Finalized prices move funds in the manager,
    ///         so this must never be permissionless on a shared deployment.
    address public immutable updater;

    struct Record {
        uint256 price;
        Status status;
        uint256 finalizedAt;
    }

    Record[] private _records;

    event PeriodFinalized(uint256 indexed periodId, Status status, uint256 price);

    error PeriodNotOver(uint256 periodId, uint256 periodEnd);
    error NotFinalStatus(Status status);
    error ZeroPriceForValid();
    error NonzeroPriceForNonValid();
    error OnlyUpdater();
    error ZeroAddress();

    constructor(uint256 _genesis, uint256 _periodDuration, address _updater) {
        if (_updater == address(0)) revert ZeroAddress();
        genesis = _genesis;
        periodDuration = _periodDuration;
        updater = _updater;
    }

    /**
     * @notice Finalizes the next period. Updater only: the price feeds the manager's
     *         fund-moving math, so anyone-may-finalize would let anyone move funds.
     *         The window must have ended, so no period finalizes before its sources
     *         could have published.
     * @param price USD per kilogram at 8 decimals; nonzero if and only if VALID.
     * @param status The final status: anything but NONE and PENDING_CONFIRMATION.
     */
    function finalize(uint256 price, Status status) external returns (uint256 periodId) {
        if (msg.sender != updater) revert OnlyUpdater();
        if (status == Status.NONE || status == Status.PENDING_CONFIRMATION) revert NotFinalStatus(status);
        if (status == Status.VALID) {
            if (price == 0) revert ZeroPriceForValid();
        } else if (price != 0) {
            revert NonzeroPriceForNonValid();
        }
        periodId = _records.length;
        uint256 end = genesis + (periodId + 1) * periodDuration;
        if (block.timestamp < end) revert PeriodNotOver(periodId, end);
        _records.push(Record(price, status, block.timestamp));
        emit PeriodFinalized(periodId, status, price);
    }

    function periodOf(uint256 timestamp) external view returns (uint256) {
        return (timestamp - genesis) / periodDuration;
    }

    function record(uint256 periodId) external view returns (uint256 price, Status status, uint256 finalizedAt) {
        if (periodId >= _records.length) return (0, Status.NONE, 0);
        Record storage r = _records[periodId];
        return (r.price, r.status, r.finalizedAt);
    }

    function count() external view returns (uint256) {
        return _records.length;
    }

    function latestValid(uint256 maxScan)
        external
        view
        returns (bool found, uint256 id, uint256 price, uint256 finalizedAt)
    {
        uint256 n = _records.length;
        uint256 crossed;
        while (n > 0) {
            if (++crossed > maxScan) revert IGCPI.ScanTooLong();
            Record storage r = _records[--n];
            if (r.status == Status.VALID) return (true, n, r.price, r.finalizedAt);
        }
        return (false, 0, 0, 0);
    }

    function firstValidAtOrAfter(uint256 from, uint256 maxScan)
        external
        view
        returns (bool found, uint256 id, uint256 price)
    {
        uint256 n = _records.length;
        uint256 crossed;
        for (uint256 i = from; i < n; ++i) {
            if (++crossed > maxScan) revert IGCPI.ScanTooLong();
            Record storage r = _records[i];
            if (r.status == Status.VALID) return (true, i, r.price);
        }
        return (false, 0, 0);
    }
}

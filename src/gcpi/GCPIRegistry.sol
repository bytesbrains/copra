// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GCPIMath.sol";
import "./GCPITypes.sol";

/**
 * @title GCPIRegistry
 * @author Copra Protocol (https://copra.dev)
 * @notice GCPI-001 §11.3: the finalized record of every GCPI period, for consumers such as COPRA-001 (§4.1).
 *         Its one writer is the GCPIEngine that deployed it, and a record once written never changes
 *         (§8.5, Invariant 4). It has no owner and no other way in.
 *
 *         A period is a calendar month in UTC, numbered year × 12 + month − 1, so the id increases by one per
 *         period and the window of any period, past or future, is known on-chain (periodStart, periodOf).
 *
 *         Reading it: status NONE means the period has no final record yet — not finalized, or held for
 *         confirmation. Only VALID carries a price. Every other status is an explicit non-price (Invariant 5).
 */
contract GCPIRegistry {
    struct PeriodRecord {
        Status status;
        uint256 price; // GCPI level at 1e-18 USD/kg; 0 unless VALID
        uint64 finalizedAt;
        bytes32 inputCommitment; // the attested source set (gcpi/ENGINE.md §7)
    }

    uint256 private constant FIRST_ID = 1970 * 12; // 1970-01
    uint256 private constant LAST_ID = 9999 * 12 + 11; // 9999-12

    address public immutable engine;
    bytes32 public immutable methodologyHash;
    string public methodologyId;

    mapping(uint256 => PeriodRecord) private _records;

    event PeriodFinalized(uint256 indexed periodId, Status status, uint256 price, bytes32 inputCommitment);

    error OnlyEngine();
    error AlreadyFinal(uint256 periodId);
    error NotFinal();

    constructor(string memory methodologyId_, bytes32 methodologyHash_) {
        engine = msg.sender;
        methodologyId = methodologyId_;
        methodologyHash = methodologyHash_;
    }

    /// @notice Written once per period by the engine.
    function publish(uint256 periodId, Status status, uint256 price, bytes32 inputCommitment) external {
        if (msg.sender != engine) revert OnlyEngine();
        if (status == Status.NONE || status == Status.PENDING_CONFIRMATION) revert NotFinal();
        if (_records[periodId].status != Status.NONE) revert AlreadyFinal(periodId);
        _records[periodId] = PeriodRecord(status, price, uint64(block.timestamp), inputCommitment);
        emit PeriodFinalized(periodId, status, price, inputCommitment);
    }

    /// @notice COPRA-001 §4.1: (price, status, finalizedAt) of a period, by id.
    function getRecord(uint256 periodId) external view returns (PeriodRecord memory) {
        return _records[periodId];
    }

    /// @notice Unix seconds at which a period begins, UTC. Periods from 1970-01 to 9999-12.
    function periodStart(uint256 periodId) external pure returns (uint256) {
        if (periodId < FIRST_ID || periodId > LAST_ID) revert Malformed("period");
        return uint256(GCPIMath.periodStart(periodId));
    }

    /// @notice The period containing a timestamp, up to the end of 9999.
    function periodOf(uint256 timestamp) external pure returns (uint256 id) {
        if (timestamp >= uint256(GCPIMath.periodStart(LAST_ID + 1))) revert Malformed("timestamp");
        int256 ts = int256(timestamp);
        // No month is longer than 31 days, so the estimate is never high, and the loop only walks it up.
        id = FIRST_ID + timestamp / (31 days);
        while (GCPIMath.periodStart(id + 1) <= ts) id++;
    }

    /// @notice "YYYY-MM" to a period id.
    function idOf(string calldata ym) external pure returns (uint256) {
        (bool ok, uint256 t) = GCPIMath.parsePeriod(ym);
        if (!ok) revert Malformed("period");
        return t;
    }
}

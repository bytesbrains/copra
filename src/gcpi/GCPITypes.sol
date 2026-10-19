// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @notice Types shared by the GCPI contracts (GCPI-001 §11, #92). The names and their order follow the
 *         reference engine, gcpi/ENGINE.md, whose canonical output uses the same words in lower or upper case.
 */

/// @dev A structurally malformed input, with the reference engine's error code (gcpi/ENGINE.md §1).
error Malformed(string code);

/// @notice One attested observation, field for field as in gcpi/ENGINE.md §1. The engine's empty `fx`
///         and `fx_exp` are `hasFx == false`, with both zero.
struct Observation {
    string market;
    string period; // YYYY-MM, the month the price reports
    string source;
    uint256 price;
    uint256 priceExp;
    string currency;
    string unit;
    bool hasFx;
    uint256 fx;
    uint256 fxExp;
    string fxSource;
    uint256 published;
    bytes32 record;
    string basis;
}

/// @notice GCPI-001 §9.4. NONE means the period has no final record yet.
enum Status {
    NONE,
    VALID,
    PENDING_CONFIRMATION,
    INSUFFICIENT_COVERAGE,
    STALE,
    INVALID_INPUT,
    UNAVAILABLE
}

/// @notice gcpi/ENGINE.md §6, the `reason` of a period record.
enum Reason {
    NONE,
    BASE,
    BASE_COVERAGE,
    LINKED,
    CONFIRMED,
    CIRCUIT_BREAKER,
    CIRCUIT_BREAKER_REJECTED,
    MARKET_PENDING,
    EARLIER_PERIOD_PENDING,
    MARKET_INVALID,
    MARKET_DISPUTED,
    MARKET_REJECTED,
    MARKET_STALE,
    NO_OBSERVATIONS,
    COVERAGE,
    NO_BASE,
    NO_MATCHED_MARKET
}

/// @notice gcpi/ENGINE.md §4–§5, one market's decision for one period. NONE: not yet collected.
enum Decision {
    NONE,
    ABSENT,
    ACCEPTED,
    PENDING,
    REJECTED_ANOMALY,
    INVALID,
    DISPUTED,
    STALE
}

/// @notice gcpi/ENGINE.md §5. NONE is the engine's null: no value, or bands disabled.
enum Band {
    NONE,
    FIRST,
    NORMAL,
    CORROBORATE,
    CONFIRM,
    QUARANTINE
}

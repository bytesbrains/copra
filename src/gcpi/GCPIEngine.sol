// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./GCPIMath.sol";
import "./GCPITypes.sol";
import "./GCPIRegistry.sol";
import "./ObservationVerifier.sol";

/**
 * @title GCPIEngine
 * @author Copra Protocol (https://copra.dev)
 * @notice GCPI-001 §11.2: the reference engine (gcpi/ENGINE.md) run on-chain, one period at a time. Anyone may
 *         call finalize() once a period's observation window has closed, and the result does not depend on who
 *         calls it or when (§10.3): it reads only the attested observations the verifier closed for that period.
 *         Final records go to GCPIRegistry, which this contract deploys and is the only writer of.
 *
 *         The methodology is fixed in the constructor and cannot change (§13.1, Invariant 7). There is no owner,
 *         no price setter, no bypass and no upgrade path (§10.2).
 *
 *         Each period is decided in the order engine.py decides it: collect the period's observations, decide
 *         each market against its history (§7), then compute every index period whose markets are all decided
 *         (§8, §9). A run of the reference engine from `firstPeriod` to the last finalized period gives the same
 *         record for every period, byte for byte (test/gcpi/GCPIVectors.t.sol).
 *
 *         Execution incentive (§10.4): anyone may fund the pool by sending ETH. Each finalize() credits its caller
 *         at most `rewardPerPeriod`. An empty pool pays nothing and changes nothing else: an unfinalized period
 *         simply has no record, which consumers must treat as not yet published, never as a price.
 */
contract GCPIEngine is ReentrancyGuard {
    struct Methodology {
        string id;
        string[] markets; // strictly ascending
        uint256[] weights;
        string[] signals;
        string[] corroborated; // the markets that list corroborators, strictly ascending
        string[][] corroborators; // their corroborators, in order
        uint256 minCoverageBp;
        uint256 maxPublicationLagDays;
        bool hasBands;
        uint256[3] bandsBp;
        bool hasCircuitBreaker;
        uint256 circuitBreakerBp;
        string basePeriod;
    }

    /// @notice One series' observations for one period, collapsed as gcpi/ENGINE.md §4 does.
    struct Entry {
        uint8 state; // ENTRY_*
        uint256 price;
        bytes32 basis;
    }

    struct MarketDecision {
        Decision decision;
        Band band;
        uint256 price;
        bool decided;
        uint32 decidedAt;
    }

    struct Record {
        Status status;
        Reason reason;
        uint256 level;
        uint256 candidate;
        bool hasLink;
        uint32 linkedFrom;
        uint256 matched; // bit i: market i
        bool decided;
        uint32 decidedAt;
    }

    struct MarketState {
        bool hasRef;
        uint32 refPeriod;
        uint256 refPrice;
        uint32[] pending; // oldest first
    }

    uint8 private constant ENTRY_NONE = 0;
    uint8 private constant ENTRY_OK = 1;
    uint8 private constant ENTRY_INVALID = 2;
    uint8 private constant ENTRY_DISPUTED = 3;
    uint8 private constant ENTRY_STALE = 4;

    uint256 public constant MAX_MARKETS = 64;
    /// @notice Index periods one call computes at most. A market pending for years releases every period after it at
    ///         once; past this many, advance() continues, so no backlog can outgrow a block.
    uint256 public constant MAX_INDEX_PER_CALL = 24;
    uint256 public constant MAX_SERIES = 128;

    ObservationVerifier public immutable verifier;
    GCPIRegistry public immutable registry;
    bytes32 public immutable methodologyHash;
    uint256 public immutable firstPeriod;
    uint256 public immutable basePeriod;
    uint256 public immutable minCoverageBp;
    uint256 public immutable maxPublicationLagDays;
    bool public immutable hasBands;
    bool public immutable hasCircuitBreaker;
    uint256 public immutable circuitBreakerBp;
    uint256 public immutable totalWeight;
    uint256 public immutable rewardPerPeriod;

    string public methodologyId;
    string[] private _markets;
    uint256[] private _weights;
    string[] private _signals;
    uint256[3] private _bands;
    mapping(uint256 => uint256[]) private _corroborators; // market => series indices

    /// @notice The next period finalize() collects, and the first index period not yet computed.
    uint256 public nextPeriod;
    uint256 public nextIndexPeriod;
    uint256 private _at; // engine.py's `at`: the period at which every earlier index period was decided
    bool private _hasValid;
    uint256 private _lastValid;
    uint32[] private _pend; // index periods held by the circuit breaker, oldest first

    mapping(uint256 => mapping(uint256 => Entry)) private _data; // series => period
    mapping(uint256 => mapping(uint256 => MarketDecision)) private _decisions; // market => period
    mapping(uint256 => MarketState) private _state;
    mapping(uint256 => Record) private _records;
    mapping(uint256 => bytes32) public inputCommitment;

    uint256 public rewardsOwed;
    mapping(address => uint256) public rewards;

    event PeriodCollected(uint256 indexed period, bytes32 inputCommitment);
    event RewardCredited(address indexed caller, uint256 indexed period, uint256 amount);
    event RewardClaimed(address indexed caller, uint256 amount);

    error NotClosed(uint256 period, uint256 closesAt);
    error VerifierMismatch();
    error NothingToClaim();
    error TransferFailed();
    error PeriodNotCollected(uint256 period);

    /**
     * @param m The methodology version, validated as engine.py's check_methodology does.
     * @param firstPeriod_ The engine's `first`: the period from which market histories start.
     * @param verifier_ An ObservationVerifier over exactly this methodology's series, first period and lag.
     * @param rewardPerPeriod_ The most one finalize() pays its caller from the pool.
     */
    constructor(
        Methodology memory m,
        string memory firstPeriod_,
        ObservationVerifier verifier_,
        uint256 rewardPerPeriod_
    ) {
        _checkMethodology(m);
        (bool ok, uint256 first) = GCPIMath.parsePeriod(firstPeriod_);
        if (!ok) revert Malformed("first");
        (, uint256 base) = GCPIMath.parsePeriod(m.basePeriod);
        if (first > base) revert Malformed("period_range");

        uint256 total;
        for (uint256 i = 0; i < m.markets.length; i++) {
            _markets.push(m.markets[i]);
            _weights.push(m.weights[i]);
            total += m.weights[i];
        }
        for (uint256 i = 0; i < m.signals.length; i++) {
            _signals.push(m.signals[i]);
        }
        for (uint256 i = 0; i < m.corroborated.length; i++) {
            uint256 k = _marketIndex(m.markets, m.corroborated[i]);
            for (uint256 j = 0; j < m.corroborators[i].length; j++) {
                _corroborators[k].push(_seriesIndex(m, m.corroborators[i][j]));
            }
        }
        _bands = m.bandsBp;

        // The verifier must collect exactly the series this methodology reads, over the same windows.
        string[] memory vs = verifier_.series();
        if (vs.length != m.markets.length + m.signals.length) revert VerifierMismatch();
        for (uint256 i = 0; i < vs.length; i++) {
            string memory want = i < m.markets.length ? m.markets[i] : m.signals[i - m.markets.length];
            if (keccak256(bytes(vs[i])) != keccak256(bytes(want))) revert VerifierMismatch();
        }
        if (verifier_.firstPeriod() != first || verifier_.maxPublicationLagDays() != m.maxPublicationLagDays) {
            revert VerifierMismatch();
        }

        bytes32 hash = sha256(bytes(_canonicalMethodology(m)));
        methodologyId = m.id;
        methodologyHash = hash;
        verifier = verifier_;
        firstPeriod = first;
        basePeriod = base;
        minCoverageBp = m.minCoverageBp;
        maxPublicationLagDays = m.maxPublicationLagDays;
        hasBands = m.hasBands;
        hasCircuitBreaker = m.hasCircuitBreaker;
        circuitBreakerBp = m.circuitBreakerBp;
        totalWeight = total;
        rewardPerPeriod = rewardPerPeriod_;
        nextPeriod = first;
        nextIndexPeriod = base;
        _at = first;
        registry = new GCPIRegistry(m.id, hash);
    }

    /// @notice Fund the finalization incentive pool.
    receive() external payable {}

    // ---------------------------------------------------------------------------------------------------
    // Finalization.

    /**
     * @notice Collect the next period, decide its markets, and compute every index period that is now decided.
     * @return period The period collected.
     */
    function finalize() external returns (uint256 period) {
        period = nextPeriod;
        uint256 closes = verifier.closesAt(period);
        if (block.timestamp < closes) revert NotClosed(period, closes);
        _collect(period);
        _decideMarkets(period);
        nextPeriod = period + 1;
        _advanceIndex();

        uint256 pool = address(this).balance - rewardsOwed;
        uint256 pay = pool < rewardPerPeriod ? pool : rewardPerPeriod;
        if (pay > 0) {
            rewards[msg.sender] += pay;
            rewardsOwed += pay;
            emit RewardCredited(msg.sender, period, pay);
        }
    }

    /// @notice Compute index periods left over by a finalize() that hit MAX_INDEX_PER_CALL. Anyone may call it.
    /// @return computed How many index periods this call computed.
    function advance() external returns (uint256 computed) {
        return _advanceIndex();
    }

    function claimReward() external nonReentrant {
        uint256 amount = rewards[msg.sender];
        if (amount == 0) revert NothingToClaim();
        rewards[msg.sender] = 0;
        rewardsOwed -= amount;
        emit RewardClaimed(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ---------------------------------------------------------------------------------------------------
    // Reading.

    function markets() external view returns (string[] memory) {
        return _markets;
    }

    function weights() external view returns (uint256[] memory) {
        return _weights;
    }

    function signals() external view returns (string[] memory) {
        return _signals;
    }

    function decision(uint256 market, uint256 t) external view returns (MarketDecision memory) {
        return _decisions[market][t];
    }

    function entry(uint256 seriesIndex, uint256 t) external view returns (Entry memory) {
        return _data[seriesIndex][t];
    }

    /// @notice Bit i set when market i is ACCEPTED at t.
    function accepted(uint256 t) public view returns (uint256 mask) {
        for (uint256 k = 0; k < _markets.length; k++) {
            if (_decisions[k][t].decision == Decision.ACCEPTED) mask |= 1 << k;
        }
    }

    /**
     * @notice The index record of period t, from the base period to the last collected one. A period not yet
     *         computed reads as engine.py reports it: PENDING_CONFIRMATION, because a market of its own
     *         (`market_pending`) or of an earlier period (`earlier_period_pending`) is still pending.
     */
    function record(uint256 t) external view returns (Record memory r) {
        if (t < basePeriod || t >= nextPeriod) revert PeriodNotCollected(t);
        if (t < nextIndexPeriod) return _records[t];
        r.status = Status.PENDING_CONFIRMATION;
        r.reason = _allDecided(t) ? Reason.EARLIER_PERIOD_PENDING : Reason.MARKET_PENDING;
    }

    // ---------------------------------------------------------------------------------------------------
    // Pass 1: the period's observations, then each market on its own (engine.py collect, decide_market).

    function _collect(uint256 t) private {
        uint256 nSeries = _markets.length + _signals.length;
        bytes32[] memory all = new bytes32[](nSeries * verifier.MAX_OBSERVATIONS());
        uint256 n;
        for (uint256 s = 0; s < nSeries; s++) {
            bytes32[] memory cs = verifier.commitments(s, t);
            if (cs.length == 0) continue;
            for (uint256 i = 0; i < cs.length; i++) {
                all[n++] = cs[i];
            }
            _data[s][t] = _collapse(cs, t);
        }
        bytes32 ic = _inputCommitment(all, n);
        inputCommitment[t] = ic;
        emit PeriodCollected(t, ic);
    }

    /// @dev One normalized price and basis: OK. More than one: DISPUTED. None usable: STALE if any was late.
    function _collapse(bytes32[] memory cs, uint256 t) private view returns (Entry memory e) {
        bool anyUsable;
        bool anyStale;
        bool disputed;
        for (uint256 i = 0; i < cs.length; i++) {
            Observation memory o = verifier.observation(cs[i]).observation;
            (uint256 p, uint8 how) = GCPIMath.normalize(o, t, maxPublicationLagDays);
            if (how == GCPIMath.NORM_STALE) anyStale = true;
            if (how != GCPIMath.NORM_OK) continue;
            bytes32 b = keccak256(bytes(o.basis));
            if (anyUsable && (p != e.price || b != e.basis)) disputed = true;
            (anyUsable, e.price, e.basis) = (true, p, b);
        }
        if (disputed) return Entry(ENTRY_DISPUTED, 0, 0);
        if (anyUsable) e.state = ENTRY_OK;
        else e.state = anyStale ? ENTRY_STALE : ENTRY_INVALID;
    }

    /// @dev SHA-256 of "GCPI-INPUT-v1", a 32-byte count, then the commitments in ascending order.
    function _inputCommitment(bytes32[] memory cs, uint256 n) private pure returns (bytes32) {
        for (uint256 i = 1; i < n; i++) {
            bytes32 v = cs[i];
            uint256 j = i;
            while (j > 0 && cs[j - 1] > v) {
                cs[j] = cs[j - 1];
                j--;
            }
            cs[j] = v;
        }
        bytes memory out = abi.encodePacked(GCPIMath.str("GCPI-INPUT-v1"), n);
        for (uint256 i = 0; i < n; i++) {
            out = abi.encodePacked(out, cs[i]);
        }
        return sha256(out);
    }

    function _decideMarkets(uint256 t) private {
        for (uint256 k = 0; k < _markets.length; k++) {
            Entry memory e = _data[k][t];
            if (e.state != ENTRY_OK) {
                Decision d = e.state == ENTRY_NONE
                    ? Decision.ABSENT
                    : e.state == ENTRY_INVALID
                        ? Decision.INVALID
                        : e.state == ENTRY_DISPUTED ? Decision.DISPUTED : Decision.STALE;
                _decisions[k][t] = MarketDecision(d, Band.NONE, 0, true, uint32(t));
                continue;
            }
            MarketState storage ms = _state[k];
            uint256 p = e.price;
            if (!ms.hasRef) {
                (ms.hasRef, ms.refPeriod, ms.refPrice) = (true, uint32(t), p);
                _decisions[k][t] = MarketDecision(Decision.ACCEPTED, Band.FIRST, p, true, uint32(t));
                continue;
            }
            (bool okRef, Band bRef) = _passes(k, ms.refPeriod, ms.refPrice, t, p);
            bool okPend;
            Band bPend;
            uint256 n = ms.pending.length;
            uint256 last = n > 0 ? ms.pending[n - 1] : 0;
            if (n > 0) (okPend, bPend) = _passes(k, last, _decisions[k][last].price, t, p);
            if (okPend && (!okRef || GCPIMath.closer(p, _decisions[k][last].price, ms.refPrice))) {
                // The newest pending observation is confirmed; the older ones were not.
                for (uint256 i = 0; i + 1 < n; i++) {
                    _settle(k, ms.pending[i], Decision.REJECTED_ANOMALY, t);
                }
                _settle(k, last, Decision.ACCEPTED, t);
                _accept(ms, k, t, p, bPend);
            } else if (okRef) {
                // Back in line with the last accepted price: anything pending was not confirmed.
                for (uint256 i = 0; i < n; i++) {
                    _settle(k, ms.pending[i], Decision.REJECTED_ANOMALY, t);
                }
                _accept(ms, k, t, p, bRef);
            } else {
                ms.pending.push(uint32(t));
                _decisions[k][t] = MarketDecision(Decision.PENDING, bRef, p, false, 0);
            }
        }
    }

    function _accept(MarketState storage ms, uint256 k, uint256 t, uint256 p, Band b) private {
        delete ms.pending;
        (ms.refPeriod, ms.refPrice) = (uint32(t), p);
        _decisions[k][t] = MarketDecision(Decision.ACCEPTED, b, p, true, uint32(t));
    }

    function _settle(uint256 k, uint256 q, Decision d, uint256 t) private {
        MarketDecision storage md = _decisions[k][q];
        (md.decision, md.decided, md.decidedAt) = (d, true, uint32(t));
    }

    /// @dev (passes, band) for a price p at t checked against a reference price at refT.
    function _passes(uint256 k, uint256 refT, uint256 refP, uint256 t, uint256 p) private view returns (bool, Band) {
        if (!hasBands) return (true, Band.NONE);
        Band b = GCPIMath.band(refP, p, _bands, t - refT);
        if (b == Band.NORMAL) return (true, b);
        if (b == Band.QUARANTINE) return (false, b);
        int256 direction = p > refP ? int256(1) : p < refP ? int256(-1) : int256(0);
        return (_corroborated(k, refT, t, direction, b == Band.CONFIRM), b);
    }

    /// @dev A corroborator moved in `direction` between a and t, on the same basis at both ends; `strong` also
    ///      needs the move to exceed the normal band.
    function _corroborated(uint256 k, uint256 a, uint256 t, int256 direction, bool strong) private view returns (bool) {
        if (direction == 0) return false;
        uint256[] storage cs = _corroborators[k];
        for (uint256 i = 0; i < cs.length; i++) {
            Entry memory ea = _data[cs[i]][a];
            Entry memory et = _data[cs[i]][t];
            if (ea.state != ENTRY_OK || et.state != ENTRY_OK || ea.basis != et.basis) continue;
            int256 moved = et.price > ea.price ? int256(1) : et.price < ea.price ? int256(-1) : int256(0);
            if (moved != direction) continue;
            if (strong && GCPIMath.within(ea.price, et.price, _bands[0], t - a)) continue;
            return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------------------------------------
    // Pass 2: the index, in the order its periods become decidable (engine.py run).

    function _allDecided(uint256 t) private view returns (bool) {
        for (uint256 k = 0; k < _markets.length; k++) {
            if (!_decisions[k][t].decided) return false;
        }
        return true;
    }

    function _advanceIndex() private returns (uint256 n) {
        while (n < MAX_INDEX_PER_CALL && nextIndexPeriod < nextPeriod && _allDecided(nextIndexPeriod)) {
            _computeIndex(nextIndexPeriod);
            nextIndexPeriod++;
            n++;
        }
    }

    function _computeIndex(uint256 t) private {
        uint256 at = _at > t ? _at : t;
        for (uint256 k = 0; k < _markets.length; k++) {
            if (_decisions[k][t].decidedAt > at) at = _decisions[k][t].decidedAt;
        }
        _at = at;
        uint256 acc = accepted(t);

        if (t == basePeriod) {
            if (acc == (1 << _markets.length) - 1) {
                uint256 sum;
                for (uint256 k = 0; k < _markets.length; k++) {
                    sum += _weights[k] * _decisions[k][t].price;
                }
                _final(t, Status.VALID, Reason.BASE, at, GCPIMath.hdiv(sum, totalWeight), false, 0, 0);
                (_hasValid, _lastValid) = (true, t);
            } else {
                (Status st, Reason re) = _nonvalid(t);
                _final(t, st, st == Status.INSUFFICIENT_COVERAGE ? Reason.BASE_COVERAGE : re, at, 0, false, 0, 0);
            }
            return;
        }
        if (!_hasValid) return _final(t, Status.UNAVAILABLE, Reason.NO_BASE, at, 0, false, 0, 0);
        if (acc == 0 || _weightOf(acc) * 10000 < minCoverageBp * totalWeight) {
            (Status st, Reason re) = _nonvalid(t);
            return _final(t, st, re, at, 0, false, 0, 0);
        }
        uint256 s = _lastValid;
        (uint256 level, uint256 matched) = _link(_records[s].level, s, t);
        if (matched == 0) return _final(t, Status.INSUFFICIENT_COVERAGE, Reason.NO_MATCHED_MARKET, at, 0, false, 0, 0);
        _breaker(t, at, s, level, matched);
    }

    /// @dev The newest candidate held by the circuit breaker, and the level at t linked from it.
    struct Held {
        bool confirms;
        uint256 period;
        uint256 candidate;
        uint256 level;
        uint256 matched;
    }

    /// @dev §9: accept a linked level within the breaker of I_s, or let it confirm a held candidate, or hold it.
    function _breaker(uint256 t, uint256 at, uint256 s, uint256 level, uint256 matched) private {
        uint256 levelS = _records[s].level;
        bool okRef = !hasCircuitBreaker || GCPIMath.within(levelS, level, circuitBreakerBp, t - s);
        uint256 n = _pend.length;
        Held memory h;
        if (n > 0) {
            h.period = _pend[n - 1];
            h.candidate = _records[h.period].candidate;
            (h.level, h.matched) = _link(h.candidate, h.period, t);
            h.confirms = h.matched != 0 && GCPIMath.within(h.candidate, h.level, _bands[0], t - h.period);
        }
        if (h.confirms && (!okRef || GCPIMath.closer(h.level, h.candidate, levelS))) {
            // The newest held candidate is confirmed; the older ones were not.
            for (uint256 i = 0; i + 1 < n; i++) {
                _resolve(_pend[i], Status.INVALID_INPUT, Reason.CIRCUIT_BREAKER_REJECTED, 0, at);
            }
            _resolve(h.period, Status.VALID, Reason.CONFIRMED, h.candidate, at);
            delete _pend;
            _final(t, Status.VALID, Reason.LINKED, at, h.level, true, h.period, h.matched);
            _lastValid = t;
        } else if (okRef) {
            for (uint256 i = 0; i < n; i++) {
                _resolve(_pend[i], Status.INVALID_INPUT, Reason.CIRCUIT_BREAKER_REJECTED, 0, at);
            }
            delete _pend;
            _final(t, Status.VALID, Reason.LINKED, at, level, true, s, matched);
            _lastValid = t;
        } else {
            _pend.push(uint32(t));
            Record storage r = _records[t];
            (r.status, r.reason, r.candidate) = (Status.PENDING_CONFIRMATION, Reason.CIRCUIT_BREAKER, level);
            (r.hasLink, r.linkedFrom, r.matched) = (true, uint32(s), matched);
        }
    }

    /// @dev Level at t chained from s by the weighted mean log relative of the markets accepted in both.
    function _link(uint256 levelS, uint256 s, uint256 t) private view returns (uint256 level, uint256 matched) {
        matched = accepted(s) & accepted(t);
        if (matched == 0) return (0, 0);
        int256 num;
        uint256 den;
        for (uint256 k = 0; k < _markets.length; k++) {
            if (matched & (1 << k) == 0) continue;
            uint256 x = _decisions[k][t].price * GCPIMath.S / _decisions[k][s].price;
            num += int256(_weights[k]) * GCPIMath.ln(x);
            den += _weights[k];
        }
        level = GCPIMath.mulHdiv(levelS, GCPIMath.exp(num / int256(den)), GCPIMath.S);
    }

    function _nonvalid(uint256 t) private view returns (Status, Reason) {
        bool[8] memory seen;
        bool allAbsent = true;
        for (uint256 k = 0; k < _markets.length; k++) {
            Decision d = _decisions[k][t].decision;
            seen[uint8(d)] = true;
            if (d != Decision.ABSENT) allAbsent = false;
        }
        if (seen[uint8(Decision.PENDING)]) return (Status.PENDING_CONFIRMATION, Reason.MARKET_PENDING);
        if (seen[uint8(Decision.INVALID)]) return (Status.INVALID_INPUT, Reason.MARKET_INVALID);
        if (seen[uint8(Decision.DISPUTED)]) return (Status.INVALID_INPUT, Reason.MARKET_DISPUTED);
        if (seen[uint8(Decision.REJECTED_ANOMALY)]) return (Status.INVALID_INPUT, Reason.MARKET_REJECTED);
        if (seen[uint8(Decision.STALE)]) return (Status.STALE, Reason.MARKET_STALE);
        if (allAbsent) return (Status.UNAVAILABLE, Reason.NO_OBSERVATIONS);
        return (Status.INSUFFICIENT_COVERAGE, Reason.COVERAGE);
    }

    function _weightOf(uint256 mask) private view returns (uint256 w) {
        for (uint256 k = 0; k < _markets.length; k++) {
            if (mask & (1 << k) != 0) w += _weights[k];
        }
    }

    function _final(
        uint256 t,
        Status status,
        Reason reason,
        uint256 at,
        uint256 level,
        bool hasLink,
        uint256 linkedFrom,
        uint256 matched
    ) private {
        _records[t] = Record(status, reason, level, 0, hasLink, uint32(linkedFrom), matched, true, uint32(at));
        registry.publish(t, status, level, inputCommitment[t]);
    }

    /// @dev A candidate held by the circuit breaker is confirmed or rejected; its link and matched set stay.
    function _resolve(uint256 q, Status status, Reason reason, uint256 level, uint256 at) private {
        Record storage r = _records[q];
        (r.status, r.reason, r.level) = (status, reason, level);
        (r.candidate, r.decided, r.decidedAt) = (0, true, uint32(at));
        registry.publish(q, status, level, inputCommitment[q]);
    }

    // ---------------------------------------------------------------------------------------------------
    // The methodology (engine.py check_methodology), and its canonical JSON for methodology_hash.

    function _checkMethodology(Methodology memory m) private pure {
        if (!GCPIMath.isId(m.id)) revert Malformed("methodology_id");
        if (m.markets.length == 0 || m.markets.length != m.weights.length || m.markets.length > MAX_MARKETS) {
            revert Malformed("markets");
        }
        for (uint256 i = 0; i < m.markets.length; i++) {
            // On-chain bound: keeps Σ weight × price far below 2²⁵⁶.
            if (!GCPIMath.isId(m.markets[i]) || m.weights[i] == 0 || m.weights[i] > type(uint64).max) {
                revert Malformed("market_weight");
            }
            if (i > 0 && !GCPIMath.lessThan(m.markets[i - 1], m.markets[i])) revert Malformed("markets");
        }
        if (m.markets.length + m.signals.length > MAX_SERIES) revert Malformed("signals");
        for (uint256 i = 0; i < m.signals.length; i++) {
            if (!GCPIMath.isId(m.signals[i]) || _contains(m.markets, m.signals[i], m.markets.length)) {
                revert Malformed("signals");
            }
            if (_contains(m.signals, m.signals[i], i)) revert Malformed("signals");
        }
        if (m.corroborated.length != m.corroborators.length) revert Malformed("corroborators");
        for (uint256 i = 0; i < m.corroborated.length; i++) {
            string memory k = m.corroborated[i];
            if (!_contains(m.markets, k, m.markets.length)) revert Malformed("corroborators");
            if (i > 0 && !GCPIMath.lessThan(m.corroborated[i - 1], k)) revert Malformed("corroborators");
            string[] memory cs = m.corroborators[i];
            for (uint256 j = 0; j < cs.length; j++) {
                bool known =
                    _contains(m.markets, cs[j], m.markets.length) || _contains(m.signals, cs[j], m.signals.length);
                if (!known || _eq(cs[j], k) || _contains(cs, cs[j], j)) revert Malformed("corroborators");
            }
        }
        if (m.minCoverageBp > 10000) revert Malformed("min_coverage_bp");
        if (m.maxPublicationLagDays > 36500) revert Malformed("max_publication_lag_days");
        uint256[3] memory b = m.bandsBp;
        if (m.hasBands ? !(0 < b[0] && b[0] < b[1] && b[1] < b[2] && b[2] <= 1e6) : (b[0] | b[1] | b[2]) != 0) {
            revert Malformed("bands_bp");
        }
        bool cbOk = m.hasCircuitBreaker
            ? m.circuitBreakerBp > 0 && m.circuitBreakerBp <= 1e6 && m.hasBands
            : m.circuitBreakerBp == 0;
        if (!cbOk) revert Malformed("circuit_breaker_bp");
        (bool ok,) = GCPIMath.parsePeriod(m.basePeriod);
        if (!ok) revert Malformed("base_period");
    }

    function _canonicalMethodology(Methodology memory m) private pure returns (string memory) {
        string memory bands = m.hasBands
            ? string.concat("[", _q(m.bandsBp[0]), ",", _q(m.bandsBp[1]), ",", _q(m.bandsBp[2]), "]")
            : "null";
        string memory corr = "{";
        for (uint256 i = 0; i < m.corroborated.length; i++) {
            corr = string.concat(corr, i > 0 ? "," : "", '"', m.corroborated[i], '":', _list(m.corroborators[i]));
        }
        string memory mk = "{";
        for (uint256 i = 0; i < m.markets.length; i++) {
            mk = string.concat(mk, i > 0 ? "," : "", '"', m.markets[i], '":', _q(m.weights[i]));
        }
        string memory head = string.concat(
            '{"bands_bp":',
            bands,
            ',"base_period":"',
            m.basePeriod,
            '","circuit_breaker_bp":',
            m.hasCircuitBreaker ? _q(m.circuitBreakerBp) : "null",
            ',"corroborators":',
            corr,
            "}"
        );
        return string.concat(
            head,
            ',"id":"',
            m.id,
            '","markets":',
            mk,
            '},"max_publication_lag_days":',
            _q(m.maxPublicationLagDays),
            ',"min_coverage_bp":',
            _q(m.minCoverageBp),
            ',"signals":',
            _list(m.signals),
            "}"
        );
    }

    function _q(uint256 v) private pure returns (string memory) {
        return string.concat('"', Strings.toString(v), '"');
    }

    function _list(string[] memory xs) private pure returns (string memory out) {
        out = "[";
        for (uint256 i = 0; i < xs.length; i++) {
            out = string.concat(out, i > 0 ? ',"' : '"', xs[i], '"');
        }
        out = string.concat(out, "]");
    }

    function _contains(string[] memory xs, string memory x, uint256 upTo) private pure returns (bool) {
        for (uint256 i = 0; i < upTo; i++) {
            if (_eq(xs[i], x)) return true;
        }
        return false;
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _marketIndex(string[] memory ms, string memory x) private pure returns (uint256) {
        for (uint256 i = 0; i < ms.length; i++) {
            if (_eq(ms[i], x)) return i;
        }
        revert Malformed("corroborators");
    }

    function _seriesIndex(Methodology memory m, string memory x) private pure returns (uint256) {
        for (uint256 i = 0; i < m.markets.length; i++) {
            if (_eq(m.markets[i], x)) return i;
        }
        for (uint256 i = 0; i < m.signals.length; i++) {
            if (_eq(m.signals[i], x)) return m.markets.length + i;
        }
        revert Malformed("corroborators");
    }
}

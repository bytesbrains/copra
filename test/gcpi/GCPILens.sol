// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Strings.sol";
import "../../src/gcpi/GCPIEngine.sol";

/**
 * @notice Test helper: the reference engine's canonical output (gcpi/ENGINE.md §6–§7), rebuilt from an
 *         on-chain GCPIEngine's state. Its SHA-256 equal to a vector's `expected_sha256` is the byte-for-byte
 *         parity #92 asks for.
 */
library GCPILens {
    function canonical(GCPIEngine e, uint256 last) internal view returns (string memory out) {
        out = string.concat(
            '{"engine":"GCPI-ENGINE-v1","methodology":"',
            e.methodologyId(),
            '","methodology_hash":"',
            GCPIMath.hex32(e.methodologyHash()),
            '","periods":['
        );
        string[] memory names = e.markets();
        for (uint256 t = e.basePeriod(); t <= last; t++) {
            out = string.concat(out, t > e.basePeriod() ? "," : "", _period(e, names, t));
        }
        out = string.concat(out, "]}");
    }

    function _period(GCPIEngine e, string[] memory names, uint256 t) private view returns (string memory) {
        GCPIEngine.Record memory r = e.record(t);
        uint256 acc = e.accepted(t);
        bool comparable = r.status == Status.VALID && r.hasLink && r.linkedFrom + 1 == t && r.matched == acc
            && acc == e.accepted(r.linkedFrom);
        string memory head = string.concat(
            '{"accepted":',
            _names(names, acc),
            ',"candidate":',
            r.candidate != 0 ? _q(r.candidate) : "null",
            ',"comparable":',
            comparable ? "true" : "false",
            ',"coverage_bp":',
            _q(_weightOf(e, acc) * 10000 / e.totalWeight()),
            ',"decided_at":',
            r.decided ? _qs(GCPIMath.periodName(r.decidedAt)) : "null",
            ',"input_commitment":',
            _qs(GCPIMath.hex32(e.inputCommitment(t)))
        );
        string memory mid = string.concat(
            ',"level":',
            r.status == Status.VALID ? _q(r.level) : "null",
            ',"linked_from":',
            r.hasLink ? _qs(GCPIMath.periodName(r.linkedFrom)) : "null",
            ',"markets":',
            _markets(e, names, t)
        );
        return string.concat(
            head,
            mid,
            ',"matched":',
            _names(names, r.matched),
            ',"period":',
            _qs(GCPIMath.periodName(t)),
            ',"reason":',
            _qs(reasonName(r.reason)),
            ',"status":',
            _qs(statusName(r.status)),
            "}"
        );
    }

    function _markets(GCPIEngine e, string[] memory names, uint256 t) private view returns (string memory out) {
        out = "{";
        for (uint256 k = 0; k < names.length; k++) {
            GCPIEngine.MarketDecision memory d = e.decision(k, t);
            out = string.concat(
                out,
                k > 0 ? "," : "",
                _qs(names[k]),
                ':{"band":',
                d.band == Band.NONE ? "null" : _qs(bandName(d.band)),
                ',"decided_at":',
                d.decided ? _qs(GCPIMath.periodName(d.decidedAt)) : "null",
                ',"decision":',
                _qs(decisionName(d.decision)),
                ',"observations":',
                _commitments(e.verifier().commitments(k, t)),
                ',"price":',
                d.price != 0 ? _q(d.price) : "null",
                "}"
            );
        }
        out = string.concat(out, "}");
    }

    function _commitments(bytes32[] memory cs) private pure returns (string memory out) {
        for (uint256 i = 1; i < cs.length; i++) {
            bytes32 v = cs[i];
            uint256 j = i;
            while (j > 0 && cs[j - 1] > v) {
                cs[j] = cs[j - 1];
                j--;
            }
            cs[j] = v;
        }
        out = "[";
        for (uint256 i = 0; i < cs.length; i++) {
            out = string.concat(out, i > 0 ? "," : "", _qs(GCPIMath.hex32(cs[i])));
        }
        out = string.concat(out, "]");
    }

    function _names(string[] memory names, uint256 mask) private pure returns (string memory out) {
        out = "[";
        bool any;
        for (uint256 k = 0; k < names.length; k++) {
            if (mask & (1 << k) == 0) continue;
            out = string.concat(out, any ? "," : "", _qs(names[k]));
            any = true;
        }
        out = string.concat(out, "]");
    }

    function _weightOf(GCPIEngine e, uint256 mask) private view returns (uint256 w) {
        uint256[] memory ws = e.weights();
        for (uint256 k = 0; k < ws.length; k++) {
            if (mask & (1 << k) != 0) w += ws[k];
        }
    }

    function _q(uint256 v) private pure returns (string memory) {
        return _qs(Strings.toString(v));
    }

    function _qs(string memory s) private pure returns (string memory) {
        return string.concat('"', s, '"');
    }

    function statusName(Status s) internal pure returns (string memory) {
        string[7] memory n =
            ["NONE", "VALID", "PENDING_CONFIRMATION", "INSUFFICIENT_COVERAGE", "STALE", "INVALID_INPUT", "UNAVAILABLE"];
        return n[uint8(s)];
    }

    function reasonName(Reason r) internal pure returns (string memory) {
        string[17] memory n = [
            "",
            "base",
            "base_coverage",
            "linked",
            "confirmed",
            "circuit_breaker",
            "circuit_breaker_rejected",
            "market_pending",
            "earlier_period_pending",
            "market_invalid",
            "market_disputed",
            "market_rejected",
            "market_stale",
            "no_observations",
            "coverage",
            "no_base",
            "no_matched_market"
        ];
        return n[uint8(r)];
    }

    function decisionName(Decision d) internal pure returns (string memory) {
        string[8] memory n = ["", "ABSENT", "ACCEPTED", "PENDING", "REJECTED_ANOMALY", "INVALID", "DISPUTED", "STALE"];
        return n[uint8(d)];
    }

    function bandName(Band b) internal pure returns (string memory) {
        string[6] memory n = ["", "first", "normal", "corroborate", "confirm", "quarantine"];
        return n[uint8(b)];
    }
}

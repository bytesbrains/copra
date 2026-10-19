// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./GCPITypes.sol";

/**
 * @title GCPIMath
 * @notice The reference engine's arithmetic and encoding (gcpi/ENGINE.md §2, §3, §7), ported line by line from
 *         gcpi/engine/engine.py. Every function here must give the engine's exact integer for the same input:
 *         test/gcpi/GCPIVectors.t.sol checks that on every published vector, and GCPIMath.t.sol on the ln/exp table.
 */
library GCPIMath {
    uint256 internal constant WAD = 1e18; // output scale: prices and levels in 1e-18 USD/kg
    uint256 internal constant S = 1e36; // internal scale of ln and exp
    int256 internal constant LN2 = 693147180559945309417232121458176568; // ln 2 at scale S, truncated
    uint256 internal constant P_MIN = 1e12; // normalized price bounds: 1e-6 to 1e6 USD/kg
    uint256 internal constant P_MAX = 1e24;
    uint256 internal constant MAX_MANTISSA = 1e30;
    uint256 internal constant MAX_EXP = 18;
    uint256 internal constant SECONDS_PER_DAY = 86400;

    /// @dev How an observation normalizes: usable, usable but late, or not usable (gcpi/ENGINE.md §3).
    uint8 internal constant NORM_OK = 0;
    uint8 internal constant NORM_STALE = 1;
    uint8 internal constant NORM_INVALID = 2;

    // ---------------------------------------------------------------------------------------------------
    // Integer helpers. Solidity's `/` on int256 already rounds toward zero, the engine's tdiv.

    /// @dev Division of non-negative integers, rounded half up.
    function hdiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (2 * a + b) / (2 * b);
    }

    /// @dev hdiv(a * b, d) without overflow in a * b: floor, then one up if the remainder is at least half.
    function mulHdiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        uint256 q = Math.mulDiv(a, b, d);
        return 2 * mulmod(a, b, d) >= d ? q + 1 : q;
    }

    /// @notice Natural log of x / S, at scale S. x > 0.
    function ln(uint256 x) internal pure returns (int256) {
        int256 k = 0;
        while (x >= 2 * S) {
            x /= 2;
            k += 1;
        }
        while (x < S) {
            x *= 2;
            k -= 1;
        }
        uint256 z = (x - S) * S / (x + S);
        uint256 z2 = z * z / S;
        uint256 total = z;
        uint256 power = z;
        uint256 n = 1;
        while (true) {
            power = power * z2 / S;
            n += 2;
            uint256 term = power / n;
            if (term == 0) break;
            total += term;
        }
        return 2 * int256(total) + k * LN2;
    }

    /// @notice e^(m / S), at scale S. m may be negative.
    function exp(int256 m) internal pure returns (uint256) {
        int256 k = m / LN2;
        int256 r = m - k * LN2;
        int256 sIn = int256(S);
        int256 total = sIn;
        int256 term = sIn;
        int256 n = 0;
        while (true) {
            n += 1;
            term = term * r / (n * sIn);
            if (term == 0) break;
            total += term;
        }
        // total lies in (S/2, 2S), so it is positive and the shift is the engine's.
        return k >= 0 ? uint256(total) << uint256(k) : uint256(total) >> uint256(-k);
    }

    // ---------------------------------------------------------------------------------------------------
    // Bands. thr in basis points; thresholds scale by the square root of the periods elapsed, k.

    /// @notice |pNew / pRef - 1| <= thr / 10000 × √k, exactly: (|Δ| × 10⁴)² <= thr² × k × pRef², in 512 bits.
    function within(uint256 pRef, uint256 pNew, uint256 thr, uint256 k) internal pure returns (bool) {
        uint256 d = (pNew > pRef ? pNew - pRef : pRef - pNew) * 10000;
        (uint256 lh, uint256 ll) = Math.mul512(d, d);
        uint256 b = thr * pRef;
        (uint256 bh, uint256 bl) = Math.mul512(b, b);
        (uint256 carry, uint256 rl) = Math.mul512(bl, k);
        uint256 rh = bh * k + carry;
        return lh < rh || (lh == rh && ll <= rl);
    }

    /// @notice True if v is relatively closer to a than to b: |v - a| × b < |v - b| × a, exactly. A tie is false.
    function closer(uint256 v, uint256 a, uint256 b) internal pure returns (bool) {
        (uint256 lh, uint256 ll) = Math.mul512(v > a ? v - a : a - v, b);
        (uint256 rh, uint256 rl) = Math.mul512(v > b ? v - b : b - v, a);
        return lh < rh || (lh == rh && ll < rl);
    }

    function band(uint256 pRef, uint256 pNew, uint256[3] memory bands, uint256 k) internal pure returns (Band) {
        if (within(pRef, pNew, bands[0], k)) return Band.NORMAL;
        if (within(pRef, pNew, bands[1], k)) return Band.CORROBORATE;
        if (within(pRef, pNew, bands[2], k)) return Band.CONFIRM;
        return Band.QUARANTINE;
    }

    // ---------------------------------------------------------------------------------------------------
    // Calendar. A period is a calendar month in UTC, numbered year × 12 + month − 1 (gcpi/ENGINE.md).

    /// @notice Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm), with floor division.
    function daysFromCivil(int256 y, int256 m, int256 d) internal pure returns (int256) {
        if (m <= 2) y -= 1;
        int256 era = (y >= 0 ? y : y - 399) / 400;
        int256 yoe = y - era * 400;
        int256 doy = (153 * (m + (m > 2 ? int256(-3) : int256(9))) + 2) / 5 + d - 1;
        int256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    /// @notice Unix seconds of the first instant of period t, UTC. Negative before 1970.
    function periodStart(uint256 t) internal pure returns (int256) {
        return daysFromCivil(int256(t / 12), int256(t % 12 + 1), 1) * int256(SECONDS_PER_DAY);
    }

    /// @notice "YYYY-MM" to its period number, or ok = false if it is not exactly that form.
    function parsePeriod(string memory s) internal pure returns (bool ok, uint256 t) {
        bytes memory b = bytes(s);
        if (b.length != 7 || b[4] != "-") return (false, 0);
        uint256 y;
        for (uint256 i = 0; i < 4; i++) {
            if (b[i] < "0" || b[i] > "9") return (false, 0);
            y = y * 10 + (uint8(b[i]) - 48);
        }
        if (b[5] < "0" || b[5] > "1" || b[6] < "0" || b[6] > "9") return (false, 0);
        uint256 m = (uint8(b[5]) - 48) * 10 + (uint8(b[6]) - 48);
        if (m < 1 || m > 12) return (false, 0);
        return (true, y * 12 + m - 1);
    }

    function periodName(uint256 t) internal pure returns (string memory) {
        uint256 y = t / 12;
        uint256 m = t % 12 + 1;
        bytes memory b = new bytes(7);
        b[0] = bytes1(uint8(48 + (y / 1000) % 10));
        b[1] = bytes1(uint8(48 + (y / 100) % 10));
        b[2] = bytes1(uint8(48 + (y / 10) % 10));
        b[3] = bytes1(uint8(48 + y % 10));
        b[4] = "-";
        b[5] = bytes1(uint8(48 + m / 10));
        b[6] = bytes1(uint8(48 + m % 10));
        return string(b);
    }

    // ---------------------------------------------------------------------------------------------------
    // Identifiers.

    /// @notice The engine's ID pattern: 1 to 64 of [A-Za-z0-9_.-].
    function isId(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length == 0 || b.length > 64) return false;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            bool ok = (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_" || c == "."
                || c == "-";
            if (!ok) return false;
        }
        return true;
    }

    /// @notice An ISO 4217 code: exactly three of [A-Z].
    function isCurrency(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length != 3) return false;
        for (uint256 i = 0; i < 3; i++) {
            if (b[i] < "A" || b[i] > "Z") return false;
        }
        return true;
    }

    /// @dev Strict byte order, as Python sorts ASCII strings.
    function lessThan(string memory a, string memory b) internal pure returns (bool) {
        bytes memory x = bytes(a);
        bytes memory y = bytes(b);
        uint256 n = x.length < y.length ? x.length : y.length;
        for (uint256 i = 0; i < n; i++) {
            if (x[i] != y[i]) return x[i] < y[i];
        }
        return x.length < y.length;
    }

    // ---------------------------------------------------------------------------------------------------
    // Encoding (gcpi/ENGINE.md §7).

    /// @dev A string as the commitment encodes it: uint32 big-endian length, then its bytes.
    function str(string memory s) internal pure returns (bytes memory) {
        return abi.encodePacked(uint32(bytes(s).length), s);
    }

    /// @notice Lowercase hex of 32 bytes, without a prefix.
    function hex32(bytes32 v) internal pure returns (string memory) {
        bytes memory digits = "0123456789abcdef";
        bytes memory out = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            out[2 * i] = digits[uint8(v[i]) >> 4];
            out[2 * i + 1] = digits[uint8(v[i]) & 15];
        }
        return string(out);
    }

    /// @notice SHA-256 of "GCPI-OBS-v1" and the fields in order: strings length-prefixed, integers as 32 bytes,
    ///         an absent fx or fx_exp as the empty string, and `record` as its 64-character hex string.
    function commitment(Observation memory o) internal pure returns (bytes32) {
        bytes memory head = abi.encodePacked(
            str("GCPI-OBS-v1"), str(o.market), str(o.period), str(o.source), o.price, o.priceExp, str(o.currency)
        );
        bytes memory fx = o.hasFx ? abi.encodePacked(o.fx, o.fxExp) : abi.encodePacked(str(""), str(""));
        bytes memory tail = abi.encodePacked(str(o.fxSource), o.published, str(hex32(o.record)), str(o.basis));
        return sha256(abi.encodePacked(head, str(o.unit), fx, tail));
    }

    // ---------------------------------------------------------------------------------------------------
    // Normalization (gcpi/ENGINE.md §3).

    function unitKg(string memory unit) internal pure returns (uint256) {
        bytes32 h = keccak256(bytes(unit));
        if (h == keccak256("kg")) return 1;
        if (h == keccak256("quintal")) return 100;
        if (h == keccak256("t")) return 1000;
        return 0;
    }

    /// @notice USD/kg at WAD and how the observation counts: NORM_OK, NORM_STALE (late, price kept) or NORM_INVALID.
    function normalize(Observation memory o, uint256 t, uint256 lagDays) internal pure returns (uint256 p, uint8 how) {
        uint256 kg = unitKg(o.unit);
        if (kg == 0) return (0, NORM_INVALID);
        if (o.price == 0 || o.price >= MAX_MANTISSA || o.priceExp > MAX_EXP) return (0, NORM_INVALID);
        uint256 fx = 1;
        uint256 fexp = 0;
        if (keccak256(bytes(o.currency)) == keccak256("USD")) {
            if (o.hasFx) return (0, NORM_INVALID);
        } else {
            if (!o.hasFx) return (0, NORM_INVALID);
            if (o.fx == 0 || o.fx >= MAX_MANTISSA || o.fxExp > MAX_EXP) return (0, NORM_INVALID);
            (fx, fexp) = (o.fx, o.fxExp);
        }
        p = hdiv(o.price * WAD * 10 ** fexp, 10 ** o.priceExp * kg * fx);
        if (p < P_MIN || p > P_MAX) return (0, NORM_INVALID);
        // Compared without casting `published`, which can be any uint256 in an observation offered as slashing evidence.
        int256 start = periodStart(t);
        if (start > 0 && o.published < uint256(start)) return (0, NORM_INVALID);
        int256 deadline = periodStart(t + 1) + int256(lagDays * SECONDS_PER_DAY);
        if (deadline < 0 || o.published > uint256(deadline)) return (p, NORM_STALE);
        return (p, NORM_OK);
    }
}

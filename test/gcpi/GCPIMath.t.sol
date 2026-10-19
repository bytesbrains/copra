// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/gcpi/GCPIMath.sol";

/**
 * @notice GCPIMath against the reference engine's ln/exp table (gcpi/engine/vectors/arithmetic.json), and property
 *         tests for the parts that differ from engine.py in mechanism but must not in result: 512-bit comparisons
 *         where Python has unbounded integers, mulDiv where it multiplies first, and the calendar.
 */
contract GCPIMathTest is Test {
    function test_LnAndExpMatchTheArithmeticVector() public view {
        string memory json = vm.readFile("gcpi/engine/vectors/arithmetic.json");
        uint256 n;
        for (; vm.keyExistsJson(json, string.concat(".ln[", vm.toString(n), "]")); n++) {
            string[] memory pair = vm.parseJsonStringArray(json, string.concat(".ln[", vm.toString(n), "]"));
            assertEq(GCPIMath.ln(vm.parseUint(pair[0])), vm.parseInt(pair[1]), pair[0]);
        }
        uint256 m;
        for (; vm.keyExistsJson(json, string.concat(".exp[", vm.toString(m), "]")); m++) {
            string[] memory pair = vm.parseJsonStringArray(json, string.concat(".exp[", vm.toString(m), "]"));
            assertEq(GCPIMath.exp(vm.parseInt(pair[0])), vm.parseUint(pair[1]), pair[0]);
        }
        assertGt(n, 10);
        assertGt(m, 10);
    }

    function test_Ln2IsTheEnginesConstant() public pure {
        assertEq(GCPIMath.ln(2 * GCPIMath.S), GCPIMath.LN2);
        assertEq(GCPIMath.ln(GCPIMath.S), 0);
        assertEq(GCPIMath.exp(0), GCPIMath.S);
    }

    /// @dev Over the engine's price bounds, exp(ln(x)) returns x to well within the output scale.
    function testFuzz_ExpUndoesLn(uint256 x) public pure {
        x = bound(x, GCPIMath.S / 1e12, GCPIMath.S * 1e12);
        uint256 y = GCPIMath.exp(GCPIMath.ln(x));
        uint256 err = y > x ? y - x : x - y;
        assertLe(err * 1e18, x, "relative error below 1e-18");
    }

    function testFuzz_WithinMatchesTheDirectFormulaWhereItFits(uint64 pRef, uint64 pNew, uint16 thr, uint8 k)
        public
        pure
    {
        vm.assume(pRef > 0 && k > 0);
        uint256 d = (pNew > pRef ? uint256(pNew) - pRef : uint256(pRef) - pNew) * 10000;
        // Both sides fit in 256 bits here, so the engine's own formula is the reference.
        bool direct = d * d <= uint256(thr) * thr * k * pRef * pRef;
        assertEq(GCPIMath.within(pRef, pNew, thr, k), direct);
    }

    function test_WithinDoesNotOverflowAtLevelsPythonAccepts() public pure {
        // A level of 1e36 wei/kg: (Δ × 10⁴)² is about 1e80, past 2²⁵⁶. Python's unbounded integers decide it; so must we.
        assertTrue(GCPIMath.within(1e36, 1.1e36, 1000, 1));
        assertFalse(GCPIMath.within(1e36, 1.1e36 + 1, 1000, 1));
    }

    function testFuzz_CloserMatchesTheDirectFormula(uint120 v, uint120 a, uint120 b) public pure {
        uint256 l = (v > a ? uint256(v) - a : uint256(a) - v) * b;
        uint256 r = (v > b ? uint256(v) - b : uint256(b) - v) * a;
        assertEq(GCPIMath.closer(v, a, b), l < r);
    }

    function test_ACloserTieIsFalse() public pure {
        // 12 is 2/10 from 10 and 3/15 from 15: a tie, which goes to the reference (gcpi/ENGINE.md §5).
        assertFalse(GCPIMath.closer(12, 10, 15));
        assertFalse(GCPIMath.closer(12, 15, 10));
        assertTrue(GCPIMath.closer(12, 11, 15));
    }

    function testFuzz_MulHdivIsHdivOfTheProduct(uint120 a, uint120 b, uint120 d) public pure {
        vm.assume(d > 0);
        assertEq(GCPIMath.mulHdiv(a, b, d), GCPIMath.hdiv(uint256(a) * b, d));
    }

    function test_HalfRoundsUp() public pure {
        assertEq(GCPIMath.hdiv(5, 2), 3);
        assertEq(GCPIMath.hdiv(4, 3), 1);
        assertEq(GCPIMath.hdiv(5, 3), 2);
        assertEq(GCPIMath.mulHdiv(5, 1, 2), 3);
    }

    function test_PeriodStartIsUtcMidnight() public pure {
        (, uint256 t) = GCPIMath.parsePeriod("2020-03");
        assertEq(GCPIMath.periodStart(t), 1583020800); // 2020-03-01T00:00:00Z
        (, t) = GCPIMath.parsePeriod("1970-01");
        assertEq(GCPIMath.periodStart(t), 0);
        (, t) = GCPIMath.parsePeriod("1969-12");
        assertEq(GCPIMath.periodStart(t), -31 days);
        (, t) = GCPIMath.parsePeriod("2000-03");
        assertEq(GCPIMath.periodStart(t), 951868800); // after a 400-year leap day
    }

    function testFuzz_PeriodsAreConsecutiveMonths(uint32 t) public pure {
        t = uint32(bound(t, 0, 9999 * 12 + 10));
        int256 len = GCPIMath.periodStart(t + 1) - GCPIMath.periodStart(t);
        assertGe(len, 28 days);
        assertLe(len, 31 days);
        (bool ok, uint256 back) = GCPIMath.parsePeriod(GCPIMath.periodName(t));
        assertTrue(ok);
        assertEq(back, t);
    }

    function test_ParsePeriodIsExact() public pure {
        string[8] memory bad = ["2020-13", "2020-00", "2020-1", "20201-01", "2020/01", "2020-01\n", "", "abcd-ef"];
        for (uint256 i = 0; i < bad.length; i++) {
            (bool ok,) = GCPIMath.parsePeriod(bad[i]);
            assertFalse(ok, bad[i]);
        }
    }

    function test_IdentifiersMatchTheEnginePattern() public pure {
        assertTrue(GCPIMath.isId("COCONUT_OIL"));
        assertTrue(GCPIMath.isId("psa-farmgate.copra_1"));
        assertFalse(GCPIMath.isId(""));
        assertFalse(GCPIMath.isId("PH\n"));
        assertFalse(GCPIMath.isId("P H"));
        assertFalse(GCPIMath.isId(string(new bytes(65))));
        assertTrue(GCPIMath.isCurrency("PHP"));
        assertFalse(GCPIMath.isCurrency("php"));
        assertFalse(GCPIMath.isCurrency("USDT"));
    }
}

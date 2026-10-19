// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GCPIHarness.sol";

/**
 * @notice GCPIEngine and GCPIRegistry (GCPI-001 §8–§11, #92): permissionless and order-independent finalization,
 *         keeper and collector outages, colluding notaries, the incentive pool, the registry's write-once records,
 *         the methodology checks, and the absence of any privileged function.
 */
contract GCPIEngineTest is GCPIHarness {
    // ---------------------------------------------------------------------------------------------------
    // Permissionless, deterministic finalization (§10.3, Invariant 1).

    function test_FinalizeWaitsForTheWindowToClose() public {
        GCPIEngine e = deploy(v1(), "2020-01");
        uint256 closes = e.verifier().closesAt(periodOf("2020-01"));
        vm.warp(closes - 1);
        vm.expectRevert(abi.encodeWithSelector(GCPIEngine.NotClosed.selector, periodOf("2020-01"), closes));
        e.finalize();
        vm.warp(closes);
        assertEq(e.finalize(), periodOf("2020-01"));
    }

    function test_WhoFinalizesDoesNotMatter() public {
        Vector memory x = loadVector("genuine_shock");
        uint256 snap = vm.snapshotState();
        GCPIEngine a = deploy(x.m, x.first);
        replayWith(a, x.obs, x.last, address(0xA), 0);
        string memory first = outputSha(a, x.last);
        vm.revertToState(snap);
        GCPIEngine b = deploy(x.m, x.first);
        replayWith(b, x.obs, x.last, address(0xB), 0);
        assertEq(outputSha(b, x.last), first);
        assertEq(first, x.expectedSha);
    }

    /// @dev §14 "malicious transaction ordering": any submission order within a window gives the same result.
    function testFuzz_SubmissionOrderDoesNotMatter(uint256 seed) public {
        vm.assume(seed != 0);
        string[3] memory names = ["genuine_shock", "circuit_breaker", "disputed_and_duplicate"];
        for (uint256 i = 0; i < names.length; i++) {
            Vector memory x = loadVector(names[i]);
            uint256 snap = vm.snapshotState();
            GCPIEngine e = deploy(x.m, x.first);
            replayWith(e, x.obs, x.last, address(this), seed);
            assertEq(outputSha(e, x.last), x.expectedSha, names[i]);
            vm.revertToState(snap);
        }
    }

    /// @dev §14 "keeper outage": nobody finalizes for years. Nothing is published meanwhile, then the same records.
    function test_AKeeperOutagePublishesNothingThenTheSameRecords() public {
        Vector memory x = loadVector("circuit_breaker");
        GCPIEngine e = deploy(x.m, x.first);
        Observation[] memory obs = bySubmission(x.obs);
        for (uint256 i = 0; i < obs.length; i++) {
            if (submittableAt(obs[i]) > block.timestamp) vm.warp(submittableAt(obs[i]));
            submit(e.verifier(), obs[i]);
        }
        vm.warp(block.timestamp + 3 * 365 days);
        for (uint256 t = e.basePeriod(); t <= x.last; t++) {
            assertEq(uint8(e.registry().getRecord(t).status), uint8(Status.NONE), "no record before finalization");
        }
        for (uint256 t = e.firstPeriod(); t <= x.last; t++) {
            e.finalize();
        }
        catchUp(e);
        assertEq(outputSha(e, x.last), x.expectedSha);
    }

    /// @dev §14 "missing regional market", collector outage: no observation at all is UNAVAILABLE, never a price.
    function test_ACollectorOutageIsUnavailableNotAPrice() public {
        GCPIEngine e = deploy(v1(), "2020-01");
        Observation[] memory obs = new Observation[](4);
        (obs[0], obs[1]) = (obsOf("PH", "2020-01", 100), obsOf("ID", "2020-01", 80));
        (obs[2], obs[3]) = (obsOf("PH", "2020-02", 100), obsOf("ID", "2020-02", 80));
        replay(e, obs, periodOf("2020-03"));
        GCPIRegistry.PeriodRecord memory r = e.registry().getRecord(periodOf("2020-03"));
        assertEq(uint8(r.status), uint8(Status.UNAVAILABLE));
        assertEq(r.price, 0);
        assertEq(uint8(e.registry().getRecord(periodOf("2020-02")).status), uint8(Status.VALID));
    }

    /// @dev A market pending for 30 months releases 30 index periods at once: no call computes more than the cap.
    function test_ALongBacklogIsComputedInBoundedSteps() public {
        Vector memory x = loadVector("long_pending");
        GCPIEngine e = deploy(x.m, x.first);
        ObservationVerifier v = e.verifier();
        Observation[] memory obs = bySubmission(x.obs);
        uint256 next;
        uint256 most;
        for (uint256 t = e.firstPeriod(); t <= x.last; t++) {
            for (; next < obs.length && submittableAt(obs[next]) <= v.closesAt(t); next++) {
                if (submittableAt(obs[next]) > block.timestamp) vm.warp(submittableAt(obs[next]));
                submit(v, obs[next]);
            }
            vm.warp(v.closesAt(t));
            uint256 before = e.nextIndexPeriod();
            e.finalize();
            if (e.nextIndexPeriod() - before > most) most = e.nextIndexPeriod() - before;
        }
        assertEq(most, e.MAX_INDEX_PER_CALL(), "the confirming call stops at the cap");
        assertLt(e.nextIndexPeriod(), e.nextPeriod(), "a backlog is left");
        uint256 rest = e.advance();
        assertGt(rest, 0);
        assertEq(e.advance(), 0);
        assertEq(e.nextIndexPeriod(), e.nextPeriod());
        assertEq(outputSha(e, x.last), x.expectedSha);
    }

    // ---------------------------------------------------------------------------------------------------
    // Colluding notaries (§14, §5.3.2, §5.3.6 item 2).

    function _base(GCPIEngine e) private returns (Observation[] memory obs) {
        obs = new Observation[](6);
        (obs[0], obs[1]) = (obsOf("PH", "2020-01", 100), obsOf("ID", "2020-01", 80));
        (obs[2], obs[3]) = (obsOf("PH", "2020-02", 100), obsOf("ID", "2020-02", 80));
        (obs[4], obs[5]) = (obsOf("COCONUT_OIL", "2020-01", 100), obsOf("COCONUT_OIL", "2020-02", 100));
        replay(e, obs, periodOf("2020-02"));
    }

    function test_AColludingQuorumAgainstAnHonestOneMakesTheMarketMissing() public {
        GCPIEngine e = deploy(v1(), "2020-01");
        _base(e);
        ObservationVerifier v = e.verifier();
        vm.warp(uint256(GCPIMath.periodStart(periodOf("2020-04"))) + 2 days);
        submit(v, obsOf("ID", "2020-03", 81));
        submit(v, obsOf("PH", "2020-03", 101)); // honest, notaries 0 and 1
        Observation memory lie = obsOf("PH", "2020-03", 104);
        lie.source = "test-source-2";
        uint256[] memory colluders = new uint256[](2);
        (colluders[0], colluders[1]) = (1, 2);
        bytes[] memory sigs = attest(v, lie, colluders);
        vm.deal(submitter, SUBMIT_BOND);
        vm.prank(submitter);
        v.submit{value: SUBMIT_BOND}(lie, sigs);

        vm.warp(v.closesAt(periodOf("2020-03")));
        e.finalize();
        // No vote picks a winner: the market is DISPUTED and the period publishes no price (§5.3.2).
        assertEq(uint8(e.decision(1, periodOf("2020-03")).decision), uint8(Decision.DISPUTED));
        GCPIRegistry.PeriodRecord memory r = e.registry().getRecord(periodOf("2020-03"));
        assertEq(uint8(r.status), uint8(Status.INVALID_INPUT));
        assertEq(r.price, 0);
    }

    function test_AColludingQuorumAloneIsStillHeldByTheAnomalyRules() public {
        // k colluding notaries can attest any value (§5.3.6 item 2). A far-off one is quarantined, not published.
        GCPIEngine e = deploy(v1(), "2020-01");
        _base(e);
        ObservationVerifier v = e.verifier();
        vm.warp(uint256(GCPIMath.periodStart(periodOf("2020-04"))) + 2 days);
        submit(v, obsOf("ID", "2020-03", 81));
        submit(v, obsOf("COCONUT_OIL", "2020-03", 100));
        submit(v, obsOf("PH", "2020-03", 300));
        vm.warp(v.closesAt(periodOf("2020-03")));
        e.finalize();
        assertEq(uint8(e.decision(1, periodOf("2020-03")).decision), uint8(Decision.PENDING));
        assertEq(uint8(e.decision(1, periodOf("2020-03")).band), uint8(Band.QUARANTINE));
        assertEq(uint8(e.record(periodOf("2020-03")).status), uint8(Status.PENDING_CONFIRMATION));
        assertEq(uint8(e.registry().getRecord(periodOf("2020-03")).status), uint8(Status.NONE));
    }

    // ---------------------------------------------------------------------------------------------------
    // Execution incentive (§10.4).

    function test_AnEmptyPoolPaysNothingAndFinalizationStillWorks() public {
        GCPIEngine e = deploy(v1(), "2020-01");
        vm.warp(e.verifier().closesAt(periodOf("2020-01")));
        address keeper = address(0xCEE);
        vm.prank(keeper);
        e.finalize();
        assertEq(e.rewards(keeper), 0);
        vm.prank(keeper);
        vm.expectRevert(GCPIEngine.NothingToClaim.selector);
        e.claimReward();
    }

    function test_TheRewardIsBoundedAndThePoolCanRunDry() public {
        GCPIEngine e = deploy(v1(), "2020-01");
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(e).call{value: REWARD + REWARD / 2}("");
        assertTrue(ok);
        address keeper = address(0xCEE);
        uint256[3] memory want = [REWARD, REWARD / 2, 0];
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(e.verifier().closesAt(e.nextPeriod()));
            uint256 before = e.rewards(keeper);
            vm.prank(keeper);
            e.finalize();
            assertEq(e.rewards(keeper) - before, want[i]);
        }
        assertEq(e.rewardsOwed(), REWARD + REWARD / 2);
        vm.prank(keeper);
        e.claimReward();
        assertEq(keeper.balance, REWARD + REWARD / 2);
        assertEq(e.rewardsOwed(), 0);
        assertEq(address(e).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------------
    // Registry.

    function test_TheRegistryHoldsEveryFinalRecordAndOnlyThose() public {
        Vector memory x = loadVector("circuit_breaker");
        GCPIEngine e = deploy(x.m, x.first);
        replay(e, x.obs, x.last);
        GCPIRegistry reg = e.registry();
        assertEq(reg.engine(), address(e));
        assertEq(reg.methodologyHash(), e.methodologyHash());
        for (uint256 t = e.basePeriod(); t <= x.last; t++) {
            GCPIEngine.Record memory r = e.record(t);
            GCPIRegistry.PeriodRecord memory p = reg.getRecord(t);
            if (r.status == Status.PENDING_CONFIRMATION) {
                assertEq(uint8(p.status), uint8(Status.NONE));
                continue;
            }
            assertEq(uint8(p.status), uint8(r.status));
            assertEq(p.price, r.status == Status.VALID ? r.level : 0);
            assertEq(p.inputCommitment, e.inputCommitment(t));
            assertGt(p.finalizedAt, 0);
        }
    }

    function test_OnlyTheEngineWritesAndOnlyOnce() public {
        GCPIEngine e = deploy(v1(), "2020-01");
        GCPIRegistry reg = e.registry();
        vm.expectRevert(GCPIRegistry.OnlyEngine.selector);
        reg.publish(1, Status.VALID, 1, bytes32(0));
        vm.startPrank(address(e));
        vm.expectRevert(GCPIRegistry.NotFinal.selector);
        reg.publish(1, Status.PENDING_CONFIRMATION, 0, bytes32(0));
        reg.publish(1, Status.VALID, 1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(GCPIRegistry.AlreadyFinal.selector, 1));
        reg.publish(1, Status.INVALID_INPUT, 0, bytes32(0));
        vm.stopPrank();
    }

    function test_RegistryPeriodsStayInTheirRange() public {
        GCPIRegistry reg = deploy(v1(), "2020-01").registry();
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "period"));
        reg.periodStart(1969 * 12 + 11);
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "timestamp"));
        reg.periodOf(type(uint256).max);
        assertEq(reg.periodOf(253402300799), 9999 * 12 + 11);
        assertEq(reg.periodStart(1970 * 12), 0);
    }

    function testFuzz_PeriodOfInvertsPeriodStart(uint40 ts) public {
        ts = uint40(bound(ts, 0, 253399622399)); // through November 9999, so the next month is in range too
        GCPIRegistry reg = deploy(v1(), "2020-01").registry();
        uint256 t = reg.periodOf(ts);
        assertLe(reg.periodStart(t), ts);
        assertGt(reg.periodStart(t + 1), ts);
        assertEq(reg.idOf("2020-03"), 2020 * 12 + 2);
    }

    // ---------------------------------------------------------------------------------------------------
    // The methodology.

    function test_TheV1DraftHashesAsTheReferenceEngineDoes() public {
        GCPIEngine.Methodology memory m = methodologyAt(vm.readFile(V1_DRAFT), "");
        GCPIEngine e = deploy(m, "2016-01");
        // engine.py: sha256(canonical(gcpi-001-v1-draft.json))
        assertEq(
            GCPIMath.hex32(e.methodologyHash()), "0a7ac0a0eee32b6ca1b29432347e33e0d9d6a3b52f34537da1da1ad04d623e1d"
        );
        assertEq(e.methodologyId(), "GCPI-001-v1-draft");
    }

    function _expectMalformed(GCPIEngine.Methodology memory m, string memory code) private {
        ObservationVerifier v = deployVerifier(v1(), "2020-01");
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, code));
        new GCPIEngine(m, "2020-01", v, 0);
    }

    function test_TheMethodologyIsCheckedAsTheEngineChecksIt() public {
        GCPIEngine.Methodology memory m = v1();
        m.id = "GCPI test";
        _expectMalformed(m, "methodology_id");
        m = v1();
        m.weights[0] = 0;
        _expectMalformed(m, "market_weight");
        m = v1();
        (m.markets[0], m.markets[1]) = ("PH", "ID");
        _expectMalformed(m, "markets");
        m = v1();
        m.signals[0] = "PH";
        _expectMalformed(m, "signals");
        m = v1();
        m.corroborators[1][0] = "PH";
        _expectMalformed(m, "corroborators");
        m = v1();
        m.corroborators[0][0] = "XX";
        _expectMalformed(m, "corroborators");
        m = v1();
        m.minCoverageBp = 10001;
        _expectMalformed(m, "min_coverage_bp");
        m = v1();
        m.bandsBp = [uint256(1000), 1000, 4000];
        _expectMalformed(m, "bands_bp");
        m = v1();
        (m.hasBands, m.bandsBp) = (false, [uint256(0), 0, 0]);
        _expectMalformed(m, "circuit_breaker_bp");
        m = v1();
        m.basePeriod = "2020-2";
        _expectMalformed(m, "base_period");
        m = v1();
        m.basePeriod = "2019-12";
        _expectMalformed(m, "period_range");
    }

    function test_TheVerifierMustCollectExactlyThisMethodology() public {
        GCPIEngine.Methodology memory other = v1();
        other.maxPublicationLagDays = 60;
        ObservationVerifier v = deployVerifier(other, "2020-01");
        vm.expectRevert(GCPIEngine.VerifierMismatch.selector);
        new GCPIEngine(v1(), "2020-01", v, 0);
        v = deployVerifier(v1(), "2019-12");
        vm.expectRevert(GCPIEngine.VerifierMismatch.selector);
        new GCPIEngine(v1(), "2020-01", v, 0);
        other = v1();
        other.signals[0] = "PALM_OIL";
        v = deployVerifier(other, "2020-01");
        vm.expectRevert(GCPIEngine.VerifierMismatch.selector);
        new GCPIEngine(v1(), "2020-01", v, 0);
    }

    // ---------------------------------------------------------------------------------------------------
    // No privileged role (§10.2, Invariants 2 and 6).

    function _mutators(string memory artifact) private view returns (string[] memory names) {
        string memory json = vm.readFile(artifact);
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".abi[", vm.toString(n), "]"))) n++;
        names = new string[](n);
        uint256 m;
        for (uint256 i = 0; i < n; i++) {
            string memory p = string.concat(".abi[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".type")))) != keccak256("function")) {
                continue;
            }
            bytes32 mut = keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".stateMutability"))));
            if (mut == keccak256("view") || mut == keccak256("pure")) continue;
            names[m++] = vm.parseJsonString(json, string.concat(p, ".name"));
        }
        assembly {
            mstore(names, m)
        }
    }

    function _assertMutators(string memory artifact, string memory want) private view {
        string[] memory got = _mutators(artifact);
        string memory joined;
        for (uint256 i = 0; i < got.length; i++) {
            joined = string.concat(joined, i > 0 ? "," : "", got[i]);
        }
        assertEq(joined, want, artifact);
    }

    function test_TrustAssumption_NoContractHasAPrivilegedFunction() public view {
        // Every state-changing function of each contract, from its compiled ABI. None sets a price, a weight, a
        // source, a notary, a threshold or a window, and none upgrades, pauses or bypasses anything.
        _assertMutators("out/GCPIEngine.sol/GCPIEngine.json", "advance,claimReward,finalize");
        _assertMutators("out/GCPIRegistry.sol/GCPIRegistry.json", "publish"); // engine only, write-once
        _assertMutators(
            "out/ObservationVerifier.sol/ObservationVerifier.json",
            "beginUnbonding,bond,refundBond,slashEquivocation,slashPremature,submit,withdrawBond"
        );
    }

    // ---------------------------------------------------------------------------------------------------
    // Cost.

    function test_GasOfAV1Finalization() public {
        GCPIEngine e = deploy(v1(), "2020-01");
        Observation[] memory obs = _base(e);
        assertEq(obs.length, 6);
        ObservationVerifier v = e.verifier();
        vm.warp(uint256(GCPIMath.periodStart(periodOf("2020-04"))) + 2 days);
        uint256 g = gasleft();
        submit(v, obsOf("PH", "2020-03", 101));
        uint256 submitGas = g - gasleft();
        submit(v, obsOf("ID", "2020-03", 81));
        submit(v, obsOf("COCONUT_OIL", "2020-03", 100));
        vm.warp(v.closesAt(periodOf("2020-03")));
        g = gasleft();
        e.finalize();
        uint256 finalizeGas = g - gasleft();
        console.log("submit, 2-of-3 attestation:", submitGas);
        console.log("finalize, v1 methodology, one observation per series:", finalizeGas);
        assertLt(submitGas, 600_000);
        assertLt(finalizeGas, 1_000_000);
    }
}

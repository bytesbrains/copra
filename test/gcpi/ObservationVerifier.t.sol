// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GCPIHarness.sol";

/**
 * @notice ObservationVerifier (GCPI-001 §5.3–§5.4, §11.1) against the attacks #92 and §14 name: replay, Sybil
 *         collectors, duplicates, stale and premature observations, colluding notaries, and the bond rules.
 */
contract ObservationVerifierTest is GCPIHarness {
    GCPIEngine internal engine;
    ObservationVerifier internal v;

    function setUp() public {
        engine = deploy(v1(), "2020-01");
        v = engine.verifier();
        vm.warp(uint256(GCPIMath.periodStart(periodOf("2020-04"))) + 2 days);
    }

    function _who(uint256 a) internal pure returns (uint256[] memory w) {
        w = new uint256[](1);
        w[0] = a;
    }

    function _who(uint256 a, uint256 b) internal pure returns (uint256[] memory w) {
        w = new uint256[](2);
        (w[0], w[1]) = (a, b);
    }

    function _submitAs(Observation memory o, bytes[] memory sigs) internal returns (bytes32) {
        vm.deal(submitter, SUBMIT_BOND);
        vm.prank(submitter);
        return v.submit{value: SUBMIT_BOND}(o, sigs);
    }

    // ---------------------------------------------------------------------------------------------------
    // Attestation.

    function test_AcceptsKOfNAndStoresTheCommitment() public {
        Observation memory o = obsOf("PH", "2020-03", 101);
        bytes32 c = submit(v, o);
        assertEq(c, GCPIMath.commitment(o));
        assertEq(v.commitments(1, periodOf("2020-03"))[0], c);
        assertEq(v.observation(c).submitter, submitter);
    }

    function test_OneNotaryIsNotEnough() public {
        Observation memory o = obsOf("PH", "2020-03", 101);
        bytes[] memory sigs = attest(v, o, _who(0));
        vm.expectRevert(ObservationVerifier.NotEnoughAttestations.selector);
        _submitAs(o, sigs);
    }

    function test_TheSameNotaryTwiceIsOneNotary() public {
        Observation memory o = obsOf("PH", "2020-03", 101);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sign(v, notaryKeys[0], o);
        sigs[1] = sign(v, notaryKeys[0], o);
        vm.expectRevert(ObservationVerifier.SignersNotAscending.selector);
        _submitAs(o, sigs);
    }

    function test_SybilCollectorsCountForNothing() public {
        // Any number of keys outside the methodology's notary list adds no weight (§14 "multiple fake collectors").
        Observation memory o = obsOf("PH", "2020-03", 101);
        uint256[2] memory fakes = [uint256(0xF1), uint256(0xF2)];
        bytes[] memory sigs = new bytes[](2);
        address[2] memory who = [vm.addr(fakes[0]), vm.addr(fakes[1])];
        (uint256 lo, uint256 hi) = who[0] < who[1] ? (0, 1) : (1, 0);
        bytes32 d = v.attestationDigest(GCPIMath.commitment(o));
        (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(fakes[lo], d);
        (uint8 v1_, bytes32 r1, bytes32 s1) = vm.sign(fakes[hi], d);
        (sigs[0], sigs[1]) = (abi.encodePacked(r0, s0, v0), abi.encodePacked(r1, s1, v1_));
        vm.expectRevert(abi.encodeWithSelector(ObservationVerifier.NotaryCannotAttest.selector, who[lo]));
        _submitAs(o, sigs);
    }

    function test_AnAttestationCannotBeReplayedOnAnotherDeployment() public {
        // The EIP-712 domain binds a signature to one verifier on one chain (§14 "stale-price replay").
        Observation memory o = obsOf("PH", "2020-03", 101);
        ObservationVerifier other = deployVerifier(v1(), "2020-01");
        bytes[] memory sigs = attest(other, o, quorum());
        vm.expectPartialRevert(ObservationVerifier.NotaryCannotAttest.selector);
        _submitAs(o, sigs);

        vm.chainId(999);
        sigs = attest(v, o, quorum());
        vm.chainId(31337);
        vm.expectPartialRevert(ObservationVerifier.NotaryCannotAttest.selector);
        _submitAs(o, sigs);
    }

    function test_ATamperedObservationLosesItsAttestation() public {
        Observation memory o = obsOf("PH", "2020-03", 101);
        bytes[] memory sigs = attest(v, o, quorum());
        o.price = 150;
        vm.expectPartialRevert(ObservationVerifier.NotaryCannotAttest.selector);
        _submitAs(o, sigs);
    }

    function test_ADuplicateIsRefused() public {
        Observation memory o = obsOf("PH", "2020-03", 101);
        submit(v, o);
        vm.expectRevert(ObservationVerifier.Duplicate.selector);
        this.submitExternal(v, o);
    }

    function test_UnbondedUnbondingAndSlashedNotariesDoNotCount() public {
        address n0 = vm.addr(notaryKeys[0]);
        vm.prank(n0);
        v.beginUnbonding();
        assertFalse(v.counts(n0));
        Observation memory o = obsOf("PH", "2020-03", 101);
        bytes[] memory sigs = attest(v, o, _who(0, 2));
        vm.expectRevert(abi.encodeWithSelector(ObservationVerifier.NotaryCannotAttest.selector, n0));
        _submitAs(o, sigs);
        // The two notaries still bonded are a quorum.
        _submitAs(o, attest(v, o, _who(1, 2)));
    }

    // ---------------------------------------------------------------------------------------------------
    // Windows and structure.

    function test_APeriodClosesAfterTheLagAndTheChallengeWindow() public {
        uint256 t = periodOf("2020-03");
        assertEq(v.closesAt(t), uint256(GCPIMath.periodStart(t + 1)) + 90 days + 3 days);
        Observation memory o = obsOf("PH", "2020-03", 101);
        vm.warp(v.closesAt(t));
        vm.expectRevert(ObservationVerifier.WindowClosed.selector);
        this.submitExternal(v, o);
    }

    function test_APublicationInTheFutureIsRefused() public {
        Observation memory o = obsOf("PH", "2020-03", 101);
        o.published = block.timestamp + 1;
        vm.expectRevert(ObservationVerifier.PublishedInFuture.selector);
        this.submitExternal(v, o);
    }

    function test_StructuralFaultsCarryTheEnginesCodes() public {
        Observation memory o = obsOf("PH", "2020-03", 101);
        o.period = "2020-13";
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "observation_period"));
        this.submitExternal(v, o);
        o = obsOf("PH", "2019-12", 101);
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "observation_out_of_range"));
        this.submitExternal(v, o);
        o = obsOf("PH", "2020-03", 101);
        o.currency = "usd";
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "observation_currency"));
        this.submitExternal(v, o);
        o = obsOf("PH", "2020-03", 101);
        o.fx = 1;
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "observation_fx"));
        this.submitExternal(v, o);
        o = obsOf("PH ", "2020-03", 101);
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "observation_id"));
        this.submitExternal(v, o);
        o = obsOf("XX", "2020-03", 101);
        vm.expectRevert(ObservationVerifier.UnknownSeries.selector);
        this.submitExternal(v, o);
    }

    function test_ObservationsPerSeriesAndPeriodAreBounded() public {
        for (uint256 i = 0; i < v.MAX_OBSERVATIONS(); i++) {
            Observation memory o = obsOf("PH", "2020-03", 101);
            o.record = bytes32(i);
            submit(v, o);
        }
        Observation memory extra = obsOf("PH", "2020-03", 101);
        extra.record = bytes32(uint256(999));
        vm.expectRevert(ObservationVerifier.TooManyObservations.selector);
        this.submitExternal(v, extra);
    }

    // ---------------------------------------------------------------------------------------------------
    // Submitter bonds: anti-spam only, returned once the period closes.

    function test_TheSubmitBondIsExactAndReturnedAfterClose() public {
        Observation memory o = obsOf("PH", "2020-03", 101);
        bytes[] memory sigs = attest(v, o, quorum());
        vm.deal(submitter, 1 ether);
        vm.prank(submitter);
        vm.expectRevert(ObservationVerifier.WrongBond.selector);
        v.submit{value: SUBMIT_BOND - 1}(o, sigs);
        vm.prank(submitter);
        bytes32 c = v.submit{value: SUBMIT_BOND}(o, sigs);

        vm.prank(submitter);
        vm.expectRevert(ObservationVerifier.WindowOpen.selector);
        v.refundBond(c);
        vm.warp(v.closesAt(periodOf("2020-03")));
        vm.prank(address(0xBAD));
        vm.expectRevert(ObservationVerifier.NotSubmitter.selector);
        v.refundBond(c);
        uint256 before = submitter.balance;
        vm.prank(submitter);
        v.refundBond(c);
        assertEq(submitter.balance, before + SUBMIT_BOND);
        vm.prank(submitter);
        vm.expectRevert(ObservationVerifier.AlreadyRefunded.selector);
        v.refundBond(c);
    }

    // ---------------------------------------------------------------------------------------------------
    // Notary bonds: slashable only for faults a contract can prove (§5.4).

    function test_EquivocationIsSlashed() public {
        Observation memory a = obsOf("PH", "2020-03", 101);
        Observation memory b = obsOf("PH", "2020-03", 140);
        address n0 = vm.addr(notaryKeys[0]);
        address reporter = address(0x4E9);
        bytes memory sa = sign(v, notaryKeys[0], a);
        bytes memory sb = sign(v, notaryKeys[0], b);
        vm.prank(reporter);
        v.slashEquivocation(a, sa, b, sb);
        (,, bool slashed,) = v.notaries(n0);
        assertTrue(slashed);
        assertFalse(v.counts(n0));
        assertEq(reporter.balance, NOTARY_BOND / 2);
        // A slashed notary can never bond again: the list changes only with a new methodology version.
        vm.deal(n0, NOTARY_BOND);
        vm.prank(n0);
        vm.expectRevert(ObservationVerifier.AlreadyBonded.selector);
        v.bond{value: NOTARY_BOND}();
    }

    function test_TwoRetrievalsOfTheSameValueAreNotEquivocation() public {
        Observation memory a = obsOf("PH", "2020-03", 101);
        Observation memory b = obsOf("PH", "2020-03", 101);
        b.record = keccak256("another retrieval");
        b.published += 1 days;
        bytes memory sa = sign(v, notaryKeys[0], a);
        bytes memory sb = sign(v, notaryKeys[0], b);
        vm.expectRevert(ObservationVerifier.NotSlashable.selector);
        v.slashEquivocation(a, sa, b, sb);
        // Nor is the same value written differently: 101 × 10⁻² and 1010 × 10⁻³ normalize alike.
        b = obsOf("PH", "2020-03", 1010);
        b.priceExp = 3;
        sb = sign(v, notaryKeys[0], b);
        vm.expectRevert(ObservationVerifier.NotSlashable.selector);
        v.slashEquivocation(a, sa, b, sb);
    }

    function test_DifferentMarketsOrNotariesAreNotEquivocation() public {
        Observation memory a = obsOf("PH", "2020-03", 101);
        Observation memory b = obsOf("ID", "2020-03", 80);
        bytes memory sa = sign(v, notaryKeys[0], a);
        bytes memory sb = sign(v, notaryKeys[0], b);
        vm.expectRevert(ObservationVerifier.NotSlashable.selector);
        v.slashEquivocation(a, sa, b, sb);
        b = obsOf("PH", "2020-03", 140);
        sb = sign(v, notaryKeys[1], b);
        vm.expectRevert(ObservationVerifier.NotSlashable.selector);
        v.slashEquivocation(a, sa, b, sb);
    }

    function test_AttestingAPeriodThatHasNotBegunIsSlashed() public {
        Observation memory o = obsOf("PH", "2021-01", 101);
        o.published = block.timestamp;
        v.slashPremature(o, sign(v, notaryKeys[2], o));
        assertFalse(v.counts(vm.addr(notaryKeys[2])));
        Observation memory ok = obsOf("PH", "2020-03", 101);
        bytes memory sig = sign(v, notaryKeys[1], ok);
        vm.expectRevert(ObservationVerifier.NotSlashable.selector);
        v.slashPremature(ok, sig);
    }

    function test_ABondCanBeWithdrawnOnlyAfterTheDelay() public {
        address n1 = vm.addr(notaryKeys[1]);
        vm.prank(n1);
        vm.expectRevert(ObservationVerifier.NotYetWithdrawable.selector);
        v.withdrawBond();
        vm.prank(n1);
        v.beginUnbonding();
        vm.warp(block.timestamp + UNBONDING - 1);
        vm.prank(n1);
        vm.expectRevert(ObservationVerifier.NotYetWithdrawable.selector);
        v.withdrawBond();
        // Still slashable while unbonding: leaving does not erase what was signed.
        Observation memory a = obsOf("PH", "2020-03", 101);
        Observation memory b = obsOf("PH", "2020-03", 140);
        v.slashEquivocation(a, sign(v, notaryKeys[1], a), b, sign(v, notaryKeys[1], b));
        vm.warp(block.timestamp + 1);
        vm.prank(n1);
        vm.expectRevert(ObservationVerifier.NotBonded.selector);
        v.withdrawBond();

        address n2 = vm.addr(notaryKeys[2]);
        vm.prank(n2);
        v.beginUnbonding();
        vm.warp(block.timestamp + UNBONDING);
        vm.prank(n2);
        v.withdrawBond();
        assertEq(n2.balance, NOTARY_BOND);
    }

    function test_OnlyListedNotariesCanBond() public {
        vm.deal(address(this), NOTARY_BOND);
        vm.expectRevert(ObservationVerifier.NotListed.selector);
        v.bond{value: NOTARY_BOND}();
    }

    // ---------------------------------------------------------------------------------------------------
    // No privileged role.

    function test_TheNotaryListAndThresholdAreFixedAtDeployment() public view {
        // There is no setter for either: GCPIEngineTest.test_TrustAssumption_NoContractHasAPrivilegedFunction
        // checks every state-changing function in the compiled ABI.
        address[] memory list = v.notaryList();
        assertEq(list.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(list[i], vm.addr(notaryKeys[i]));
        }
        assertEq(v.threshold(), THRESHOLD);
    }

    function test_ConstructorRefusesABadNotarySet() public {
        address[] memory none = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "threshold"));
        new ObservationVerifier(seriesOf(v1()), "2020-01", 90, none, 1, 0, 0, 0);
        address[] memory twice = new address[](2);
        (twice[0], twice[1]) = (address(1), address(1));
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "notaries"));
        new ObservationVerifier(seriesOf(v1()), "2020-01", 90, twice, 1, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "threshold"));
        new ObservationVerifier(seriesOf(v1()), "2020-01", 90, notaryAddresses(), 4, 0, 0, 0);
        // A delay that wrapped unbondingAt's 64 bits would make a bond withdrawable at once.
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "unbonding_delay"));
        new ObservationVerifier(seriesOf(v1()), "2020-01", 90, notaryAddresses(), 2, 0, 0, type(uint64).max);
        vm.expectRevert(abi.encodeWithSelector(Malformed.selector, "first"));
        new ObservationVerifier(seriesOf(v1()), "1969-12", 90, notaryAddresses(), 2, 0, 0, 0);
    }

    function test_AHugePublicationTimeIsNotEarlyAndNotSlashableAsEquivocation() public {
        // Evidence is any signed observation, so `published` can be any uint256; it must compare as a number.
        Observation memory a = obsOf("PH", "2020-03", 101);
        Observation memory b = obsOf("PH", "2020-03", 140);
        b.published = type(uint256).max;
        bytes memory sa = sign(v, notaryKeys[0], a);
        bytes memory sb = sign(v, notaryKeys[0], b);
        // b is STALE, so usable: a different value from the same notary is still equivocation.
        v.slashEquivocation(a, sa, b, sb);
        assertFalse(v.counts(vm.addr(notaryKeys[0])));
        (uint256 p, uint8 how) = GCPIMath.normalize(b, periodOf("2020-03"), 90);
        assertEq(p, 1.4e18);
        assertEq(how, GCPIMath.NORM_STALE);
    }
}

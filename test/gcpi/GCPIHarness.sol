// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/gcpi/GCPIEngine.sol";
import "../../src/gcpi/GCPIRegistry.sol";
import "../../src/gcpi/ObservationVerifier.sol";
import "./GCPILens.sol";
import "../../script/GCPIMethodologyReader.sol";

/**
 * @notice Shared set-up for the GCPI contract tests (#92): three notaries with a 2-of-3 threshold, the published
 *         vectors of gcpi/engine/vectors/ loaded as typed inputs, and a replay that submits each observation at its
 *         publication time and finalizes each period as soon as its window closes, as live collectors would.
 */
abstract contract GCPIHarness is Test, GCPIMethodologyReader {
    string internal constant VECTORS = "gcpi/engine/vectors/";
    string internal constant V1_DRAFT = "gcpi/engine/methodology/gcpi-001-v1-draft.json";

    uint256 internal constant SUBMIT_BOND = 0.001 ether;
    uint256 internal constant NOTARY_BOND = 1 ether;
    uint256 internal constant UNBONDING = 30 days;
    uint256 internal constant REWARD = 0.01 ether;
    uint256 internal constant THRESHOLD = 2;

    uint256[3] internal notaryKeys = [uint256(0xA11CE), uint256(0xB0B), uint256(0xCA401)];
    address internal submitter = address(0x5B);

    /// @dev Slashing rewards and refunds paid to the test itself.
    receive() external payable {}

    struct Vector {
        string name;
        GCPIEngine.Methodology m;
        string first;
        uint256 last;
        Observation[] obs;
        string error; // "" unless the vector expects a structural error
        string expectedSha;
    }

    // ---------------------------------------------------------------------------------------------------
    // Deployment.

    function notaryAddresses() internal view returns (address[] memory a) {
        a = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            a[i] = vm.addr(notaryKeys[i]);
        }
    }

    function seriesOf(GCPIEngine.Methodology memory m) internal pure returns (string[] memory s) {
        s = new string[](m.markets.length + m.signals.length);
        for (uint256 i = 0; i < m.markets.length; i++) {
            s[i] = m.markets[i];
        }
        for (uint256 i = 0; i < m.signals.length; i++) {
            s[m.markets.length + i] = m.signals[i];
        }
    }

    function deployVerifier(GCPIEngine.Methodology memory m, string memory first)
        internal
        returns (ObservationVerifier v)
    {
        v = new ObservationVerifier(
            seriesOf(m),
            first,
            m.maxPublicationLagDays,
            notaryAddresses(),
            THRESHOLD,
            SUBMIT_BOND,
            NOTARY_BOND,
            UNBONDING
        );
        for (uint256 i = 0; i < 3; i++) {
            address n = vm.addr(notaryKeys[i]);
            vm.deal(n, NOTARY_BOND);
            vm.prank(n);
            v.bond{value: NOTARY_BOND}();
        }
    }

    function deploy(GCPIEngine.Methodology memory m, string memory first) internal returns (GCPIEngine e) {
        e = new GCPIEngine(m, first, deployVerifier(m, first), REWARD);
    }

    // ---------------------------------------------------------------------------------------------------
    // Attestation.

    function sign(ObservationVerifier v, uint256 key, Observation memory o) internal view returns (bytes memory) {
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(key, v.attestationDigest(GCPIMath.commitment(o)));
        return abi.encodePacked(r, s, vv);
    }

    /// @dev Signatures from the given notaries (indices into notaryKeys), in ascending signer order.
    function attest(ObservationVerifier v, Observation memory o, uint256[] memory who)
        internal
        view
        returns (bytes[] memory sigs)
    {
        for (uint256 i = 1; i < who.length; i++) {
            for (uint256 j = i; j > 0 && vm.addr(notaryKeys[who[j - 1]]) > vm.addr(notaryKeys[who[j]]); j--) {
                (who[j - 1], who[j]) = (who[j], who[j - 1]);
            }
        }
        sigs = new bytes[](who.length);
        for (uint256 i = 0; i < who.length; i++) {
            sigs[i] = sign(v, notaryKeys[who[i]], o);
        }
    }

    function quorum() internal pure returns (uint256[] memory who) {
        who = new uint256[](2);
        (who[0], who[1]) = (0, 1);
    }

    function submit(ObservationVerifier v, Observation memory o) internal returns (bytes32) {
        // Signed first: the signing helper calls the verifier, which would use up the prank.
        bytes[] memory sigs = attest(v, o, quorum());
        vm.deal(submitter, submitter.balance + SUBMIT_BOND);
        vm.prank(submitter);
        return v.submit{value: SUBMIT_BOND}(o, sigs);
    }

    // ---------------------------------------------------------------------------------------------------
    // Replay: observations at their publication time, each period finalized when its window closes.

    function replay(GCPIEngine e, Observation[] memory obs, uint256 last) internal {
        replayWith(e, obs, last, address(this), 0);
    }

    /**
     * @dev Each window's observations are submitted in an order drawn from `seed` (0: by publication time), once
     *      the newest of them is published. `finalizer` calls finalize() as soon as each period closes.
     */
    function replayWith(GCPIEngine e, Observation[] memory obs, uint256 last, address finalizer, uint256 seed)
        internal
    {
        ObservationVerifier v = e.verifier();
        Observation[] memory sorted = byPublished(obs);
        uint256 next;
        for (uint256 t = e.firstPeriod(); t <= last; t++) {
            uint256 closes = v.closesAt(t);
            uint256 from = next;
            while (next < sorted.length && sorted[next].published <= closes) next++;
            if (seed != 0) {
                if (next > from && sorted[next - 1].published > block.timestamp) vm.warp(sorted[next - 1].published);
                _shuffle(sorted, from, next, uint256(keccak256(abi.encode(seed, t))));
            }
            for (uint256 i = from; i < next; i++) {
                if (sorted[i].published > block.timestamp) vm.warp(sorted[i].published);
                _submitOnce(v, sorted[i]);
            }
            if (closes > block.timestamp) vm.warp(closes);
            vm.prank(finalizer);
            assertEq(e.finalize(), t);
        }
        catchUp(e);
        assertEq(next, sorted.length, "every observation was submitted");
    }

    /// @dev Compute any index periods a capped finalize() left for advance().
    function catchUp(GCPIEngine e) internal {
        while (e.advance() > 0) {}
    }

    /// @dev A resubmitted observation counts once (gcpi/ENGINE.md §4): the verifier refuses the copy.
    function _submitOnce(ObservationVerifier v, Observation memory o) internal {
        if (v.observation(GCPIMath.commitment(o)).submitter != address(0)) {
            vm.expectRevert(ObservationVerifier.Duplicate.selector);
            this.submitExternal(v, o);
        } else {
            submit(v, o);
        }
    }

    function _shuffle(Observation[] memory xs, uint256 from, uint256 to, uint256 seed) private pure {
        for (uint256 i = to; i > from + 1; i--) {
            uint256 j = from + uint256(keccak256(abi.encode(seed, i))) % (i - from);
            (xs[i - 1], xs[j]) = (xs[j], xs[i - 1]);
        }
    }

    function submitExternal(ObservationVerifier v, Observation memory o) external {
        submit(v, o);
    }

    function byPublished(Observation[] memory obs) internal pure returns (Observation[] memory s) {
        s = new Observation[](obs.length);
        for (uint256 i = 0; i < obs.length; i++) {
            s[i] = obs[i];
            for (uint256 j = i; j > 0 && s[j - 1].published > s[j].published; j--) {
                (s[j - 1], s[j]) = (s[j], s[j - 1]);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------
    // Loading the published vectors.

    function vectorNames() internal view returns (string[] memory names) {
        Vm.DirEntry[] memory entries = vm.readDir(VECTORS);
        names = new string[](entries.length);
        uint256 n;
        for (uint256 i = 0; i < entries.length; i++) {
            string memory file = _basename(entries[i].path);
            if (!vm.contains(file, ".json") || keccak256(bytes(file)) == keccak256("arithmetic.json")) continue;
            names[n++] = vm.replace(file, ".json", "");
        }
        assembly {
            mstore(names, n)
        }
    }

    function loadVector(string memory name) internal view returns (Vector memory x) {
        string memory json = vm.readFile(string.concat(VECTORS, name, ".json"));
        x.name = name;
        x.expectedSha = vm.parseJsonString(json, ".expected_sha256");
        if (vm.keyExistsJson(json, ".expected.error")) x.error = vm.parseJsonString(json, ".expected.error");
        x.m = methodologyAt(json, ".input.methodology");
        x.first = vm.parseJsonString(json, ".input.first");
        (, x.last) = GCPIMath.parsePeriod(vm.parseJsonString(json, ".input.last"));
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".input.observations[", vm.toString(n), "]"))) n++;
        x.obs = new Observation[](n);
        for (uint256 i = 0; i < n; i++) {
            x.obs[i] = _observation(json, string.concat(".input.observations[", vm.toString(i), "]"));
        }
    }

    function _observation(string memory json, string memory p) private pure returns (Observation memory o) {
        o.market = vm.parseJsonString(json, string.concat(p, ".market"));
        o.period = vm.parseJsonString(json, string.concat(p, ".period"));
        o.source = vm.parseJsonString(json, string.concat(p, ".source"));
        o.price = vm.parseUint(vm.parseJsonString(json, string.concat(p, ".price")));
        o.priceExp = vm.parseUint(vm.parseJsonString(json, string.concat(p, ".price_exp")));
        o.currency = vm.parseJsonString(json, string.concat(p, ".currency"));
        o.unit = vm.parseJsonString(json, string.concat(p, ".unit"));
        string memory fx = vm.parseJsonString(json, string.concat(p, ".fx"));
        if (bytes(fx).length != 0) {
            o.hasFx = true;
            o.fx = vm.parseUint(fx);
            o.fxExp = vm.parseUint(vm.parseJsonString(json, string.concat(p, ".fx_exp")));
        }
        o.fxSource = vm.parseJsonString(json, string.concat(p, ".fx_source"));
        o.published = vm.parseUint(vm.parseJsonString(json, string.concat(p, ".published")));
        o.record = vm.parseBytes32(string.concat("0x", vm.parseJsonString(json, string.concat(p, ".record"))));
        o.basis = vm.parseJsonString(json, string.concat(p, ".basis"));
    }

    function _basename(string memory path) private pure returns (string memory) {
        string[] memory parts = vm.split(path, "/");
        return parts[parts.length - 1];
    }

    // ---------------------------------------------------------------------------------------------------
    // A v1-shaped methodology and observations for the contract tests.

    function v1() internal pure returns (GCPIEngine.Methodology memory m) {
        m.id = "GCPI-test";
        m.markets = new string[](2);
        (m.markets[0], m.markets[1]) = ("ID", "PH");
        m.weights = new uint256[](2);
        (m.weights[0], m.weights[1]) = (35, 65);
        m.signals = new string[](1);
        m.signals[0] = "COCONUT_OIL";
        m.corroborated = new string[](2);
        (m.corroborated[0], m.corroborated[1]) = ("ID", "PH");
        m.corroborators = new string[][](2);
        m.corroborators[0] = new string[](2);
        (m.corroborators[0][0], m.corroborators[0][1]) = ("PH", "COCONUT_OIL");
        m.corroborators[1] = new string[](2);
        (m.corroborators[1][0], m.corroborators[1][1]) = ("ID", "COCONUT_OIL");
        m.minCoverageBp = 7000;
        m.maxPublicationLagDays = 90;
        m.hasBands = true;
        m.bandsBp = [uint256(1000), 2000, 4000];
        m.hasCircuitBreaker = true;
        m.circuitBreakerBp = 4000;
        m.basePeriod = "2020-02";
    }

    function periodOf(string memory ym) internal pure returns (uint256 t) {
        (, t) = GCPIMath.parsePeriod(ym);
    }

    /// @dev A USD/kg observation in cents, published one day after its month ends.
    function obsOf(string memory market, string memory ym, uint256 cents) internal pure returns (Observation memory o) {
        o.market = market;
        o.period = ym;
        o.source = "test-source";
        o.price = cents;
        o.priceExp = 2;
        o.currency = "USD";
        o.unit = "kg";
        o.published = uint256(GCPIMath.periodStart(periodOf(ym) + 1)) + 1 days;
        o.record = keccak256(abi.encode(market, ym, cents));
    }

    // ---------------------------------------------------------------------------------------------------
    // Output.

    function outputSha(GCPIEngine e, uint256 last) internal view returns (string memory) {
        return GCPIMath.hex32(sha256(bytes(GCPILens.canonical(e, last))));
    }
}

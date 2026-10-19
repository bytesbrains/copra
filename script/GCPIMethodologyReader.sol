// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Base.sol";
import "../src/gcpi/GCPIEngine.sol";

/**
 * @notice Reads a GCPI methodology in the reference engine's JSON (gcpi/engine/methodology/, and the `methodology` of
 *         each vector) into GCPIEngine's constructor argument. Shared by DeployGCPI and the contract tests, so the
 *         deployed methodology is read exactly as the tested one is.
 */
abstract contract GCPIMethodologyReader is CommonBase {
    /// @param p The JSON path of the methodology object: "" for a methodology file.
    function methodologyAt(string memory json, string memory p)
        internal
        pure
        returns (GCPIEngine.Methodology memory m)
    {
        m.id = vm.parseJsonString(json, string.concat(p, ".id"));
        m.markets = _sorted(vm.parseJsonKeys(json, string.concat(p, ".markets")));
        m.weights = new uint256[](m.markets.length);
        for (uint256 i = 0; i < m.markets.length; i++) {
            m.weights[i] = vm.parseUint(vm.parseJsonString(json, string.concat(p, ".markets.", m.markets[i])));
        }
        m.signals = vm.parseJsonStringArray(json, string.concat(p, ".signals"));
        m.corroborated = _sorted(vm.parseJsonKeys(json, string.concat(p, ".corroborators")));
        m.corroborators = new string[][](m.corroborated.length);
        for (uint256 i = 0; i < m.corroborated.length; i++) {
            m.corroborators[i] = vm.parseJsonStringArray(json, string.concat(p, ".corroborators.", m.corroborated[i]));
        }
        m.minCoverageBp = vm.parseUint(vm.parseJsonString(json, string.concat(p, ".min_coverage_bp")));
        m.maxPublicationLagDays = vm.parseUint(vm.parseJsonString(json, string.concat(p, ".max_publication_lag_days")));
        if (!_isNull(json, string.concat(p, ".bands_bp"))) {
            string[] memory bands = vm.parseJsonStringArray(json, string.concat(p, ".bands_bp"));
            m.hasBands = true;
            for (uint256 i = 0; i < 3; i++) {
                m.bandsBp[i] = vm.parseUint(bands[i]);
            }
        }
        if (!_isNull(json, string.concat(p, ".circuit_breaker_bp"))) {
            m.hasCircuitBreaker = true;
            m.circuitBreakerBp = vm.parseUint(vm.parseJsonString(json, string.concat(p, ".circuit_breaker_bp")));
        }
        m.basePeriod = vm.parseJsonString(json, string.concat(p, ".base_period"));
    }

    /// @dev Foundry reads a JSON null as one zero word; these keys otherwise hold a string or a list.
    function _isNull(string memory json, string memory key) private pure returns (bool) {
        bytes memory raw = vm.parseJson(json, key);
        return raw.length == 32 && bytes32(raw) == bytes32(0);
    }

    function _sorted(string[] memory xs) private pure returns (string[] memory) {
        for (uint256 i = 1; i < xs.length; i++) {
            for (uint256 j = i; j > 0 && GCPIMath.lessThan(xs[j], xs[j - 1]); j--) {
                (xs[j - 1], xs[j]) = (xs[j], xs[j - 1]);
            }
        }
        return xs;
    }
}

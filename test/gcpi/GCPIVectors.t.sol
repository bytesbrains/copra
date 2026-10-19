// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GCPIHarness.sol";

/**
 * @notice #92 "On-chain results match the reference engine for every test vector": each published vector in
 *         gcpi/engine/vectors/ runs through the real contracts, and the on-chain state, encoded as the engine
 *         encodes its output, has the vector's SHA-256. The vectors' bytes come from engine.py, so this is the
 *         third implementation agreeing byte for byte with the first two.
 */
contract GCPIVectorsTest is GCPIHarness {
    /// @dev A typed ABI cannot carry these inputs: a JSON number, a non-canonical decimal, an unknown field.
    function _unrepresentable(string memory name) private pure returns (bool) {
        bytes32 h = keccak256(bytes(name));
        return h == keccak256("error_number_not_string") || h == keccak256("error_noncanonical_integer")
            || h == keccak256("error_unknown_field");
    }

    function test_EveryVectorMatchesTheReferenceEngine() public {
        string[] memory names = vectorNames();
        assertGe(names.length, 25, "vectors");
        uint256 checked;
        for (uint256 i = 0; i < names.length; i++) {
            if (_unrepresentable(names[i])) continue;
            Vector memory x = loadVector(names[i]);
            if (bytes(x.error).length != 0) {
                _expectError(x);
            } else {
                uint256 snap = vm.snapshotState();
                GCPIEngine e = deploy(x.m, x.first);
                replay(e, x.obs, x.last);
                string memory got = outputSha(e, x.last);
                if (keccak256(bytes(got)) != keccak256(bytes(x.expectedSha))) {
                    console.log(names[i]);
                    console.log(GCPILens.canonical(e, x.last));
                }
                assertEq(got, x.expectedSha, names[i]);
                vm.revertToState(snap);
            }
            checked++;
        }
        assertEq(checked, names.length - 3, "every representable vector was checked");
    }

    /// @dev A structural error is a revert with the engine's code: at deployment for the methodology, at
    ///      submission for an observation.
    function _expectError(Vector memory x) private {
        uint256 snap = vm.snapshotState();
        bytes memory want = abi.encodeWithSelector(Malformed.selector, x.error);
        try this.deployExternal(x.m, x.first) returns (GCPIEngine e) {
            ObservationVerifier v = e.verifier();
            bool reverted;
            for (uint256 i = 0; i < x.obs.length && !reverted; i++) {
                if (submittableAt(x.obs[i]) > block.timestamp) vm.warp(submittableAt(x.obs[i]));
                try this.submitExternal(v, x.obs[i]) {}
                catch (bytes memory reason) {
                    assertEq(reason, want, x.name);
                    reverted = true;
                }
            }
            assertTrue(reverted, x.name);
        } catch (bytes memory reason) {
            assertEq(reason, want, x.name);
        }
        vm.revertToState(snap);
    }

    function deployExternal(GCPIEngine.Methodology memory m, string memory first) external returns (GCPIEngine) {
        return deploy(m, first);
    }

    function test_UnrepresentableErrorsAreExactlyTheUntypedOnes() public view {
        // These three exist only because JSON is untyped. Each of the other structural errors reverts on-chain.
        string[] memory names = vectorNames();
        uint256 n;
        for (uint256 i = 0; i < names.length; i++) {
            if (_unrepresentable(names[i])) n++;
        }
        assertEq(n, 3);
    }
}

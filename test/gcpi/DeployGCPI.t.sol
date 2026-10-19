// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../script/DeployGCPI.s.sol";

/// @notice DeployGCPI (#92): what it deploys, and every refusal.
contract DeployGCPITest is Test {
    uint256 constant KEY = 0xD3916C;
    DeployGCPI script;

    function setUp() public {
        script = new DeployGCPI();
        vm.deal(vm.addr(KEY), 10 ether);
    }

    function _cfg() internal pure returns (DeployGCPI.Config memory c) {
        c.methodologyPath = "gcpi/engine/methodology/gcpi-001-v1-draft.json";
        c.first = "2016-01";
        c.notaries = new address[](3);
        (c.notaries[0], c.notaries[1], c.notaries[2]) = (address(0x1), address(0x2), address(0x3));
        c.threshold = 2;
        c.submitBond = 0.0001 ether;
        c.notaryBond = 0.01 ether;
        c.unbondingDelay = 30 days;
        c.rewardPerPeriod = 0.001 ether;
        c.pool = 0.05 ether;
    }

    function test_DeploysTheThreeContractsWiredTogether() public {
        GCPIEngine e = script.deploy(_cfg(), KEY);
        ObservationVerifier v = e.verifier();
        assertEq(e.registry().engine(), address(e));
        assertEq(e.methodologyId(), "GCPI-001-v1-draft");
        assertEq(
            GCPIMath.hex32(e.methodologyHash()), "0a7ac0a0eee32b6ca1b29432347e33e0d9d6a3b52f34537da1da1ad04d623e1d"
        );
        assertEq(v.threshold(), 2);
        assertEq(v.notaryList().length, 3);
        assertEq(v.series().length, 3);
        assertEq(address(e).balance, 0.05 ether);
        assertEq(e.rewardPerPeriod(), 0.001 ether);
    }

    function test_RefusesBaseMainnet() public {
        vm.chainId(8453);
        vm.expectRevert("DeployGCPI: no live GCPI before shadow publication (#93)");
        script.deploy(_cfg(), KEY);
    }

    function test_RefusesABasePeriodThatHasClosed() public {
        vm.warp(1_800_000_000); // 2027: the v1 draft's 2016-02 base closed long ago
        vm.expectRevert("DeployGCPI: the base period has closed, so no period could be VALID");
        script.deploy(_cfg(), KEY);
    }
}

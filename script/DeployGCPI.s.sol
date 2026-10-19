// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/gcpi/GCPIEngine.sol";
import "../src/gcpi/ObservationVerifier.sol";
import "./GCPIMethodologyReader.sol";

/**
 * @title DeployGCPI
 * @notice Deploys the GCPI contracts (GCPI-001 §11, #92) for one methodology version: an ObservationVerifier with
 *         its notaries, then a GCPIEngine, which deploys its GCPIRegistry. After this no key has any power over
 *         them; the deployer is just the first funder of the incentive pool, if it sends GCPI_POOL.
 *
 *         Testnets only. GCPI publishes no live price before shadow publication (#93), so Base mainnet is refused.
 *         A methodology whose base period has already closed is refused too: its index could never be VALID.
 *
 * Usage:
 * GCPI_METHODOLOGY=gcpi/engine/methodology/<version>.json GCPI_FIRST=2026-11 \
 * GCPI_NOTARIES=0x..,0x..,0x.. GCPI_THRESHOLD=2 \
 * forge script script/DeployGCPI.s.sol:DeployGCPI --rpc-url $BASE_SEPOLIA_RPC --broadcast
 *
 * Optional, in wei and seconds: GCPI_SUBMIT_BOND, GCPI_NOTARY_BOND, GCPI_UNBONDING, GCPI_REWARD, GCPI_POOL.
 */
contract DeployGCPI is Script, GCPIMethodologyReader {
    uint256 public constant BASE_MAINNET = 8453;

    struct Config {
        string methodologyPath;
        string first;
        address[] notaries;
        uint256 threshold;
        uint256 submitBond;
        uint256 notaryBond;
        uint256 unbondingDelay;
        uint256 rewardPerPeriod;
        uint256 pool;
    }

    function run() external returns (GCPIEngine) {
        Config memory cfg = Config({
            methodologyPath: vm.envString("GCPI_METHODOLOGY"),
            first: vm.envString("GCPI_FIRST"),
            notaries: vm.envAddress("GCPI_NOTARIES", ","),
            threshold: vm.envUint("GCPI_THRESHOLD"),
            submitBond: vm.envOr("GCPI_SUBMIT_BOND", uint256(0.0001 ether)),
            notaryBond: vm.envOr("GCPI_NOTARY_BOND", uint256(0.01 ether)),
            unbondingDelay: vm.envOr("GCPI_UNBONDING", uint256(30 days)),
            rewardPerPeriod: vm.envOr("GCPI_REWARD", uint256(0)),
            pool: vm.envOr("GCPI_POOL", uint256(0))
        });
        return deploy(cfg, vm.envUint("PRIVATE_KEY"));
    }

    function deploy(Config memory cfg, uint256 key) public returns (GCPIEngine engine) {
        require(block.chainid != BASE_MAINNET, "DeployGCPI: no live GCPI before shadow publication (#93)");
        GCPIEngine.Methodology memory m = methodologyAt(vm.readFile(cfg.methodologyPath), "");
        (bool ok, uint256 base) = GCPIMath.parsePeriod(m.basePeriod);
        require(ok, "DeployGCPI: methodology base_period");
        uint256 baseCloses = uint256(GCPIMath.periodStart(base + 1)) + m.maxPublicationLagDays * 1 days + 3 days;
        require(block.timestamp < baseCloses, "DeployGCPI: the base period has closed, so no period could be VALID");

        string[] memory series = new string[](m.markets.length + m.signals.length);
        for (uint256 i = 0; i < m.markets.length; i++) {
            series[i] = m.markets[i];
        }
        for (uint256 i = 0; i < m.signals.length; i++) {
            series[m.markets.length + i] = m.signals[i];
        }

        vm.startBroadcast(key);
        ObservationVerifier verifier = new ObservationVerifier(
            series,
            cfg.first,
            m.maxPublicationLagDays,
            cfg.notaries,
            cfg.threshold,
            cfg.submitBond,
            cfg.notaryBond,
            cfg.unbondingDelay
        );
        engine = new GCPIEngine(m, cfg.first, verifier, cfg.rewardPerPeriod);
        if (cfg.pool > 0) {
            (bool sent,) = address(engine).call{value: cfg.pool}("");
            require(sent, "DeployGCPI: funding the pool failed");
        }
        vm.stopBroadcast();

        console.log("ObservationVerifier:", address(verifier));
        console.log("GCPIEngine:", address(engine));
        console.log("GCPIRegistry:", address(engine.registry()));
        console.log("methodology:", m.id);
        console.logBytes32(engine.methodologyHash());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployCopra.s.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title DeployCopraMainnet
 * @notice Deploys Copra Protocol against real collateral with separated roles (#47). The deployer is a
 *         throwaway key that holds no role once OWNER accepts:
 *         - OWNER (the multisig) owns the CopraRegistry from birth: it is part of the CREATE2 init code, so
 *           the multisig fixes the registry's address and no other key ever owns it. The script therefore
 *           cannot register the new set; it prints the calls for OWNER to execute.
 *         - The vault starts owned by the deployer only so it can bind the token, then is handed to OWNER
 *           with Ownable2Step. OWNER accepts in the same batch that registers the set.
 *         - ORACLE_UPDATER (immutable) is the feeder's key. FEE_RECIPIENT receives the protocol fees.
 *         Pre-flight checks and post-deploy verification: docs/MAINNET_DEPLOY.md.
 *
 * Usage (drop --broadcast for a dry run):
 * PRIVATE_KEY=.. COPRA_OWNER=0x.. COPRA_ORACLE_UPDATER=0x.. COPRA_FEE_RECIPIENT=0x.. \
 * COPRA_COLLATERAL=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 COPRA_COLLATERAL_DECIMALS=6 COPRA_INITIAL_PRICE=.. \
 * forge script script/DeployCopraMainnet.s.sol:DeployCopraMainnet --rpc-url $BASE_RPC --broadcast
 */
contract DeployCopraMainnet is CopraRegistryScript {
    uint256 public constant BASE_CHAIN_ID = 8453;
    /// @notice Circle's native USDC on Base: the only collateral this script accepts on chain 8453.
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    struct Config {
        address owner;
        address oracleUpdater;
        address feeRecipient;
        address collateral;
        uint8 collateralDecimals;
        uint256 initialPrice; // 8 decimals, like the oracle
        bool allowDeployerAsUpdater;
    }

    struct Deployment {
        CopraRegistry registry;
        CopraOracle oracle;
        CopraVault vault;
        CopraToken token;
    }

    function run() external returns (Deployment memory) {
        uint256 decimals = vm.envUint("COPRA_COLLATERAL_DECIMALS");
        require(decimals <= type(uint8).max, "DeployCopraMainnet: COPRA_COLLATERAL_DECIMALS out of range");
        Config memory cfg = Config({
            owner: vm.envAddress("COPRA_OWNER"),
            oracleUpdater: vm.envAddress("COPRA_ORACLE_UPDATER"),
            feeRecipient: vm.envAddress("COPRA_FEE_RECIPIENT"),
            collateral: vm.envAddress("COPRA_COLLATERAL"),
            // forge-lint: disable-next-line(unsafe-typecast)
            collateralDecimals: uint8(decimals), // range-checked above
            initialPrice: vm.envUint("COPRA_INITIAL_PRICE"),
            allowDeployerAsUpdater: vm.envOr("COPRA_ALLOW_DEPLOYER_UPDATER", false)
        });
        return deploy(cfg, vm.envUint("PRIVATE_KEY"));
    }

    /// @dev Separate from run() so tests can pass a config without mutating the shared process environment.
    function deploy(Config memory cfg, uint256 deployerPrivateKey) public returns (Deployment memory d) {
        require(deployerPrivateKey != 0, "DeployCopraMainnet: invalid PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        check(cfg, deployer);

        console.log("--------------------------------------------------");
        console.log("Deploying Copra Protocol, chain id:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Owner (multisig):", cfg.owner);
        console.log("Oracle updater:", cfg.oracleUpdater);
        console.log("Fee recipient:", cfg.feeRecipient);
        console.log("Collateral:", cfg.collateral);
        console.log("--------------------------------------------------");

        vm.startBroadcast(deployerPrivateKey);

        // 0. The multisig's registry: deployed once, by anyone, at the address its owner fixes
        d.registry = _ensureRegistry(cfg.owner);

        d.oracle = new CopraOracle(cfg.oracleUpdater, cfg.initialPrice);
        console.log("1. CopraOracle deployed at:", address(d.oracle));

        // Owned by the deployer only until the token is bound
        d.vault = new CopraVault(cfg.collateral, cfg.collateralDecimals, address(d.oracle), cfg.feeRecipient, deployer);
        console.log("2. CopraVault deployed at:", address(d.vault));

        d.token = new CopraToken(address(d.vault));
        console.log("3. CopraToken deployed at:", address(d.token));

        d.vault.setCopraToken(address(d.token));
        d.vault.transferOwnership(cfg.owner);
        console.log("4. Token bound; vault ownership offered to the multisig");

        vm.stopBroadcast();

        console.log("--------------------------------------------------");
        console.log("Not live yet. The multisig must execute, in one batch:");
        console.log("  1. to CopraVault", address(d.vault));
        console.logBytes(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        console.log("  2. to CopraRegistry", address(d.registry));
        console.logBytes(
            abi.encodeCall(
                CopraRegistry.setDeployment, (cfg.collateral, address(d.oracle), address(d.vault), address(d.token))
            )
        );
        console.log("--------------------------------------------------");
    }

    /// @notice Pre-flight checks: everything the script refuses, before anything is broadcast.
    function check(Config memory cfg, address deployer) public view {
        require(
            cfg.owner != address(0) && cfg.oracleUpdater != address(0) && cfg.feeRecipient != address(0)
                && cfg.collateral != address(0),
            "DeployCopraMainnet: zero address"
        );
        // An EOA here would own the registry forever: its address cannot be moved to a multisig later.
        require(cfg.owner.code.length > 0, "DeployCopraMainnet: OWNER must be a contract (the multisig)");
        require(cfg.feeRecipient != deployer, "DeployCopraMainnet: FEE_RECIPIENT must not be the deployer");
        require(
            cfg.oracleUpdater != deployer || cfg.allowDeployerAsUpdater,
            "DeployCopraMainnet: ORACLE_UPDATER is the deployer (set COPRA_ALLOW_DEPLOYER_UPDATER=true to allow)"
        );
        require(cfg.initialPrice > 0, "DeployCopraMainnet: zero COPRA_INITIAL_PRICE");

        require(cfg.collateral.code.length > 0, "DeployCopraMainnet: COLLATERAL has no code");
        require(_hasNoFaucet(cfg.collateral), "DeployCopraMainnet: COLLATERAL is TestnetUSDC (public faucet)");
        require(
            IERC20Metadata(cfg.collateral).decimals() == cfg.collateralDecimals,
            "DeployCopraMainnet: COLLATERAL_DECIMALS does not match the token"
        );
        if (block.chainid == BASE_CHAIN_ID) {
            require(cfg.collateral == BASE_USDC, "DeployCopraMainnet: on Base the collateral must be USDC");
        }
    }

    /// @dev TestnetUSDC mints to anyone. Real USDC has no MAX_FAUCET_AMOUNT, so the call reverts.
    function _hasNoFaucet(address token) internal view returns (bool) {
        (bool ok,) = token.staticcall(abi.encodeWithSignature("MAX_FAUCET_AMOUNT()"));
        return !ok;
    }
}

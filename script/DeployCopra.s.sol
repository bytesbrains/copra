// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CopraToken.sol";
import "../src/CopraOracle.sol";
import "../src/CopraVault.sol";
import "../src/CopraRegistry.sol";
import "../src/testnet/TestnetUSDC.sol";

/**
 * @title DeployCopra
 * @notice Forge deployment script for Copra Protocol on Base Sepolia testnet sandbox.
 *
 * Usage:
 * forge script script/DeployCopra.s.sol:DeployCopra --rpc-url $BASE_SEPOLIA_RPC --broadcast
 */
/// @dev Shared CREATE2 handling for the permanent CopraRegistry.
abstract contract CopraRegistryScript is Script {
    /// @notice Canonical registry address. The web app and oracle feeder hardcode this; it never changes.
    address public constant REGISTRY = 0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25;
    /// @notice The deployer that owns REGISTRY (the owner is part of the CREATE2 init code).
    address public constant REGISTRY_OWNER = 0x91d3019b38185b517Bb98B7BB4953c137F5EEb8E;
    bytes32 public constant REGISTRY_SALT = keccak256("copra.registry.v1");

    /// @notice Deterministic registry address for a given owner.
    function registryAddress(address owner) public pure returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(CopraRegistry).creationCode, abi.encode(owner)));
        return vm.computeCreate2Address(REGISTRY_SALT, initCodeHash);
    }

    /// @dev Returns the owner's registry, deploying it through the CREATE2 factory if it is missing.
    ///      Must be called inside a broadcast.
    function _ensureRegistry(address owner) internal returns (CopraRegistry registry) {
        address expected = registryAddress(owner);
        if (owner == REGISTRY_OWNER) {
            require(expected == REGISTRY, "CopraRegistry bytecode changed: REGISTRY address no longer matches");
        }
        if (expected.code.length == 0) {
            registry = new CopraRegistry{salt: REGISTRY_SALT}(owner);
            require(address(registry) == expected, "CopraRegistry: CREATE2 address mismatch");
            console.log("0. CopraRegistry deployed at:", address(registry));
        } else {
            registry = CopraRegistry(expected);
        }
        require(registry.owner() == owner, "CopraRegistry: broadcaster is not the registry owner");
    }
}

contract DeployCopra is CopraRegistryScript {
    uint8 public constant USDC_DECIMALS = 6;
    uint256 public constant INITIAL_PRICE = 142000000; // $1.42 USD (8 decimals)

    function run() external {
        deploy(vm.envUint("PRIVATE_KEY"));
    }

    /// @notice Local chains only: broadcasts as the `--sender` account, which the node must hold unlocked.
    ///         The e2e stack runs this on anvil as REGISTRY_OWNER (impersonated), so the registry lands at
    ///         the canonical REGISTRY address the dApp and feeder already use.
    ///         forge script DeployCopra.s.sol:DeployCopra --sig "runUnlocked()" --unlocked --sender <addr> --broadcast
    function runUnlocked() external {
        _deploy(msg.sender, 0);
    }

    /// @dev Separate from run() so tests can pass a key without mutating the shared process environment.
    function deploy(uint256 deployerPrivateKey) public {
        require(deployerPrivateKey != 0, "DeployCopra: invalid PRIVATE_KEY");
        _deploy(vm.addr(deployerPrivateKey), deployerPrivateKey);
    }

    /// @dev Broadcasts with `deployerPrivateKey`, or as `deployerAddress` (unlocked on the node) when it is 0.
    function _deploy(address deployerAddress, uint256 deployerPrivateKey) internal {
        console.log("--------------------------------------------------");
        console.log("Deploying Copra Protocol to Base Sepolia Testnet");
        console.log("Deployer Address:", deployerAddress);
        console.log("--------------------------------------------------");

        if (deployerPrivateKey != 0) {
            vm.startBroadcast(deployerPrivateKey);
        } else {
            vm.startBroadcast(deployerAddress);
        }

        // 0. Permanent registry (deployed once; checked for ownership before anything else is spent)
        CopraRegistry registry = _ensureRegistry(deployerAddress);

        // 1. Deploy Testnet USDC with Faucet
        TestnetUSDC usdc = new TestnetUSDC();
        console.log("1. TestnetUSDC deployed at:", address(usdc));

        // 2. Deploy Oracle ($1.42 initial spot price)
        CopraOracle oracle = new CopraOracle(deployerAddress, INITIAL_PRICE);
        console.log("2. CopraOracle deployed at:", address(oracle));

        // 3. Deploy Vault (backed by TestnetUSDC, 0.25% fee, deployer as feeRecipient and owner)
        CopraVault vault =
            new CopraVault(address(usdc), USDC_DECIMALS, address(oracle), deployerAddress, deployerAddress);
        console.log("3. CopraVault deployed at:", address(vault));

        // 4. Deploy CopraToken ($COPRA) pointing to Vault
        CopraToken token = new CopraToken(address(vault));
        console.log("4. CopraToken deployed at:", address(token));

        // 5. Bind Token to Vault
        vault.setCopraToken(address(token));
        console.log("5. CopraToken successfully bound to Vault!");

        // 6. Point the registry at the new set: the web app and oracle feeder follow automatically
        registry.setDeployment(address(usdc), address(oracle), address(vault), address(token));
        console.log("6. CopraRegistry updated to version:", registry.version());

        vm.stopBroadcast();

        console.log("--------------------------------------------------");
        console.log("Base Sepolia Deployment Complete!");
        console.log("--------------------------------------------------");
    }
}

/**
 * @title RegisterCopraDeployment
 * @notice Points the registry at an already-deployed contract set without redeploying it
 *         (bootstrap, or rollback to a previous set).
 *
 * Usage:
 * COPRA_COLLATERAL=0x.. COPRA_ORACLE=0x.. COPRA_VAULT=0x.. COPRA_TOKEN=0x.. \
 * forge script script/DeployCopra.s.sol:RegisterCopraDeployment --rpc-url $BASE_SEPOLIA_RPC --broadcast
 */
contract RegisterCopraDeployment is CopraRegistryScript {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(key != 0, "RegisterCopraDeployment: invalid PRIVATE_KEY");

        vm.startBroadcast(key);
        CopraRegistry registry = _ensureRegistry(vm.addr(key));
        registry.setDeployment(
            vm.envAddress("COPRA_COLLATERAL"),
            vm.envAddress("COPRA_ORACLE"),
            vm.envAddress("COPRA_VAULT"),
            vm.envAddress("COPRA_TOKEN")
        );
        vm.stopBroadcast();

        console.log("CopraRegistry:", address(registry));
        console.log("Registered version:", registry.version());
    }
}

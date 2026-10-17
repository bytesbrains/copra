// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../script/DeployCopraMainnet.s.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RealUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Stands in for the multisig: the script only requires OWNER to be a contract.
contract Multisig {}

/// @notice The mainnet deploy path (#47): separated roles, the multisig's registry, and every refusal.
contract DeployCopraMainnetTest is Test {
    uint256 constant DEPLOYER_KEY = 0xD3910;
    uint256 constant PRICE = 142000000;

    DeployCopraMainnet script;
    address deployer;
    address owner;
    address updater = makeAddr("updater");
    address feeRecipient = makeAddr("feeRecipient");
    RealUSDC usdc;

    function setUp() public {
        script = new DeployCopraMainnet();
        deployer = vm.addr(DEPLOYER_KEY);
        owner = address(new Multisig());
        usdc = new RealUSDC();
    }

    function _cfg() internal view returns (DeployCopraMainnet.Config memory) {
        return DeployCopraMainnet.Config({
            owner: owner,
            oracleUpdater: updater,
            feeRecipient: feeRecipient,
            collateral: address(usdc),
            collateralDecimals: 6,
            initialPrice: PRICE,
            allowDeployerAsUpdater: false
        });
    }

    function _expectRefused(DeployCopraMainnet.Config memory cfg, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        script.deploy(cfg, DEPLOYER_KEY);
    }

    function test_DeployCopraMainnet_RolesSeparatedAndHandedToMultisig() public {
        DeployCopraMainnet.Deployment memory d = script.deploy(_cfg(), DEPLOYER_KEY);

        // The registry belongs to the multisig from birth, at the address it fixes; nothing is registered yet
        assertEq(address(d.registry), script.registryAddress(owner));
        assertEq(d.registry.owner(), owner);
        assertEq(d.registry.version(), 0);

        // Four distinct roles; the deployer holds none once the multisig accepts the vault
        assertEq(d.oracle.feedUpdater(), updater);
        (uint256 price,) = d.oracle.getCopraPriceUSD();
        assertEq(price, PRICE);
        assertEq(d.vault.feeRecipient(), feeRecipient);
        assertEq(address(d.vault.collateralToken()), address(usdc));
        assertEq(address(d.vault.copraToken()), address(d.token));
        assertEq(d.token.vault(), address(d.vault));
        assertEq(d.vault.owner(), deployer);
        assertEq(d.vault.pendingOwner(), owner);

        // The batch the script prints for the multisig
        vm.startPrank(owner);
        d.vault.acceptOwnership();
        d.registry.setDeployment(address(usdc), address(d.oracle), address(d.vault), address(d.token));
        vm.stopPrank();

        assertEq(d.vault.owner(), owner);
        assertEq(d.vault.pendingOwner(), address(0));
        (address collateral, address o, address v, address t, uint256 version,) = d.registry.getDeployment();
        assertEq(abi.encode(collateral, o, v, t, version), abi.encode(usdc, d.oracle, d.vault, d.token, 1));

        // Only the multisig can repoint the registry
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        d.registry.setDeployment(address(usdc), address(d.oracle), address(d.vault), address(d.token));
    }

    function test_DeployCopraMainnet_RedeployReusesTheMultisigRegistry() public {
        DeployCopraMainnet.Deployment memory first = script.deploy(_cfg(), DEPLOYER_KEY);
        DeployCopraMainnet.Deployment memory second = script.deploy(_cfg(), DEPLOYER_KEY);
        assertEq(address(second.registry), address(first.registry));
        assertTrue(address(second.vault) != address(first.vault));
    }

    /// @dev A broadcast that stops part-way (after the vault, before setCopraToken) leaves contracts that
    ///      cannot go live: the registry refuses a vault with no token bound, so a re-run is the only path.
    function test_DeployCopraMainnet_HalfFinishedRunCannotBeRegistered() public {
        DeployCopraMainnet.Deployment memory d = script.deploy(_cfg(), DEPLOYER_KEY);
        CopraVault orphan = new CopraVault(address(usdc), 6, address(d.oracle), feeRecipient, deployer);
        CopraToken orphanToken = new CopraToken(address(orphan));

        vm.prank(owner);
        vm.expectRevert(CopraRegistry.InconsistentDeployment.selector);
        d.registry.setDeployment(address(usdc), address(d.oracle), address(orphan), address(orphanToken));
    }

    /// @dev The registry's address is derived from OWNER, so a redeploy can only find the multisig's own
    ///      registry; if the multisig later handed it to someone else, the script refuses rather than adopt it.
    function test_DeployCopraMainnet_RefusesARegistryNoLongerOwnedByOwner() public {
        DeployCopraMainnet.Deployment memory d = script.deploy(_cfg(), DEPLOYER_KEY);
        address successor = address(new Multisig());
        vm.prank(owner);
        d.registry.transferOwnership(successor);
        vm.prank(successor);
        d.registry.acceptOwnership();

        _expectRefused(_cfg(), "CopraRegistry: not owned by the expected owner");
    }

    function test_DeployCopraMainnet_RefusesZeroAddresses() public {
        string memory reason = "DeployCopraMainnet: zero address";
        DeployCopraMainnet.Config memory cfg = _cfg();
        cfg.owner = address(0);
        _expectRefused(cfg, reason);
        cfg = _cfg();
        cfg.oracleUpdater = address(0);
        _expectRefused(cfg, reason);
        cfg = _cfg();
        cfg.feeRecipient = address(0);
        _expectRefused(cfg, reason);
        cfg = _cfg();
        cfg.collateral = address(0);
        _expectRefused(cfg, reason);
    }

    function test_DeployCopraMainnet_RefusesAnEOAOwner() public {
        DeployCopraMainnet.Config memory cfg = _cfg();
        cfg.owner = makeAddr("eoa");
        _expectRefused(cfg, "DeployCopraMainnet: OWNER must be a contract (the multisig)");
    }

    function test_DeployCopraMainnet_RefusesTheDeployerAsFeeRecipient() public {
        DeployCopraMainnet.Config memory cfg = _cfg();
        cfg.feeRecipient = deployer;
        _expectRefused(cfg, "DeployCopraMainnet: FEE_RECIPIENT must not be the deployer");
    }

    function test_DeployCopraMainnet_RefusesTheDeployerAsUpdaterUnlessAllowed() public {
        DeployCopraMainnet.Config memory cfg = _cfg();
        cfg.oracleUpdater = deployer;
        _expectRefused(
            cfg, "DeployCopraMainnet: ORACLE_UPDATER is the deployer (set COPRA_ALLOW_DEPLOYER_UPDATER=true to allow)"
        );

        cfg.allowDeployerAsUpdater = true;
        DeployCopraMainnet.Deployment memory d = script.deploy(cfg, DEPLOYER_KEY);
        assertEq(d.oracle.feedUpdater(), deployer);
    }

    function test_DeployCopraMainnet_RefusesTestnetUSDC() public {
        DeployCopraMainnet.Config memory cfg = _cfg();
        cfg.collateral = address(new TestnetUSDC());
        _expectRefused(cfg, "DeployCopraMainnet: COLLATERAL is TestnetUSDC (public faucet)");
    }

    function test_DeployCopraMainnet_RefusesBadCollateral() public {
        DeployCopraMainnet.Config memory cfg = _cfg();
        cfg.collateral = makeAddr("nothing");
        _expectRefused(cfg, "DeployCopraMainnet: COLLATERAL has no code");

        cfg = _cfg();
        cfg.collateralDecimals = 18;
        _expectRefused(cfg, "DeployCopraMainnet: COLLATERAL_DECIMALS does not match the token");
    }

    function test_DeployCopraMainnet_RefusesZeroPriceAndKey() public {
        DeployCopraMainnet.Config memory cfg = _cfg();
        cfg.initialPrice = 0;
        _expectRefused(cfg, "DeployCopraMainnet: zero COPRA_INITIAL_PRICE");

        vm.expectRevert("DeployCopraMainnet: invalid PRIVATE_KEY");
        script.deploy(_cfg(), 0);
    }

    /// @dev On Base only Circle's USDC is accepted: any other token, even a well-formed one, is refused.
    function test_DeployCopraMainnet_OnBaseOnlyUSDC() public {
        vm.chainId(8453);
        _expectRefused(_cfg(), "DeployCopraMainnet: on Base the collateral must be USDC");

        vm.etch(script.BASE_USDC(), address(usdc).code);
        DeployCopraMainnet.Config memory cfg = _cfg();
        cfg.collateral = script.BASE_USDC();
        DeployCopraMainnet.Deployment memory d = script.deploy(cfg, DEPLOYER_KEY);
        assertEq(address(d.vault.collateralToken()), script.BASE_USDC());
    }

    /// @dev The testnet script deploys TestnetUSDC and gives one key every role: never on Base.
    function test_DeployCopra_RefusesBaseMainnet() public {
        DeployCopra testnet = new DeployCopra();
        vm.chainId(8453);
        vm.expectRevert("DeployCopra: testnet only, use DeployCopraMainnet on Base");
        testnet.deploy(123456);
    }

    /// @dev Sets only COPRA_* variables: forge runs suites in parallel and the environment is shared, so
    ///      touching PRIVATE_KEY here would race test_DeployCopra_RequiresExplicitPrivateKey.
    function test_DeployCopraMainnet_ConfigFromEnvironment() public {
        vm.setEnv("COPRA_OWNER", vm.toString(owner));
        vm.setEnv("COPRA_ORACLE_UPDATER", vm.toString(updater));
        vm.setEnv("COPRA_FEE_RECIPIENT", vm.toString(feeRecipient));
        vm.setEnv("COPRA_COLLATERAL", vm.toString(address(usdc)));
        vm.setEnv("COPRA_INITIAL_PRICE", vm.toString(PRICE));

        vm.setEnv("COPRA_COLLATERAL_DECIMALS", "262"); // 6 once truncated to uint8: must not slip through
        vm.expectRevert("DeployCopraMainnet: COPRA_COLLATERAL_DECIMALS out of range");
        script.configFromEnv();

        vm.setEnv("COPRA_COLLATERAL_DECIMALS", "6");
        assertEq(abi.encode(script.configFromEnv()), abi.encode(_cfg()));
    }
}

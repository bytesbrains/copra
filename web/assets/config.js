// Copra Protocol dApp: contract addresses, network, environment and ABIs.
// Classic script, not a module: its top-level names share the page's global scope with the
// other /assets/*.js files. It only declares; app.js (loaded last) wires events and starts work,
// so nothing here runs before every file has loaded. Load order is fixed in index.html.

// Network settings (chain, RPC, explorer, registry) come from network.js, loaded just before this
// file and generated per environment (local, sepolia, mainnet) by scripts/web-env.cjs (#43).
// `registry` is permanent (CREATE2). usdc/oracle/vault/token are read from CopraRegistry on load, so
// a protocol redeploy needs no change to this page. On Base Sepolia the set this page shipped with
// stays as a fallback for when the registry cannot be read; other networks have none.
const SEPOLIA_FALLBACK = {
  usdc: '0xd6bC2f148b750e47936f8720aF84DDFc061404DF',
  oracle: '0x4F409293636dCf579f12e7627137e62A8a790b9A',
  vault: '0xbB1CDe2B3c2f8F1D6AAFc1718a92192cb3335f54',
  token: '0x53f5Ef67439E8565559f9C450cFF5CB49b4b996C'
};
const CONTRACTS = {
  registry: NETWORK.registry,
  chainId: NETWORK.chainId,
  chainIdHex: '0x' + NETWORK.chainId.toString(16),
  chainName: NETWORK.chainName,
  rpcUrl: NETWORK.rpcUrl,
  explorer: NETWORK.explorer, // null on a local chain: no explorer links are rendered
  explorerName: NETWORK.explorerName, // "Basescan"; null exactly when explorer is
  // TestnetUSDC has a public faucet; real USDC has none, so no faucet is offered on any hostname (#47).
  faucet: NETWORK.collateral === 'TestnetUSDC',
  collateralName: NETWORK.collateral === 'TestnetUSDC' ? 'Testnet USDC' : 'USDC',
  ...(NETWORK.name === 'sepolia' ? SEPOLIA_FALLBACK : {})
};

// --- Environment & Dynamic Theme Engine ---
// The testnet theme and banner are chosen by HOSTNAME, never by CONTRACTS.chainId (the faucet also
// needs a network whose collateral has one, CONTRACTS.faucet):
// the chainId is 84532 on every deployment while only Base Sepolia exists, so keying on it
// put the testnet theme on copra.dev too. testnet.copra.dev, Workers preview URLs and local
// dev get the testnet UI; copra.dev does not.
const hostname = window.location.hostname;
const isTestnet = hostname.includes('testnet') || hostname.endsWith('.workers.dev') || hostname.includes('localhost') || hostname.includes('127.0.0.1') || window.location.search.includes('testnet');

// Contract ABIs
const ERC20_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function faucet(address to, uint256 amount) external",
  "error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)",
  "error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)"
];

const ORACLE_ABI = [
  "function getCopraPriceUSD() view returns (uint256 price, uint256 timestamp)",
  "error StalePrice()"
];

const VAULT_ABI = [
  "function quoteMint(uint256 copraAmount) view returns (uint256 collateralRequired, uint256 fee)",
  "function quoteRedeem(uint256 copraAmount) view returns (uint256 collateralToReturn, uint256 fee)",
  "function mint(uint256 copraAmount, uint256 maxCollateralIn) external",
  "function redeem(uint256 copraAmount, uint256 minCollateralOut) external",
  "function protocolFeeBps() view returns (uint256)",
  "function accumulatedFees() view returns (uint256)",
  "error ZeroAmount()",
  "error InsufficientVaultCollateral()",
  "error SlippageExceeded(uint256 actual, uint256 limit)",
  "error StalePrice()" // the oracle's, raised through the vault's own price read
];

const REGISTRY_ABI = [
  "function getDeployment() view returns (address collateral, address oracle, address vault, address token, uint256 version, uint256 updatedAt)"
];

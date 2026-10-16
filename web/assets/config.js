// Copra Protocol dApp: contract addresses, network, environment and ABIs.
// Classic script, not a module: its top-level names share the page's global scope with the
// other /assets/*.js files. It only declares; app.js (loaded last) wires events and starts work,
// so nothing here runs before every file has loaded. Load order is fixed in index.html.

// On-Chain Base Sepolia Contract Addresses.
// `registry` is permanent (CREATE2). usdc/oracle/vault/token are only fallbacks: the live set is
// read from CopraRegistry on load, so a protocol redeploy needs no change to this page.
const CONTRACTS = {
  registry: '0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25',
  chainId: 84532,
  chainIdHex: '0x14a34',
  chainName: 'Base Sepolia',
  rpcUrl: 'https://base-sepolia-rpc.publicnode.com',
  explorer: 'https://sepolia.basescan.org',
  usdc: '0xd6bC2f148b750e47936f8720aF84DDFc061404DF',
  oracle: '0x4F409293636dCf579f12e7627137e62A8a790b9A',
  vault: '0xbB1CDe2B3c2f8F1D6AAFc1718a92192cb3335f54',
  token: '0x53f5Ef67439E8565559f9C450cFF5CB49b4b996C'
};

// --- Environment & Dynamic Theme Engine ---
// The testnet theme, banner and faucet are chosen by HOSTNAME, never by CONTRACTS.chainId:
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
  "function faucet(address to, uint256 amount) external"
];

const ORACLE_ABI = [
  "function getCopraPriceUSD() view returns (uint256 price, uint256 timestamp)"
];

const VAULT_ABI = [
  "function quoteMint(uint256 copraAmount) view returns (uint256 collateralRequired, uint256 fee)",
  "function quoteRedeem(uint256 copraAmount) view returns (uint256 collateralToReturn, uint256 fee)",
  "function mint(uint256 copraAmount) external",
  "function redeem(uint256 copraAmount) external",
  "function protocolFeeBps() view returns (uint256)",
  "function accumulatedFees() view returns (uint256)"
];

const REGISTRY_ABI = [
  "function getDeployment() view returns (address collateral, address oracle, address vault, address token, uint256 version, uint256 updatedAt)"
];

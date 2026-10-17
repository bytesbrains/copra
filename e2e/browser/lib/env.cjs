// Where the suite finds the stack. The page always runs at 127.0.0.1 (the hostname that gives the
// testnet UI, as local dev does) and reads the RPC its network.js names: anvil's host port. On the host
// both are real; in the browser container global-setup.cjs forwards those ports to the compose services.
const path = require('node:path');

const REPO = process.env.REPO_DIR || path.join(__dirname, '../../..');
const WEB_PORT = Number(process.env.E2E_WEB_PORT || 8787);
const RPC_PORT = Number(process.env.E2E_RPC_PORT || 8545);

module.exports = {
  REPO,
  WEB_PORT,
  RPC_PORT,
  WEB_URL: `http://127.0.0.1:${WEB_PORT}`,
  PAGE_RPC_URL: `http://127.0.0.1:${RPC_PORT}`, // what the page and its CSP use
  RPC_URL: process.env.RPC_URL || `http://127.0.0.1:${RPC_PORT}`, // what the suite itself uses
  // host:port of the compose services, when the suite runs in its container
  WEB_UPSTREAM: process.env.WEB_UPSTREAM || null,
  CHAIN_UPSTREAM: process.env.CHAIN_UPSTREAM || null,
};

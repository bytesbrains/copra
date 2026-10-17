// Shared harness for the contract scenario suite (#44). Every state change is a real signed transaction
// on the e2e chain, sent from an anvil account through eth_sendTransaction (as a wallet would), and is
// followed by an invariant check. Expected failures are real mined transactions that revert on chain;
// their revert data is read back from the node and decoded, so a test cannot pass on a gas-estimate
// failure or on the wrong error.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { ethers } = require('ethers');

const OUT = process.env.E2E_OUT_DIR || path.join(__dirname, '../../.out');
const manifest = JSON.parse(fs.readFileSync(path.join(OUT, 'deployment.json'), 'utf8'));
const RPC = process.env.RPC_URL || manifest.rpcUrl;

const provider = new ethers.JsonRpcProvider(RPC, manifest.chainId, { staticNetwork: true, cacheTimeout: -1 });
provider.pollingInterval = 50;

const artifact = (name) => JSON.parse(fs.readFileSync(path.join(OUT, 'artifacts', `${name}.json`), 'utf8'));
const abi = (name) => artifact(name).abi;

const C = manifest.contracts;
const contracts = {
  registry: new ethers.Contract(C.registry, abi('CopraRegistry'), provider),
  usdc: new ethers.Contract(C.usdc, abi('TestnetUSDC'), provider),
  oracle: new ethers.Contract(C.oracle, abi('CopraOracle'), provider),
  vault: new ethers.Contract(C.vault, abi('CopraVault'), provider),
  token: new ethers.Contract(C.token, abi('CopraToken'), provider),
};

// Every error any Copra contract or its collateral can raise, for decoding revert data.
const errorInterfaces = ['CopraVault', 'CopraOracle', 'CopraToken', 'CopraRegistry', 'TestnetUSDC', 'MockCollateral']
  .map((n) => new ethers.Interface(abi(n)));

const rpc = (method, params = []) => provider.send(method, params);
const OWNER = manifest.roles.registryOwner;
const users = manifest.users.map(ethers.getAddress);
const signer = (address) => provider.getSigner(address); // unlocked on anvil: eth_sendTransaction

// --- chain control ---
const latestTimestamp = async () => (await provider.getBlock('latest')).timestamp;
const setNextTimestamp = (ts) => rpc('evm_setNextBlockTimestamp', [Number(ts)]);
async function warp(seconds) {
  await rpc('evm_increaseTime', [Number(seconds)]);
  await rpc('evm_mine');
}
async function warpTo(ts) {
  await setNextTimestamp(ts);
  await rpc('evm_mine');
}

/** Runs each test in a snapshot, so state and time are isolated; mines on demand for speed. */
function isolate({ beforeEach, afterEach, before, after }) {
  let snap;
  before(async () => {
    // The stack mines every 2s like Base, which the browser suites rely on. Contract scenarios do not
    // depend on block cadence, so mine per transaction here and restore the cadence afterwards.
    await rpc('evm_setIntervalMining', [0]);
    await rpc('evm_setAutomine', [true]);
    await rpc('anvil_impersonateAccount', [OWNER]);
  });
  after(async () => {
    await rpc('anvil_stopImpersonatingAccount', [OWNER]);
    await rpc('evm_setIntervalMining', [2]);
  });
  beforeEach(async () => {
    snap = await rpc('evm_snapshot');
    invariants.expected.registry = { ...C };
    invariants.extraVaults = [];
  });
  afterEach(async () => {
    await rpc('evm_revert', [snap]);
  });
}

// --- invariants, checked after every successful transaction ---
const invariants = {
  expected: { registry: { ...C } },
  extraVaults: [], // vaults deployed by a test (other collateral decimals), checked the same way
};

async function sumEvents(contract, eventName, field) {
  const logs = await contract.queryFilter(contract.filters[eventName](), 0, 'latest');
  return logs.reduce((acc, l) => acc + BigInt(l.args[field]), 0n);
}

async function checkVault({ vault, token, collateral }) {
  const [balance, fees] = await Promise.all([collateral.balanceOf(vault.target), vault.accumulatedFees()]);
  assert.ok(balance >= fees, `vault ${vault.target} holds ${balance}, less than accumulatedFees ${fees}`);

  // Fee ledger: every fee taken is either still accrued or was claimed.
  const [mintFees, redeemFees, claimed] = await Promise.all([
    sumEvents(vault, 'Minted', 'feePaid'),
    sumEvents(vault, 'Redeemed', 'feePaid'),
    sumEvents(vault, 'FeesClaimed', 'amount'),
  ]);
  assert.equal(fees, mintFees + redeemFees - claimed, 'accumulatedFees != fees taken - fees claimed');

  // Supply ledger: the vault is the only minter; burns are redemptions or holders burning their own.
  const [supply, minted, redeemed] = await Promise.all([
    token.totalSupply(),
    sumEvents(vault, 'Minted', 'copraAmount'),
    sumEvents(vault, 'Redeemed', 'copraAmount'),
  ]);
  const transfers = await token.queryFilter(token.filters.Transfer(), 0, 'latest');
  const mintedByTransfer = transfers.filter((t) => t.args.from === ethers.ZeroAddress).reduce((a, t) => a + t.args.value, 0n);
  const burned = transfers.filter((t) => t.args.to === ethers.ZeroAddress).reduce((a, t) => a + t.args.value, 0n);
  assert.equal(mintedByTransfer, minted, 'COPRA minted outside CopraVault.mint');
  assert.equal(supply, minted - burned, 'totalSupply != minted - burned');
  assert.ok(redeemed <= burned, 'more COPRA redeemed than burned');
}

async function checkInvariants() {
  await checkVault({ vault: contracts.vault, token: contracts.token, collateral: contracts.usdc });
  for (const v of invariants.extraVaults) await checkVault(v);

  const [usdc, oracle, vault, token] = await contracts.registry.getDeployment();
  const r = invariants.expected.registry;
  assert.deepEqual([usdc, oracle, vault, token], [r.usdc, r.oracle, r.vault, r.token], 'registry moved unexpectedly');
}

// --- transactions ---
/** Sends `contract.method(...args)` from `from`, requires success, then checks every invariant. */
async function send(contract, method, args, from, overrides = {}) {
  let tx;
  try {
    tx = await contract.connect(await signer(from))[method](...args, overrides);
    const receipt = await tx.wait();
    assert.equal(receipt.status, 1, `${method} failed`);
    await checkInvariants();
    return receipt;
  } catch (e) {
    // Make an unexpected failure self-explaining in CI logs: what was sent, by whom, and why it reverted.
    const revert = tx ? decodeRevert((await rpc('debug_traceTransaction', [tx.hash, { tracer: 'callTracer' }]).catch(() => ({}))).output)
      : decodeRevert(e.data ?? e.info?.error?.data);
    const ts = await latestTimestamp().catch(() => '?');
    e.message = `${method}(${args.join(', ')}) from ${from} on ${contract.target}` +
      ` [tx ${tx?.hash ?? 'not sent'}, revert ${revert.name}, chain time ${ts}]: ${e.message}`;
    throw e;
  }
}

function decodeRevert(data) {
  if (!data || data === '0x') return { name: '(empty revert)', args: [] };
  for (const iface of errorInterfaces) {
    try {
      const e = iface.parseError(data);
      if (e) return { name: e.name, args: e.args };
    } catch {}
  }
  return { name: `(unknown ${data.slice(0, 10)})`, args: [] };
}

/**
 * Sends a transaction that must revert ON CHAIN with `errorName`. A fixed gas limit skips estimation,
 * so the transaction is mined and fails in a block; the revert data comes from the node's trace.
 * Returns the decoded error args. Invariants must still hold afterwards.
 */
async function expectRevert(contract, method, args, from, errorName, overrides = {}) {
  const c = contract.connect(await signer(from));
  const tx = await c[method](...args, { gasLimit: 1_000_000, ...overrides });
  let receipt;
  try {
    receipt = await tx.wait();
  } catch (e) {
    receipt = e.receipt;
  }
  assert.ok(receipt, `${method}: no receipt`);
  assert.equal(receipt.status, 0, `${method} succeeded, expected ${errorName}`);
  const trace = await rpc('debug_traceTransaction', [tx.hash, { tracer: 'callTracer' }]);
  const err = decodeRevert(trace.output);
  assert.equal(err.name, errorName, `${method} reverted with ${err.name}, expected ${errorName}`);
  await checkInvariants();
  return err.args;
}

// --- actors ---
async function fundUsdc(user, amount) {
  // The public faucet caps a claim at 10,000 USDC, so large balances take several claims, like a user would.
  const cap = await contracts.usdc.MAX_FAUCET_AMOUNT();
  for (let left = BigInt(amount); left > 0n; left -= left > cap ? cap : left) {
    await send(contracts.usdc, 'faucet', [user, left > cap ? cap : left], user);
  }
}

async function mintCopra(user, copraAmount, { approve = true } = {}) {
  const [required] = await contracts.vault.quoteMint(copraAmount);
  if (approve) await send(contracts.usdc, 'approve', [C.vault, required], user);
  return send(contracts.vault, 'mint', [copraAmount], user);
}

/** Posts a price as the oracle updater after waiting out MIN_UPDATE_INTERVAL, as the feeder would. */
async function postPrice(price, oracle = contracts.oracle) {
  const due = (await lastUpdatedAt(oracle)) + (await oracle.MIN_UPDATE_INTERVAL());
  if (BigInt(await latestTimestamp()) < due) await warpTo(due);
  return send(oracle, 'updatePrice', [price], OWNER);
}

/** lastUpdatedAt has no getter; read it from the last PriceUpdated event (works when stale too). */
async function lastUpdatedAt(oracle = contracts.oracle) {
  const logs = await oracle.queryFilter(oracle.filters.PriceUpdated(), 0, 'latest');
  return logs.at(-1).args.timestamp;
}

const balances = async (addr) => ({
  usdc: await contracts.usdc.balanceOf(addr),
  copra: await contracts.token.balanceOf(addr),
});

/** Deploys a contract from its artifact as `from` and returns it connected to the provider. */
async function deploy(name, args, from = OWNER) {
  const a = artifact(name);
  const factory = new ethers.ContractFactory(a.abi, a.bytecode.object, await signer(from));
  const c = await factory.deploy(...args);
  await c.waitForDeployment();
  return new ethers.Contract(await c.getAddress(), a.abi, provider);
}

const units = (v, d) => ethers.parseUnits(String(v), d);

module.exports = {
  ethers, provider, rpc, manifest, contracts, artifact, users, OWNER, signer,
  latestTimestamp, setNextTimestamp, warp, warpTo, isolate,
  invariants, checkInvariants, send, expectRevert, decodeRevert,
  fundUsdc, mintCopra, postPrice, lastUpdatedAt, balances, deploy, units,
};

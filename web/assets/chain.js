// Copra Protocol dApp: on-chain reads (registry, telemetry, balances, allowance) and EIP-747.
// Classic script, not a module: its top-level names share the page's global scope with the
// other /assets/*.js files. It only declares; app.js (loaded last) wires events and starts work,
// so nothing here runs before every file has loaded. Load order is fixed in index.html.

// --- Live Contract Resolution (CopraRegistry) ---
// index.html ships with Base Sepolia's addresses and links in it, identically on every network (#43).
// Rendered at load, so a network without an address shows none rather than Sepolia's (#63).
function renderContractAddresses() {
  document.querySelectorAll('[data-contract]').forEach((el) => {
    const addr = CONTRACTS[el.getAttribute('data-contract')];
    if (el.tagName === 'A') {
      const href = addr && CONTRACTS.explorer ? `${CONTRACTS.explorer}/address/${addr}` : null;
      if (href) {
        el.setAttribute('href', href);
        el.setAttribute('target', '_blank');
        el.setAttribute('rel', 'noopener noreferrer');
      } else {
        // No explorer (a local chain) or no address: never link to another network's, nor half a link.
        ['href', 'target', 'rel'].forEach((a) => el.removeAttribute(a));
      }
      if (el.hasAttribute('data-short')) el.textContent = addr ? `${addr.slice(0, 6)}...${addr.slice(-4)}` : '—';
      else el.classList.toggle('hidden', !href); // "View Contracts on …" with nowhere to go says nothing
    }
    if (el.hasAttribute('data-copy')) {
      el.setAttribute('data-copy', addr || ''); // the copy handler ignores an empty one
      el.classList.toggle('hidden', !addr);
    }
  });
}

// The page's network copy (chain name and id, explorer name) from this build's settings, never the
// Base Sepolia text index.html ships with (#63).
function renderNetwork() {
  document.querySelectorAll('[data-network]').forEach((el) => {
    const value = CONTRACTS[el.getAttribute('data-network')];
    if (value !== null && value !== undefined) el.textContent = String(value);
  });
  document.querySelectorAll('[data-needs-explorer]').forEach((el) => {
    if (!CONTRACTS.explorer) el.classList.add('hidden');
  });
  renderContractAddresses();
}

// Resolves to true when the registry was read; on any failure the baked-in fallbacks stay in use.
async function loadDeployment() {
  try {
    const readProvider = new ethers.JsonRpcProvider(CONTRACTS.rpcUrl);
    const registry = new ethers.Contract(CONTRACTS.registry, REGISTRY_ABI, readProvider);
    const [collateral, oracle, vault, token, version] = await registry.getDeployment();
    const live = { usdc: collateral, oracle, vault, token };
    if (version === 0n || !Object.values(live).every((a) => ethers.isAddress(a) && a !== ethers.ZeroAddress)) {
      throw new Error('registry has no deployment');
    }
    Object.assign(CONTRACTS, live);
    renderContractAddresses();
    document.getElementById('registryVersion').textContent = `· deployment v${version}`;
    return true;
  } catch (e) {
    console.warn('CopraRegistry unavailable, using built-in addresses:', e);
    return false;
  }
}

// --- Readable contract errors ---
// What a user is told when a call reverts with one of the protocol's custom errors. Found by the
// browser suite (#46): without the error fragments, ethers reported "unknown custom error".
const REVERT_MESSAGES = {
  StalePrice: 'The oracle price is stale, so minting and redeeming are paused until it is updated.',
  InsufficientVaultCollateral: 'The vault does not hold enough USDC to pay this redemption right now. Try a smaller amount.',
  SlippageExceeded: 'The price or fee moved past your quote before the transaction ran, so the vault refused it and no USDC or $COPRA moved. The new quote is shown: check it and submit again.',
  ZeroAmount: 'Enter an amount greater than zero.',
  ERC20InsufficientBalance: 'Your balance is too low for this amount.',
  ERC20InsufficientAllowance: 'The vault is not approved to spend this much USDC.'
};

// The protocol's custom errors, parsed once. Built on first use, not at load, so a page whose ethers
// failed to load still degrades to "Unavailable" instead of dying here.
let revertInterface = null;
function protocolErrors() {
  if (!revertInterface) {
    const errors = [...ERC20_ABI, ...ORACLE_ABI, ...VAULT_ABI].filter((f) => f.startsWith('error '));
    revertInterface = new ethers.Interface([...new Set(errors)]);
  }
  return revertInterface;
}

// The custom error a failed call or transaction reverted with, or null. ethers decodes it for calls
// through a Contract (err.revert); a failed gas estimate only carries the raw revert data.
function revertName(err) {
  if (err?.revert?.name) return err.revert.name;
  const data = err?.data ?? err?.info?.error?.data ?? err?.error?.data;
  if (typeof data !== 'string' || data.length < 10) return null;
  try {
    return protocolErrors().parseError(data)?.name ?? null;
  } catch {
    return null;
  }
}

function errorMessage(err) {
  if (err?.code === 'ACTION_REJECTED' || err?.code === 4001 || err?.info?.error?.code === 4001) return 'You rejected the request in your wallet.';
  const name = revertName(err);
  if (name) return REVERT_MESSAGES[name] || `The contract rejected it (${name}).`;
  return err?.shortMessage || err?.message || 'Cancelled';
}

// No usable oracle price: say so instead of quoting against a price the chain did not give.
function showOracleUnavailable(err) {
  currentPriceRaw = null;
  const stale = revertName(err) === 'StalePrice';
  priceProblem = stale ? REVERT_MESSAGES.StalePrice : 'The protocol cannot be read right now, so minting and redeeming are paused.';
  const label = stale ? 'Price stale' : 'Price unavailable';
  document.getElementById('benchmarkHeader').textContent = label;
  document.getElementById('oracleDisplay').textContent = label;
  document.getElementById('metricOracleAge').textContent = stale ? 'Stale: no update within the 7-day heartbeat' : 'Oracle unreachable';
  document.getElementById('metricOracleUpdated').textContent = 'Minting and redeeming are paused';
}

// Reads overlap (the 15s poll, a quote re-check, the refresh after a transaction) and can resolve out
// of order on a slow RPC. Only a read newer than the last one applied may change the page, so an old
// response never puts back a price the chain has since moved from.
let telemetryStarted = 0;
let telemetryApplied = 0;
function telemetryIsLatest(seq) {
  if (seq < telemetryApplied) return false;
  telemetryApplied = seq;
  return true;
}

// No readable fee: quote nothing rather than the built-in 25 bps (#64). The next read that gets it resumes.
function showFeeUnavailable() {
  feeBps = null;
  feeLabel.textContent = 'Protocol Fee (unavailable)';
  document.getElementById('metricFeeRate').textContent = 'Fee unavailable';
}

// Read live price, total supply, vault reserves, and protocol fee metrics from the chain
async function readProtocolTelemetry() {
  await deploymentReady;
  const seq = ++telemetryStarted;
  try {
    const readProvider = new ethers.JsonRpcProvider(CONTRACTS.rpcUrl);
    const oracleContract = new ethers.Contract(CONTRACTS.oracle, ORACLE_ABI, readProvider);
    const vaultContract = new ethers.Contract(CONTRACTS.vault, VAULT_ABI, readProvider);
    const tokenContract = new ethers.Contract(CONTRACTS.token, ERC20_ABI, readProvider);
    const usdcContract = new ethers.Contract(CONTRACTS.usdc, ERC20_ABI, readProvider);

    let oracleError = null;
    const [oracleData, totalSupplyRaw, vaultUsdcRaw, accFeesRaw, feeBpsRaw] = await Promise.all([
      oracleContract.getCopraPriceUSD().catch((e) => { oracleError = e; return null; }),
      tokenContract.totalSupply().catch(() => null),
      usdcContract.balanceOf(CONTRACTS.vault).catch(() => null),
      vaultContract.accumulatedFees().catch(() => null),
      vaultContract.protocolFeeBps().catch(() => null)
    ]);
    if (!telemetryIsLatest(seq)) return;

    if (oracleData) {
      const [priceBn, updatedAtBn] = oracleData;
      currentPriceRaw = BigInt(priceBn);
      currentPriceUSD = Number(priceBn) / 1e8;
      const updatedAtSec = Number(updatedAtBn);
      document.getElementById('benchmarkHeader').textContent = `$${currentPriceUSD.toFixed(2)} USD / kg`;
      document.getElementById('oracleDisplay').textContent = `$${currentPriceUSD.toFixed(2)} USD / kg`;
      document.getElementById('metricOracleAge').textContent = `Updated ${formatAge(updatedAtSec)}`;
      const dateStr = new Date(updatedAtSec * 1000).toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
      document.getElementById('metricOracleUpdated').textContent = dateStr;
    } else {
      showOracleUnavailable(oracleError);
    }

    if (feeBpsRaw !== null) {
      feeBps = BigInt(feeBpsRaw);
      const bps = Number(feeBpsRaw);
      const pct = (bps / 100).toFixed(2);
      feeLabel.textContent = `Protocol Fee (${pct}%)`;
      document.getElementById('metricFeeRate').textContent = `${pct}% (${bps} bps) Fee`;
    } else {
      showFeeUnavailable();
    }

    if (totalSupplyRaw !== null) {
      const supply = Number(totalSupplyRaw) / 1e18;
      document.getElementById('metricTotalSupply').textContent = `${supply.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 4 })} $COPRA`;
    }

    if (vaultUsdcRaw !== null) {
      const reserves = Number(vaultUsdcRaw) / 1e6;
      document.getElementById('metricVaultReserves').textContent = `$${reserves.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USDC`;
    }

    if (accFeesRaw !== null) {
      const fees = Number(accFeesRaw) / 1e6;
      document.getElementById('metricAccumulatedFees').textContent = `$${fees.toLocaleString(undefined, { minimumFractionDigits: 4, maximumFractionDigits: 4 })} USDC`;
    }

    calculate();
  } catch (e) {
    console.warn('Could not read protocol telemetry:', e);
    if (!telemetryIsLatest(seq)) return;
    // Nothing could be read (no deployment known, RPC down): say so rather than "Loading..." forever.
    for (const id of ['metricTotalSupply', 'metricVaultReserves', 'metricAccumulatedFees']) {
      const el = document.getElementById(id);
      if (el.textContent === 'Loading...') el.textContent = 'Unavailable';
    }
    showOracleUnavailable(e);
    showFeeUnavailable();
    calculate();
  }
}

// Refresh User Balances
async function refreshBalances() {
  if (!userAddress || !provider) return;
  try {
    const usdcContract = new ethers.Contract(CONTRACTS.usdc, ERC20_ABI, provider);
    const tokenContract = new ethers.Contract(CONTRACTS.token, ERC20_ABI, provider);

    const [usdcRaw, copraRaw] = await Promise.all([
      usdcContract.balanceOf(userAddress),
      tokenContract.balanceOf(userAddress)
    ]);

    userUsdcBalanceRaw = usdcRaw;
    userCopraBalanceRaw = copraRaw;

    usdcBalanceEl.textContent = (Number(usdcRaw) / 1e6).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    copraBalanceEl.textContent = (Number(copraRaw) / 1e18).toLocaleString(undefined, { minimumFractionDigits: 4, maximumFractionDigits: 4 });
  } catch (e) {
    console.warn('Balance refresh error:', e);
  }
}

// Check USDC allowance for Vault
async function checkAllowance() {
  if (!userAddress || !provider || mode !== 'mint') return;
  try {
    const usdcContract = new ethers.Contract(CONTRACTS.usdc, ERC20_ABI, provider);
    const allowance = await usdcContract.allowance(userAddress, CONTRACTS.vault);
    const amountUSDC = CopraQuote.parseUnits(amountInput.value, 6) ?? 0n;

    if (allowance < amountUSDC) {
      actionBtnText.textContent = 'Approve USDC';
    } else {
      actionBtnText.textContent = 'Mint $COPRA';
    }
  } catch (e) {
    console.warn('Allowance check error:', e);
  }
}

// --- EIP-747 Watch Asset Helpers ---
async function watchToken(address, symbol, decimals, image) {
  if (!window.ethereum) return;
  try {
    await window.ethereum.request({
      method: 'wallet_watchAsset',
      params: {
        type: 'ERC20',
        options: { address, symbol, decimals, image }
      }
    });
  } catch (e) {
    console.warn('wallet_watchAsset error:', e);
  }
}

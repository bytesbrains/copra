// Copra Protocol dApp: on-chain reads (registry, telemetry, balances, allowance) and EIP-747.
// Classic script, not a module: its top-level names share the page's global scope with the
// other /assets/*.js files. It only declares; app.js (loaded last) wires events and starts work,
// so nothing here runs before every file has loaded. Load order is fixed in index.html.

// --- Live Contract Resolution (CopraRegistry) ---
function renderContractAddresses() {
  document.querySelectorAll('[data-contract]').forEach((el) => {
    const addr = CONTRACTS[el.getAttribute('data-contract')];
    if (!addr) return;
    if (el.tagName === 'A') {
      el.href = `${CONTRACTS.explorer}/address/${addr}`;
      if (el.hasAttribute('data-short')) el.textContent = `${addr.slice(0, 6)}...${addr.slice(-4)}`;
    }
    if (el.hasAttribute('data-copy')) el.setAttribute('data-copy', addr);
  });
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

// Read live price, total supply, vault reserves, and protocol fee metrics from Base Sepolia
async function readProtocolTelemetry() {
  await deploymentReady;
  try {
    const readProvider = new ethers.JsonRpcProvider(CONTRACTS.rpcUrl);
    const oracleContract = new ethers.Contract(CONTRACTS.oracle, ORACLE_ABI, readProvider);
    const vaultContract = new ethers.Contract(CONTRACTS.vault, VAULT_ABI, readProvider);
    const tokenContract = new ethers.Contract(CONTRACTS.token, ERC20_ABI, readProvider);
    const usdcContract = new ethers.Contract(CONTRACTS.usdc, ERC20_ABI, readProvider);

    const [oracleData, totalSupplyRaw, vaultUsdcRaw, accFeesRaw, feeBpsRaw] = await Promise.all([
      oracleContract.getCopraPriceUSD().catch(() => null),
      tokenContract.totalSupply().catch(() => null),
      usdcContract.balanceOf(CONTRACTS.vault).catch(() => null),
      vaultContract.accumulatedFees().catch(() => null),
      vaultContract.protocolFeeBps().catch(() => null)
    ]);

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
    }

    if (feeBpsRaw !== null) {
      feeBps = BigInt(feeBpsRaw);
      const bps = Number(feeBpsRaw);
      const pct = (bps / 100).toFixed(2);
      feeLabel.textContent = `Protocol Fee (${pct}%)`;
      document.getElementById('metricFeeRate').textContent = `${pct}% (${bps} bps) Fee`;
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

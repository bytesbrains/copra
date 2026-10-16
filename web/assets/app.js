// Copra Protocol dApp. External (not inline) so the CSP needs no 'unsafe-inline' for scripts.
// Loaded at the end of <body>: expects ethers, CopraQuote and the page's DOM to be present.
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

// --- State Variables ---
let currentPriceUSD = 1.42;
let currentPriceRaw = 142000000n; // oracle price, 8 decimals
let feeBps = 25n; // 0.25%
let mode = 'mint';
let userAddress = null;
let provider = null;
let signer = null;
let userUsdcBalanceRaw = 0n;
let userCopraBalanceRaw = 0n;

// --- Apply Theme & Hostname Adaptations ---
if (isTestnet) {
  document.getElementById('bodyEl').classList.add('testnet-theme');
  document.getElementById('testnetBar').classList.remove('hidden');
  document.getElementById('testnetBadge').classList.remove('hidden');
  document.getElementById('networkBadge').textContent = 'Base Sepolia';
  document.getElementById('networkBadge').className = 'text-xs font-mono bg-amber-500/20 text-amber-300 border border-amber-500/40 px-2 py-0.5 rounded-full';
  document.getElementById('logoSuffix').className = 'text-amber-400 font-medium';
  document.getElementById('heroGlow').className = 'absolute -inset-1 rounded-full bg-gradient-to-r from-amber-500 to-orange-400 opacity-25 blur-lg';
  document.getElementById('heroTag').className = 'inline-flex items-center space-x-2 bg-amber-500/10 border border-amber-500/30 text-amber-400 text-xs px-3 py-1 rounded-full mb-6 font-mono';
  document.getElementById('heroGradientText').className = 'text-transparent bg-clip-text bg-gradient-to-r from-amber-400 to-orange-300';
  document.getElementById('tabMint').className = 'flex-1 py-2 rounded-md bg-amber-500 text-black transition font-bold';
  document.getElementById('actionBtn').className = 'w-full bg-amber-500 hover:bg-amber-400 text-black font-bold py-3.5 rounded-xl transition text-sm flex items-center justify-center space-x-2';
  document.getElementById('reserveDisplay').className = 'text-amber-400 font-bold';
  document.getElementById('connectBtn').className = 'bg-amber-500 hover:bg-amber-400 text-black font-bold text-xs px-4 py-2 rounded-lg transition flex items-center space-x-1.5';
}

// --- DOM Elements ---
const tabMint = document.getElementById('tabMint');
const tabRedeem = document.getElementById('tabRedeem');
const inputLabel = document.getElementById('inputLabel');
const outputLabel = document.getElementById('outputLabel');
const inputTicker = document.getElementById('inputTicker');
const outputTicker = document.getElementById('outputTicker');
const amountInput = document.getElementById('amountInput');
const outputAmount = document.getElementById('outputAmount');
const feeDisplay = document.getElementById('feeDisplay');
const feeLabel = document.getElementById('feeLabel');
const actionBtn = document.getElementById('actionBtn');
const actionBtnText = document.getElementById('actionBtnText');
const connectBtn = document.getElementById('connectBtn');
const connectText = document.getElementById('connectText');
const balanceBar = document.getElementById('balanceBar');
const usdcBalanceEl = document.getElementById('usdcBalance');
const copraBalanceEl = document.getElementById('copraBalance');
const txStatus = document.getElementById('txStatus');
const faucetBtn = document.getElementById('faucetBtn');
const maxBtn = document.getElementById('maxBtn');
const watchCopraBtn = document.getElementById('watchCopraBtn');
const watchUsdcBtn = document.getElementById('watchUsdcBtn');

// --- Price & Calculation Engine ---
// Exact BigInt mirror of CopraVault.quoteMint / quoteRedeem (see /assets/quote.js).
// Mint: the input is the total USDC paid, fee included, so the $COPRA amount is the largest
// one whose quoteMint().collateralRequired fits inside it.
function mintCopraWei() {
  const usdcRaw = CopraQuote.parseUnits(amountInput.value, 6) ?? 0n;
  return CopraQuote.copraForCollateral(usdcRaw, currentPriceRaw, feeBps);
}

function calculate() {
  if (mode === 'mint') {
    const copraWei = mintCopraWei();
    const { fee } = CopraQuote.quoteMint(copraWei, currentPriceRaw, feeBps);
    outputAmount.value = CopraQuote.formatUnits(copraWei, 18, 4);
    feeDisplay.textContent = '$' + CopraQuote.formatUnits(fee, 6, 4) + ' USDC';
  } else {
    const copraWei = CopraQuote.parseUnits(amountInput.value, 18) ?? 0n;
    const { collateralToReturn, fee } = CopraQuote.quoteRedeem(copraWei, currentPriceRaw, feeBps);
    outputAmount.value = CopraQuote.formatUnits(collateralToReturn, 6, 4);
    feeDisplay.textContent = '$' + CopraQuote.formatUnits(fee, 6, 4) + ' USDC';
  }
}

amountInput.addEventListener('input', calculate);

function setTabStyles() {
  const activeClass = isTestnet
    ? 'flex-1 py-2 rounded-md bg-amber-500 text-black transition font-bold'
    : 'flex-1 py-2 rounded-md bg-emerald-500 text-black transition font-bold';
  const inactiveClass = 'flex-1 py-2 rounded-md text-slate-400 hover:text-white transition';

  if (mode === 'mint') {
    tabMint.className = activeClass;
    tabRedeem.className = inactiveClass;
    inputLabel.textContent = 'You Pay (USDC)';
    outputLabel.textContent = 'You Receive ($COPRA)';
    inputTicker.innerHTML = '<span>USDC</span>';
    outputTicker.innerHTML = '<img src="/assets/copra_logo_32.png" alt="Copra" class="w-4 h-4 rounded-full"><span>COPRA</span>';
    amountInput.value = '14.20';
    actionBtnText.textContent = userAddress ? 'Mint $COPRA' : 'Connect Wallet to Mint';
  } else {
    tabRedeem.className = activeClass;
    tabMint.className = inactiveClass;
    inputLabel.textContent = 'You Burn ($COPRA)';
    outputLabel.textContent = 'You Receive (USDC)';
    inputTicker.innerHTML = '<img src="/assets/copra_logo_32.png" alt="Copra" class="w-4 h-4 rounded-full"><span>COPRA</span>';
    outputTicker.innerHTML = '<span>USDC</span>';
    amountInput.value = '10.00';
    actionBtnText.textContent = userAddress ? 'Redeem USDC' : 'Connect Wallet to Redeem';
  }
  calculate();
}

tabMint.addEventListener('click', () => { mode = 'mint'; setTabStyles(); checkAllowance(); });
tabRedeem.addEventListener('click', () => { mode = 'redeem'; setTabStyles(); });

// --- MAX Button Handler ---
maxBtn.addEventListener('click', () => {
  if (!userAddress) return;
  // Exact balance, never rounded up — a rounded-up MAX makes transferFrom / burn revert.
  amountInput.value = mode === 'mint'
    ? CopraQuote.formatUnits(userUsdcBalanceRaw, 6)
    : CopraQuote.formatUnits(userCopraBalanceRaw, 18);
  calculate();
  checkAllowance();
});

// --- Copy Address Buttons ---
document.querySelectorAll('.copy-addr-btn').forEach((btn) => {
  btn.addEventListener('click', async () => {
    const addr = btn.getAttribute('data-copy');
    if (!addr) return;
    try {
      await navigator.clipboard.writeText(addr);
      const prev = btn.textContent;
      btn.textContent = 'Copied!';
      setTimeout(() => { btn.textContent = prev; }, 1500);
    } catch (e) {
      console.warn('Clipboard copy failed:', e);
    }
  });
});

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

watchCopraBtn.addEventListener('click', () => {
  watchToken(CONTRACTS.token, 'COPRA', 18, window.location.origin + '/assets/copra_logo_128.png');
});

watchUsdcBtn.addEventListener('click', () => {
  watchToken(CONTRACTS.usdc, 'USDC', 6, '');
});

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

const deploymentReady = loadDeployment();

// --- Toast / Notification Helper ---
function showToast(msg, type = 'info', txHash = null) {
  txStatus.classList.remove('hidden', 'bg-emerald-500/10', 'border-emerald-500/30', 'text-emerald-300', 'bg-amber-500/10', 'border-amber-500/30', 'text-amber-300', 'bg-red-500/10', 'border-red-500/30', 'text-red-300');
  let colorClass = 'bg-emerald-500/10 border-emerald-500/30 text-emerald-300';
  if (type === 'warn' || type === 'pending') colorClass = 'bg-amber-500/10 border-amber-500/30 text-amber-300';
  if (type === 'error') colorClass = 'bg-red-500/10 border-red-500/30 text-red-300';
  txStatus.className = 'rounded-xl p-3 text-xs font-mono border ' + colorClass;

  // Messages can carry wallet/RPC error text, so build nodes instead of interpolating HTML.
  const msgEl = document.createElement('div');
  msgEl.textContent = msg;
  txStatus.replaceChildren(msgEl);
  if (txHash) {
    const link = document.createElement('a');
    link.href = `${CONTRACTS.explorer}/tx/${encodeURIComponent(txHash)}`;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.className = 'underline mt-1 inline-block text-[11px] font-bold';
    link.textContent = 'View on Basescan ↗';
    txStatus.appendChild(link);
  }
}

// --- Web3 Blockchain Connection & Interactivity ---
async function initWeb3() {
  await deploymentReady;
  if (typeof window.ethereum === 'undefined') {
    showToast('Please install MetaMask, Coinbase Wallet, or Rabby to interact with Copra Protocol on Base Sepolia.', 'warn');
    return;
  }

  try {
    provider = new ethers.BrowserProvider(window.ethereum);
    const accounts = await provider.send("eth_requestAccounts", []);
    userAddress = accounts[0];

    // Check & enforce network before getting signer
    const network = await provider.getNetwork();
    if (Number(network.chainId) !== CONTRACTS.chainId) {
      try {
        await window.ethereum.request({
          method: 'wallet_switchEthereumChain',
          params: [{ chainId: CONTRACTS.chainIdHex }]
        });
      } catch (switchError) {
        if (switchError.code === 4902) {
          await window.ethereum.request({
            method: 'wallet_addEthereumChain',
            params: [{
              chainId: CONTRACTS.chainIdHex,
              chainName: CONTRACTS.chainName,
              nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
              rpcUrls: [CONTRACTS.rpcUrl],
              blockExplorerUrls: [CONTRACTS.explorer]
            }]
          });
        } else {
          throw switchError;
        }
      }
      provider = new ethers.BrowserProvider(window.ethereum);
    }

    signer = await provider.getSigner();
    connectText.textContent = `${userAddress.slice(0, 6)}...${userAddress.slice(-4)}`;
    balanceBar.classList.remove('hidden');
    maxBtn.classList.remove('hidden');
    await refreshBalances();
    await readProtocolTelemetry();
    await checkAllowance();
  } catch (err) {
    console.error('Wallet error:', err);
    showToast('Wallet error: ' + (err.shortMessage || err.message), 'error');
  }
}

// Format relative age for oracle timestamp
function formatAge(updatedAtSeconds) {
  const nowSec = Math.floor(Date.now() / 1000);
  const diff = Math.max(0, nowSec - updatedAtSeconds);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
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

amountInput.addEventListener('input', checkAllowance);

// --- Action Button Click Handler (Approve / Mint / Redeem) ---
actionBtn.addEventListener('click', async () => {
  if (!userAddress || !signer) {
    await initWeb3();
    return;
  }

  actionBtn.disabled = true;
  actionBtnText.textContent = 'Confirming in wallet...';

  try {
    if (mode === 'mint') {
      const usdcContract = new ethers.Contract(CONTRACTS.usdc, ERC20_ABI, signer);
      const vaultContract = new ethers.Contract(CONTRACTS.vault, VAULT_ABI, signer);

      // Largest $COPRA amount whose collateral (fee included) fits inside the USDC entered
      const copraWei = mintCopraWei();
      if (copraWei <= 0n) {
        showToast('Enter a valid USDC amount to mint.', 'warn');
        return;
      }

      // Get exact quote from vault — the oracle may have moved since the preview
      const [collateralRequired] = await vaultContract.quoteMint(copraWei);
      const usdcBalance = await usdcContract.balanceOf(userAddress);
      if (usdcBalance < collateralRequired) {
        showToast(`Insufficient USDC: this mint needs ${CopraQuote.formatUnits(collateralRequired, 6)} USDC at the current oracle price.`, 'warn');
        return;
      }
      const allowance = await usdcContract.allowance(userAddress, CONTRACTS.vault);

      if (allowance < collateralRequired) {
        showToast('Requesting USDC approval...', 'pending');
        const appTx = await usdcContract.approve(CONTRACTS.vault, ethers.MaxUint256);
        showToast(`Approval submitted. Waiting for confirmation...`, 'pending', appTx.hash);
        await appTx.wait(1);
        showToast('USDC approved! Now click Mint $COPRA.', 'info');
        actionBtnText.textContent = 'Mint $COPRA';
        actionBtn.disabled = false;
        return;
      }

      showToast('Minting $COPRA on Base Sepolia...', 'pending');
      const mintTx = await vaultContract.mint(copraWei);
      showToast(`Mint transaction broadcast! Waiting for confirmation...`, 'pending', mintTx.hash);
      await mintTx.wait(1);

      showToast(`🎉 Successfully minted ${CopraQuote.formatUnits(copraWei, 18, 4)} $COPRA!`, 'info', mintTx.hash);
      await refreshBalances();
      await readProtocolTelemetry();
    } else {
      // Redeem flow
      const vaultContract = new ethers.Contract(CONTRACTS.vault, VAULT_ABI, signer);
      const copraWei = CopraQuote.parseUnits(amountInput.value, 18) ?? 0n;
      if (copraWei <= 0n) {
        showToast('Enter a valid $COPRA amount to redeem.', 'warn');
        return;
      }

      showToast('Redeeming $COPRA for USDC...', 'pending');
      const redeemTx = await vaultContract.redeem(copraWei);
      showToast(`Redemption broadcast! Waiting for confirmation...`, 'pending', redeemTx.hash);
      await redeemTx.wait(1);

      showToast(`🎉 Successfully redeemed for USDC!`, 'info', redeemTx.hash);
      await refreshBalances();
      await readProtocolTelemetry();
    }
  } catch (err) {
    console.error('Transaction error:', err);
    showToast('Transaction error: ' + (err.shortMessage || err.message || 'Cancelled'), 'error');
  } finally {
    actionBtn.disabled = false;
    if (mode === 'mint') {
      checkAllowance();
    } else {
      actionBtnText.textContent = userAddress ? 'Redeem USDC' : 'Connect Wallet to Redeem';
    }
  }
});

// --- Testnet Faucet Handler ---
faucetBtn.addEventListener('click', async () => {
  if (!userAddress || !signer) {
    await initWeb3();
    if (!userAddress) return;
  }

  faucetBtn.disabled = true;
  const originalText = faucetBtn.innerHTML;
  faucetBtn.innerHTML = '<span>⏳ Claiming...</span>';

  try {
    const usdcContract = new ethers.Contract(CONTRACTS.usdc, ERC20_ABI, signer);
    showToast('Claiming 1,000 Testnet USDC from faucet...', 'pending');
    const tx = await usdcContract.faucet(userAddress, ethers.parseUnits("1000", 6));
    showToast(`Faucet claim broadcast! Waiting for confirmation...`, 'pending', tx.hash);
    await tx.wait(1);
    showToast('💧 1,000 Testnet USDC successfully claimed into your wallet!', 'info', tx.hash);
    await refreshBalances();
    checkAllowance();
  } catch (err) {
    console.error('Faucet error:', err);
    showToast('Faucet error: ' + (err.shortMessage || err.message), 'error');
  } finally {
    faucetBtn.disabled = false;
    faucetBtn.innerHTML = originalText;
  }
});

connectBtn.addEventListener('click', initWeb3);

// Initial load: read protocol telemetry and perform initial calculation
readProtocolTelemetry();
calculate();

// Listen to account changes
if (window.ethereum) {
  window.ethereum.on('accountsChanged', (accounts) => {
    if (accounts.length > 0) {
      userAddress = accounts[0];
      connectText.textContent = `${userAddress.slice(0, 6)}...${userAddress.slice(-4)}`;
      balanceBar.classList.remove('hidden');
      maxBtn.classList.remove('hidden');
      refreshBalances();
      checkAllowance();
    } else {
      userAddress = null;
      connectText.textContent = 'Connect Wallet';
      balanceBar.classList.add('hidden');
      maxBtn.classList.add('hidden');
    }
  });
  window.ethereum.on('chainChanged', () => window.location.reload());
}

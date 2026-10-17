// Copra Protocol dApp: page state, DOM references, theme, quote preview and toasts.
// Classic script, not a module: its top-level names share the page's global scope with the
// other /assets/*.js files. It only declares; app.js (loaded last) wires events and starts work,
// so nothing here runs before every file has loaded. Load order is fixed in index.html.

// --- State Variables ---
let currentPriceUSD = 1.42;
let currentPriceRaw = 142000000n; // oracle price, 8 decimals; null when the oracle gives none
let priceProblem = null; // why there is no price (stale, unreachable), told to a user who tries to submit
let feeBps = 25n; // 0.25%
let mode = 'mint';
let userAddress = null;
let provider = null;
let signer = null;
let userUsdcBalanceRaw = 0n;
let userCopraBalanceRaw = 0n;

// --- Apply Theme & Hostname Adaptations ---
function applyTheme() {
  if (!isTestnet) return;
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
  if (currentPriceRaw === null) return 0n;
  const usdcRaw = CopraQuote.parseUnits(amountInput.value, 6) ?? 0n;
  return CopraQuote.copraForCollateral(usdcRaw, currentPriceRaw, feeBps);
}

function calculate() {
  if (currentPriceRaw === null) {
    outputAmount.value = '';
    feeDisplay.textContent = '—';
    return;
  }
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

// Ticker badges are built as nodes, not HTML strings, so this file has no HTML-string sinks.
function textSpan(text) {
  const span = document.createElement('span');
  span.textContent = text;
  return span;
}
function copraTicker() {
  const img = document.createElement('img');
  img.src = '/assets/copra_logo_32.png';
  img.alt = 'Copra';
  img.className = 'w-4 h-4 rounded-full';
  return [img, textSpan('COPRA')];
}

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
    inputTicker.replaceChildren(textSpan('USDC'));
    outputTicker.replaceChildren(...copraTicker());
    amountInput.value = '14.20';
    actionBtnText.textContent = userAddress ? 'Mint $COPRA' : 'Connect Wallet to Mint';
  } else {
    tabRedeem.className = activeClass;
    tabMint.className = inactiveClass;
    inputLabel.textContent = 'You Burn ($COPRA)';
    outputLabel.textContent = 'You Receive (USDC)';
    inputTicker.replaceChildren(...copraTicker());
    outputTicker.replaceChildren(textSpan('USDC'));
    amountInput.value = '10.00';
    actionBtnText.textContent = userAddress ? 'Redeem USDC' : 'Connect Wallet to Redeem';
  }
  calculate();
}

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
  if (txHash && CONTRACTS.explorer) {
    const link = document.createElement('a');
    link.href = `${CONTRACTS.explorer}/tx/${encodeURIComponent(txHash)}`;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.className = 'underline mt-1 inline-block text-[11px] font-bold';
    link.textContent = 'View on Basescan ↗';
    txStatus.appendChild(link);
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

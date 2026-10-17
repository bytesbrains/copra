// Copra Protocol dApp entry point. External (not inline) so the CSP needs no 'unsafe-inline' for scripts.
// Loaded last, after ethers, CopraQuote, config.js, ui.js, chain.js and wallet.js (see index.html).
// The only file with load-time side effects: it applies the theme, wires every event and starts
// the registry and telemetry reads. The other files only declare.

applyTheme();
renderNetwork();
const deploymentReady = loadDeployment();

amountInput.addEventListener('input', calculate);
amountInput.addEventListener('input', checkAllowance);
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

watchCopraBtn.addEventListener('click', () => {
  watchToken(CONTRACTS.token, 'COPRA', 18, window.location.origin + '/assets/copra_logo_128.png');
});

watchUsdcBtn.addEventListener('click', () => {
  watchToken(CONTRACTS.usdc, 'USDC', 6, '');
});

actionBtn.addEventListener('click', submitAction);
faucetBtn.addEventListener('click', claimFaucet);
connectBtn.addEventListener('click', initWeb3);

// Initial load: read protocol telemetry and perform initial calculation. Then keep reading it, so the
// price, quote and metrics follow the oracle feeder and other users mid-session (#46).
readProtocolTelemetry();
calculate();
setInterval(readProtocolTelemetry, 15000);

// Listen to account changes
if (window.ethereum) {
  window.ethereum.on('accountsChanged', async (accounts) => {
    if (accounts.length > 0) {
      userAddress = accounts[0];
      // Sign as the account now selected: the old signer would send from an account the wallet left.
      if (provider) {
        try {
          signer = await provider.getSigner(userAddress);
        } catch (e) {
          signer = null;
          console.warn('Could not switch signer:', e);
        }
      }
      connectText.textContent = `${userAddress.slice(0, 6)}...${userAddress.slice(-4)}`;
      balanceBar.classList.remove('hidden');
      maxBtn.classList.remove('hidden');
      refreshBalances();
      checkAllowance();
    } else {
      userAddress = null;
      signer = null;
      connectText.textContent = 'Connect Wallet';
      balanceBar.classList.add('hidden');
      maxBtn.classList.add('hidden');
    }
  });
  window.ethereum.on('chainChanged', () => window.location.reload());
}

// Copra Protocol dApp: wallet connection and the transactions it signs (approve, mint, redeem, faucet).
// Classic script, not a module: its top-level names share the page's global scope with the
// other /assets/*.js files. It only declares; app.js (loaded last) wires events and starts work,
// so nothing here runs before every file has loaded. Load order is fixed in index.html.

// --- Requests the user answers in their wallet ---
// Closing the wallet's window does not reject a request: MetaMask keeps it pending (#76), and the page
// can only wait. After a few seconds, say where the answer is expected. There is one status toast, so
// there is one hint, shared by every request still waiting past the delay (Add COPRA and Add USDC can
// both be pending). It is withdrawn when the last of them settles, putting back what it covered unless
// a newer message replaced it.
const WALLET_HINT_MS = 5000;
const WALLET_HINT = 'Waiting for your answer: open your wallet to confirm or reject this request.';
let walletHint = null; // { el, covered, waiting }: the hint on screen and how many late requests it stands for

async function awaitWallet(request) {
  let late = false;
  const timer = setTimeout(() => {
    late = true;
    if (!walletHint || txStatus.firstChild !== walletHint.el) {
      const covered = { className: txStatus.className, nodes: [...txStatus.childNodes] };
      showToast(WALLET_HINT, 'pending');
      walletHint = { el: txStatus.firstChild, covered, waiting: walletHint?.waiting ?? 0 };
    }
    walletHint.waiting++;
  }, WALLET_HINT_MS);
  try {
    return await request;
  } finally {
    clearTimeout(timer);
    if (late && --walletHint.waiting === 0) {
      if (txStatus.firstChild === walletHint.el) {
        txStatus.className = walletHint.covered.className;
        txStatus.replaceChildren(...walletHint.covered.nodes);
      }
      walletHint = null;
    }
  }
}

// --- Web3 Blockchain Connection & Interactivity ---
async function initWeb3() {
  await deploymentReady;
  if (typeof window.ethereum === 'undefined') {
    showToast(`Please install MetaMask, Coinbase Wallet, or Rabby to interact with Copra Protocol on ${CONTRACTS.chainName}.`, 'warn');
    return;
  }

  try {
    provider = new ethers.BrowserProvider(window.ethereum);
    const accounts = await awaitWallet(provider.send("eth_requestAccounts", []));
    userAddress = accounts[0];

    // Check & enforce network before getting signer
    const network = await provider.getNetwork();
    if (Number(network.chainId) !== CONTRACTS.chainId) {
      try {
        await awaitWallet(window.ethereum.request({
          method: 'wallet_switchEthereumChain',
          params: [{ chainId: CONTRACTS.chainIdHex }]
        }));
      } catch (switchError) {
        if (switchError.code === 4902) {
          await awaitWallet(window.ethereum.request({
            method: 'wallet_addEthereumChain',
            params: [{
              chainId: CONTRACTS.chainIdHex,
              chainName: CONTRACTS.chainName,
              nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
              rpcUrls: [CONTRACTS.rpcUrl],
              blockExplorerUrls: CONTRACTS.explorer ? [CONTRACTS.explorer] : null
            }]
          }));
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
    showToast('Wallet error: ' + errorMessage(err), 'error');
  }
}

// The price or fee moved since the quote on screen. Never ask for a signature on a quote the user has
// not seen: show the new one and let them submit again. (The contract itself has no bound yet: #57.)
async function quoteChanged() {
  await readProtocolTelemetry();
  showToast('The price or fee changed since your quote. The new quote is shown: check it and submit again.', 'warn');
}

// A mined transaction that reverted carries no revert data in ethers, so ask the vault: if its quote
// is now past the bound the user signed (#57), that is what refused it.
async function revertedPastBound(err, boundCrossed) {
  if (err?.code !== 'CALL_EXCEPTION' || !err.receipt || !boundCrossed) return false;
  return boundCrossed().catch(() => false);
}

// --- Action Button (Approve / Mint / Redeem) ---
async function submitAction() {
  if (!userAddress || !signer) {
    await initWeb3();
    return;
  }

  actionBtn.disabled = true;
  actionBtnText.textContent = 'Confirming in wallet...';
  let boundCrossed = null; // set once a mint or redeem is signed with its bound

  try {
    if (quoteProblem()) {
      showToast(quoteProblem(), 'warn');
      return;
    }
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
      // Both the amount and the fee must be the ones shown: a fee change can leave the total unchanged.
      const [collateralRequired, mintFee] = await vaultContract.quoteMint(copraWei);
      const shownMint = CopraQuote.quoteMint(copraWei, currentPriceRaw, feeBps);
      if (collateralRequired !== shownMint.collateralRequired || mintFee !== shownMint.fee) {
        await quoteChanged();
        return;
      }
      const usdcBalance = await usdcContract.balanceOf(userAddress);
      if (usdcBalance < collateralRequired) {
        showToast(`Insufficient USDC: this mint needs ${CopraQuote.formatUnits(collateralRequired, 6)} USDC at the current oracle price.`, 'warn');
        return;
      }
      const allowance = await usdcContract.allowance(userAddress, CONTRACTS.vault);

      if (allowance < collateralRequired) {
        // Approve the amount entered, never an unlimited allowance: the mint spends all but its dust.
        showToast('Requesting USDC approval...', 'pending');
        const appTx = await awaitWallet(usdcContract.approve(CONTRACTS.vault, CopraQuote.parseUnits(amountInput.value, 6)));
        showToast(`Approval submitted. Waiting for confirmation...`, 'pending', appTx.hash);
        await appTx.wait(1);
        showToast('USDC approved! Now click Mint $COPRA.', 'info');
        actionBtnText.textContent = 'Mint $COPRA';
        actionBtn.disabled = false;
        return;
      }

      showToast(`Minting $COPRA on ${CONTRACTS.chainName}...`, 'pending');
      // The quote on screen is the bound: the vault refuses to charge more than the user saw (#57).
      boundCrossed = async () => (await vaultContract.quoteMint(copraWei))[0] > collateralRequired;
      const mintTx = await awaitWallet(vaultContract.mint(copraWei, collateralRequired));
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

      const [collateralToReturn, redeemFee] = await vaultContract.quoteRedeem(copraWei);
      const shownRedeem = CopraQuote.quoteRedeem(copraWei, currentPriceRaw, feeBps);
      if (collateralToReturn !== shownRedeem.collateralToReturn || redeemFee !== shownRedeem.fee) {
        await quoteChanged();
        return;
      }

      showToast('Redeeming $COPRA for USDC...', 'pending');
      boundCrossed = async () => (await vaultContract.quoteRedeem(copraWei))[0] < collateralToReturn;
      const redeemTx = await awaitWallet(vaultContract.redeem(copraWei, collateralToReturn));
      showToast(`Redemption broadcast! Waiting for confirmation...`, 'pending', redeemTx.hash);
      await redeemTx.wait(1);

      showToast(`🎉 Successfully redeemed for USDC!`, 'info', redeemTx.hash);
      await refreshBalances();
      await readProtocolTelemetry();
    }
  } catch (err) {
    console.error('Transaction error:', err);
    if (revertName(err) === 'SlippageExceeded' || await revertedPastBound(err, boundCrossed)) {
      await readProtocolTelemetry();
      showToast(REVERT_MESSAGES.SlippageExceeded, 'warn');
    } else {
      showToast('Transaction error: ' + errorMessage(err), 'error');
    }
  } finally {
    actionBtn.disabled = false;
    if (mode === 'mint') {
      checkAllowance();
    } else {
      actionBtnText.textContent = userAddress ? 'Redeem USDC' : 'Connect Wallet to Redeem';
    }
  }
}

// --- Testnet Faucet ---
async function claimFaucet() {
  if (!CONTRACTS.faucet) return; // the button is hidden then; real USDC has no faucet to call
  if (!userAddress || !signer) {
    await initWeb3();
    if (!userAddress) return;
  }

  faucetBtn.disabled = true;
  const originalLabel = [...faucetBtn.childNodes];
  faucetBtn.replaceChildren(textSpan('⏳ Claiming...'));

  try {
    const usdcContract = new ethers.Contract(CONTRACTS.usdc, ERC20_ABI, signer);
    showToast('Claiming 1,000 Testnet USDC from faucet...', 'pending');
    const tx = await awaitWallet(usdcContract.faucet(userAddress, ethers.parseUnits("1000", 6)));
    showToast(`Faucet claim broadcast! Waiting for confirmation...`, 'pending', tx.hash);
    await tx.wait(1);
    showToast('💧 1,000 Testnet USDC successfully claimed into your wallet!', 'info', tx.hash);
    await refreshBalances();
    checkAllowance();
  } catch (err) {
    console.error('Faucet error:', err);
    showToast('Faucet error: ' + errorMessage(err), 'error');
  } finally {
    faucetBtn.disabled = false;
    faucetBtn.replaceChildren(...originalLabel);
  }
}

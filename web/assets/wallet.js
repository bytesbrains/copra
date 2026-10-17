// Copra Protocol dApp: wallet connection and the transactions it signs (approve, mint, redeem, faucet).
// Classic script, not a module: its top-level names share the page's global scope with the
// other /assets/*.js files. It only declares; app.js (loaded last) wires events and starts work,
// so nothing here runs before every file has loaded. Load order is fixed in index.html.

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
              blockExplorerUrls: CONTRACTS.explorer ? [CONTRACTS.explorer] : null
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
    showToast('Wallet error: ' + errorMessage(err), 'error');
  }
}

// The price or fee moved since the quote on screen. Never ask for a signature on a quote the user has
// not seen: show the new one and let them submit again. (The contract itself has no bound yet: #57.)
async function quoteChanged() {
  await readProtocolTelemetry();
  showToast('The price or fee changed since your quote. The new quote is shown: check it and submit again.', 'warn');
}

// --- Action Button (Approve / Mint / Redeem) ---
async function submitAction() {
  if (!userAddress || !signer) {
    await initWeb3();
    return;
  }

  actionBtn.disabled = true;
  actionBtnText.textContent = 'Confirming in wallet...';

  try {
    if (currentPriceRaw === null) {
      showToast(priceProblem, 'warn');
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

      const [collateralToReturn, redeemFee] = await vaultContract.quoteRedeem(copraWei);
      const shownRedeem = CopraQuote.quoteRedeem(copraWei, currentPriceRaw, feeBps);
      if (collateralToReturn !== shownRedeem.collateralToReturn || redeemFee !== shownRedeem.fee) {
        await quoteChanged();
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
    showToast('Transaction error: ' + errorMessage(err), 'error');
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
    const tx = await usdcContract.faucet(userAddress, ethers.parseUnits("1000", 6));
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

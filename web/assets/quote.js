// Exact integer mirror of CopraVault.quoteMint / quoteRedeem (src/CopraVault.sol).
// All amounts are BigInt base units: USDC 6 decimals, $COPRA 18 decimals, oracle price 8 decimals.
// Floats are never used for amounts sent on-chain: rounding up by a single wei makes
// transferFrom / burn revert when the user spends their whole balance.
(function (root) {
  const BPS = 10000n;
  const PRICE_SCALE = 100000000n; // 1e8
  const COPRA_DECIMALS = 18;
  const USDC_DECIMALS = 6;

  // Parse a non-negative decimal string into base units, truncating excess fraction digits.
  // Returns null for anything that is not a plain decimal (empty, negative, exponent, junk).
  function parseUnits(value, decimals) {
    const m = /^\s*(\d*)(?:\.(\d*))?\s*$/.exec(String(value ?? ''));
    if (!m || (m[1] === '' && (m[2] ?? '') === '')) return null;
    const frac = (m[2] ?? '').slice(0, decimals).padEnd(decimals, '0');
    return BigInt(m[1] || '0') * 10n ** BigInt(decimals) + BigInt(frac || '0');
  }

  // Format base units as a decimal string, always rounding DOWN.
  // With fracDigits, the fraction is truncated and zero-padded to exactly that many digits;
  // without it, the exact value is returned with trailing zeros trimmed.
  function formatUnits(raw, decimals, fracDigits) {
    const scale = 10n ** BigInt(decimals);
    const whole = raw / scale;
    let frac = (raw % scale).toString().padStart(decimals, '0');
    if (fracDigits === undefined) {
      frac = frac.replace(/0+$/, '');
      return frac ? `${whole}.${frac}` : `${whole}`;
    }
    frac = frac.slice(0, fracDigits);
    return fracDigits > 0 ? `${whole}.${frac}` : `${whole}`;
  }

  function baseCollateral(copraWei, price8) {
    const valueUSD18 = (copraWei * price8) / PRICE_SCALE;
    return valueUSD18 / 10n ** BigInt(COPRA_DECIMALS - USDC_DECIMALS);
  }

  function quoteMint(copraWei, price8, feeBps) {
    const base = baseCollateral(copraWei, price8);
    const fee = (base * feeBps) / BPS;
    return { collateralRequired: base + fee, fee };
  }

  function quoteRedeem(copraWei, price8, feeBps) {
    const base = baseCollateral(copraWei, price8);
    const fee = (base * feeBps) / BPS;
    return { collateralToReturn: base - fee, fee };
  }

  // Largest-safe $COPRA amount for a USDC budget: quoteMint(result).collateralRequired <= usdcRaw.
  function copraForCollateral(usdcRaw, price8, feeBps) {
    if (usdcRaw <= 0n || price8 <= 0n) return 0n;
    const scale = 10n ** BigInt(COPRA_DECIMALS - USDC_DECIMALS);
    return (usdcRaw * scale * PRICE_SCALE * BPS) / (price8 * (BPS + feeBps));
  }

  const api = { parseUnits, formatUnits, quoteMint, quoteRedeem, copraForCollateral };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.CopraQuote = api;
})(this);

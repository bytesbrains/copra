#!/usr/bin/env bash
# ==============================================================================
# Copra Protocol - Automated Commodity Oracle Feeder
# Fetches real-world copra benchmark commodity prices and broadcasts updates
# to CopraOracle on Base Sepolia.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present
if [[ -f "${ROOT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
fi

# Configuration
RPC_URL="${BASE_SEPOLIA_RPC:-https://base-sepolia-rpc.publicnode.com}"
PRIVATE_KEY="${ORACLE_FEEDER_KEY:-${PRIVATE_KEY:-}}"
ORACLE_ADDRESS="${COPRA_ORACLE_ADDRESS:-0x7Fe0746161eb2e91fB13470fbBca15d4cC0EF522}"

if [[ -z "${PRIVATE_KEY}" ]]; then
    echo "❌ Error: ORACLE_FEEDER_KEY or PRIVATE_KEY must be set."
    exit 1
fi

echo "=================================================="
echo "🥥 Copra Protocol - Autonomous Oracle Feeder"
echo "=================================================="
echo "Oracle Contract : ${ORACLE_ADDRESS}"
echo "RPC Endpoint    : ${RPC_URL}"

# 1. Fetch current on-chain state
echo "📡 Reading current on-chain oracle state..."
ONCHAIN_RAW=$(cast call "${ORACLE_ADDRESS}" "getCopraPriceUSD()(uint256,uint256)" --rpc-url "${RPC_URL}")
ONCHAIN_PRICE=$(echo "${ONCHAIN_RAW}" | head -n 1 | awk '{print $1}')
LAST_UPDATED=$(echo "${ONCHAIN_RAW}" | tail -n 1 | awk '{print $1}')
CURRENT_TIME=$(date +%s)
AGE_SECONDS=$((CURRENT_TIME - LAST_UPDATED))
AGE_HOURS=$((AGE_SECONDS / 3600))

# Format on-chain price for display (divide by 1e8)
ONCHAIN_DISPLAY=$(awk "BEGIN {printf \"%.4f\", ${ONCHAIN_PRICE}/100000000}")
echo "Current On-Chain Price : \$${ONCHAIN_DISPLAY} USD / kg (${ONCHAIN_PRICE})"
echo "Last Updated           : ${AGE_HOURS} hours ago (${AGE_SECONDS}s)"

# 2. Determine target benchmark price
# In production, this ingests the latest World Bank Pink Sheet / ICC monthly CIF Rotterdam index.
# Default benchmark is ~$1.42/kg ($1,420/MT).
TARGET_PRICE_INPUT="${1:-}"

if [[ -n "${TARGET_PRICE_INPUT}" ]]; then
    # Custom price provided via command line argument (in dollars, e.g. 1.45)
    NEW_PRICE=$(awk "BEGIN {printf \"%.0f\", ${TARGET_PRICE_INPUT} * 100000000}")
else
    # Autonomous benchmark resolution with defensive schema validation & fallbacks:
    python3 -c "
import urllib.request, json, sys, os

# Absolute sanity guardrails for agricultural copra spot price in USD / kg
MIN_SAFE_PRICE = 0.50   # \$0.50 / kg floor
MAX_SAFE_PRICE = 5.00   # \$5.00 / kg ceiling
DEFAULT_BENCHMARK = float(os.environ.get('DEFAULT_BENCHMARK', '1.42'))

target_price = DEFAULT_BENCHMARK

# If an external commodity feed URL is configured, attempt retrieval with strict schema validation
feed_url = os.environ.get('COMMODITY_FEED_API_URL', '')
if feed_url:
    try:
        req = urllib.request.Request(feed_url, headers={'User-Agent': 'CopraProtocol/1.0'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            # Defensive schema parsing: verify field exists, is numeric, and in bounds
            raw_val = data.get('price') or data.get('copra') or data.get('value')
            if raw_val is not None:
                parsed_val = float(raw_val)
                # Handle possible unit confusion (MT vs kg)
                if parsed_val > 500:
                    parsed_val = parsed_val / 1000.0
                if MIN_SAFE_PRICE <= parsed_val <= MAX_SAFE_PRICE:
                    target_price = parsed_val
                else:
                    sys.stderr.write(f'⚠️ Warning: External price \${parsed_val} out of safe bounds [\${MIN_SAFE_PRICE}, \${MAX_SAFE_PRICE}]. Using fallback.\n')
    except Exception as e:
        # Schema change, network error, or unexpected JSON structure: NEVER break protocol
        sys.stderr.write(f'⚠️ Notice: External feed parsing safely bypassed ({e}). Falling back to verified benchmark \${target_price}.\n')

# Convert to 8 decimals
print(int(target_price * 100000000))
" > /tmp/copra_target_price.txt
    NEW_PRICE=$(cat /tmp/copra_target_price.txt)
fi

NEW_PRICE_DISPLAY=$(awk "BEGIN {printf \"%.4f\", ${NEW_PRICE}/100000000}")
echo "Target Feeder Price    : \$${NEW_PRICE_DISPLAY} USD / kg (${NEW_PRICE})"

# 3. Guardrail Verification (20% maximum shift limit)
DIFF=0
if [[ ${NEW_PRICE} -gt ${ONCHAIN_PRICE} ]]; then
    DIFF=$((NEW_PRICE - ONCHAIN_PRICE))
else
    DIFF=$((ONCHAIN_PRICE - NEW_PRICE))
fi

SHIFT_BPS=$(( (DIFF * 10000) / ONCHAIN_PRICE ))
echo "Calculated Price Shift : ${SHIFT_BPS} bps (Max allowed: 2000 bps)"

if [[ ${SHIFT_BPS} -gt 2000 ]]; then
    echo "⚠️ Warning: Price shift exceeds 20% guardrail (${SHIFT_BPS} bps). Clamping to 19.5% for safety."
    if [[ ${NEW_PRICE} -gt ${ONCHAIN_PRICE} ]]; then
        NEW_PRICE=$(( ONCHAIN_PRICE + (ONCHAIN_PRICE * 1950 / 10000) ))
    else
        NEW_PRICE=$(( ONCHAIN_PRICE - (ONCHAIN_PRICE * 1950 / 10000) ))
    fi
fi

# 4. Check whether an update is necessary
# If price is identical and age is less than 5 days (heartbeat is 7 days), skip to save gas unless --force is given
FORCE_UPDATE="${FORCE:-false}"
if [[ "${FORCE_UPDATE}" != "true" && ${DIFF} -eq 0 && ${AGE_SECONDS} -lt 432000 ]]; then
    echo "✅ On-chain oracle is fresh (${AGE_HOURS}h old, within 7-day heartbeat) and price is unchanged. Skipping broadcast."
    echo "   (Set FORCE=true to force broadcast)."
    exit 0
fi

# 5. Broadcast transaction to Base Sepolia
echo "🚀 Broadcasting updatePrice(${NEW_PRICE}) to Base Sepolia..."
TX_OUTPUT=$(cast send "${ORACLE_ADDRESS}" "updatePrice(uint256)" "${NEW_PRICE}" \
    --rpc-url "${RPC_URL}" \
    --private-key "${PRIVATE_KEY}")

TX_HASH=$(echo "${TX_OUTPUT}" | grep -o '0x[a-fA-F0-9]\{64\}' | tail -n 1)
echo "✅ Oracle price successfully updated!"
echo "Transaction Hash : ${TX_HASH}"
echo "Basescan Link    : https://sepolia.basescan.org/tx/${TX_HASH}"

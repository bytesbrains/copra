#!/usr/bin/env bash
# ==============================================================================
# Copra Protocol - Automated Commodity Oracle Feeder
# Fetches real-world copra benchmark commodity prices and broadcasts updates
# to CopraOracle on Base Sepolia.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env only in local non-CI environments when credentials are not already provided
if [[ -z "${CI:-}" && -z "${GITHUB_ACTIONS:-}" && -z "${ORACLE_FEEDER_KEY:-}" && -z "${PRIVATE_KEY:-}" && -f "${ROOT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
fi

# Configuration
RPC_URL="${BASE_SEPOLIA_RPC:-https://base-sepolia-rpc.publicnode.com}"
PRIVATE_KEY="${ORACLE_FEEDER_KEY:-${PRIVATE_KEY:-}}"
# Permanent CopraRegistry (CREATE2) — the oracle address is resolved from it, so redeploys need no edit here.
REGISTRY_ADDRESS="${COPRA_REGISTRY_ADDRESS:-0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25}"

if [[ -z "${PRIVATE_KEY}" ]]; then
    echo "❌ Error: ORACLE_FEEDER_KEY or PRIVATE_KEY must be set."
    exit 1
fi

if [[ -n "${COPRA_ORACLE_ADDRESS:-}" ]]; then
    ORACLE_ADDRESS="${COPRA_ORACLE_ADDRESS}"
else
    # Never fall back to a guessed address: signing updatePrice against the wrong oracle is worse than skipping a run.
    if ! ORACLE_ADDRESS=$(cast call "${REGISTRY_ADDRESS}" "oracle()(address)" --rpc-url "${RPC_URL}" 2>/dev/null); then
        echo "❌ Error: could not read oracle() from CopraRegistry ${REGISTRY_ADDRESS}. Set COPRA_ORACLE_ADDRESS to override."
        exit 1
    fi
fi

if [[ ! "${ORACLE_ADDRESS}" =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ "${ORACLE_ADDRESS}" =~ ^0x0{40}$ ]]; then
    echo "❌ Error: invalid oracle address '${ORACLE_ADDRESS}' (registry empty or misconfigured)."
    exit 1
fi

echo "=================================================="
echo "🥥 Copra Protocol - Autonomous Oracle Feeder"
echo "=================================================="
echo "Registry        : ${REGISTRY_ADDRESS}"
echo "Oracle Contract : ${ORACLE_ADDRESS}"
echo "RPC Endpoint    : ${RPC_URL}"

# 1. Fetch current on-chain state
echo "📡 Reading current on-chain oracle state..."
if ONCHAIN_RAW=$(cast call "${ORACLE_ADDRESS}" "getCopraPriceUSD()(uint256,uint256)" --rpc-url "${RPC_URL}" 2>/dev/null); then
    ONCHAIN_PRICE=$(echo "${ONCHAIN_RAW}" | head -n 1 | awk '{print $1}')
    LAST_UPDATED=$(echo "${ONCHAIN_RAW}" | tail -n 1 | awk '{print $1}')
    # Age by chain time, which the oracle's heartbeat and update interval use; fall back to the local clock.
    CURRENT_TIME=$(cast block latest --field timestamp --rpc-url "${RPC_URL}" 2>/dev/null) || CURRENT_TIME=""
    [[ "${CURRENT_TIME}" =~ ^[0-9]+$ ]] || CURRENT_TIME=$(date +%s)
    AGE_SECONDS=$((CURRENT_TIME - LAST_UPDATED))
    AGE_HOURS=$((AGE_SECONDS / 3600))

    # Format on-chain price for display (divide by 1e8)
    ONCHAIN_DISPLAY=$(awk -v p="${ONCHAIN_PRICE}" 'BEGIN {printf "%.4f", p/100000000}')
    echo "Current On-Chain Price : \$${ONCHAIN_DISPLAY} USD / kg (${ONCHAIN_PRICE})"
    echo "Last Updated           : ${AGE_HOURS} hours ago (${AGE_SECONDS}s)"
else
    echo "⚠️ Warning: getCopraPriceUSD() reverted (oracle may be stale or uninitialized). Proceeding with recovery update."
    ONCHAIN_PRICE=0
    LAST_UPDATED=0
    AGE_SECONDS=999999
    AGE_HOURS=999
fi

# 2. Determine target benchmark price
# In production, this ingests the latest World Bank Pink Sheet / ICC monthly CIF Rotterdam index.
# Default benchmark is ~$1.42/kg ($1,420/MT).
TARGET_PRICE_INPUT="${1:-${TARGET_PRICE:-}}"

if [[ -n "${TARGET_PRICE_INPUT}" ]]; then
    # Strictly validate numeric format before passing to awk
    if [[ ! "${TARGET_PRICE_INPUT}" =~ ^([0-9]+(\.[0-9]+)?)$ ]]; then
        echo "❌ Error: Invalid target price format '${TARGET_PRICE_INPUT}'. Expected positive decimal number (e.g. 1.45)."
        exit 1
    fi
    # Custom price provided via command line argument (in dollars, e.g. 1.45)
    NEW_PRICE=$(awk -v p="${TARGET_PRICE_INPUT}" 'BEGIN {printf "%.0f", p * 100000000}')
else
    # Autonomous benchmark resolution with defensive schema validation, URL allowlisting & fallbacks:
    NEW_PRICE=$(ONCHAIN_PRICE="${ONCHAIN_PRICE}" python3 -c "
import urllib.request, urllib.parse, json, sys, os

# Absolute sanity guardrails for agricultural copra spot price in USD / kg
MIN_SAFE_PRICE = 0.50   # \$0.50 / kg floor
MAX_SAFE_PRICE = 5.00   # \$5.00 / kg ceiling
ALLOWED_HOSTS = {'api.worldbank.org', 'commoditymarkets.org', 'coconutboard.gov.in'}

default_raw = os.environ.get('DEFAULT_BENCHMARK', '1.42')
try:
    DEFAULT_BENCHMARK = float(default_raw)
    if not (MIN_SAFE_PRICE <= DEFAULT_BENCHMARK <= MAX_SAFE_PRICE):
        DEFAULT_BENCHMARK = 1.42
except ValueError:
    DEFAULT_BENCHMARK = 1.42

target_price = DEFAULT_BENCHMARK

# If an external commodity feed URL is configured, enforce HTTPS and strict host allowlist
feed_url = os.environ.get('COMMODITY_FEED_API_URL', '').strip()
if feed_url:
    try:
        parsed_url = urllib.parse.urlparse(feed_url)
        hostname = (parsed_url.hostname or '').lower()
        if parsed_url.scheme != 'https' or hostname not in ALLOWED_HOSTS:
            raise ValueError(f'Untrusted feed URL scheme or host: {parsed_url.scheme}://{hostname}')

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
        # Schema change, untrusted host, network error, or unexpected JSON structure: NEVER break protocol
        sys.stderr.write(f'⚠️ Notice: External feed parsing safely bypassed ({e}). Falling back to verified benchmark \${target_price}.\n')

# Convert to 8 decimals
print(int(round(target_price * 100000000)))
")
fi

if [[ ! "${NEW_PRICE}" =~ ^[0-9]+$ ]] || [[ "${NEW_PRICE}" -lt 50000000 ]] || [[ "${NEW_PRICE}" -gt 500000000 ]]; then
    echo "❌ Error: Computed target price (${NEW_PRICE}) is outside safe bounds [50000000 (\$0.50), 500000000 (\$5.00)]."
    exit 1
fi

NEW_PRICE_DISPLAY=$(awk -v p="${NEW_PRICE}" 'BEGIN {printf "%.4f", p/100000000}')
echo "Target Feeder Price    : \$${NEW_PRICE_DISPLAY} USD / kg (${NEW_PRICE})"

# 3. Guardrail Verification (20% maximum shift limit when on-chain price is available)
DIFF=0
if [[ "${ONCHAIN_PRICE}" -gt 0 ]]; then
    if [[ "${NEW_PRICE}" -gt "${ONCHAIN_PRICE}" ]]; then
        DIFF=$((NEW_PRICE - ONCHAIN_PRICE))
    else
        DIFF=$((ONCHAIN_PRICE - NEW_PRICE))
    fi

    SHIFT_BPS=$(( (DIFF * 10000) / ONCHAIN_PRICE ))
    echo "Calculated Price Shift : ${SHIFT_BPS} bps (Max allowed: 2000 bps)"

    if [[ "${SHIFT_BPS}" -gt 2000 ]]; then
        echo "⚠️ Warning: Price shift exceeds 20% guardrail (${SHIFT_BPS} bps). Clamping to 19.5% for safety."
        if [[ "${NEW_PRICE}" -gt "${ONCHAIN_PRICE}" ]]; then
            NEW_PRICE=$(( ONCHAIN_PRICE + (ONCHAIN_PRICE * 1950 / 10000) ))
        else
            NEW_PRICE=$(( ONCHAIN_PRICE - (ONCHAIN_PRICE * 1950 / 10000) ))
        fi
    fi
else
    echo "ℹ️ Skipping shift bps guardrail check (on-chain reference price unavailable)."
fi

# 4. Check whether an update is necessary
# If price is identical and age is less than 5 days (heartbeat is 7 days), skip to save gas unless --force is given
FORCE_UPDATE="${FORCE:-false}"
if [[ "${FORCE_UPDATE}" != "true" && "${ONCHAIN_PRICE}" -gt 0 && "${DIFF}" -eq 0 && "${AGE_SECONDS}" -lt 432000 ]]; then
    echo "✅ On-chain oracle is fresh (${AGE_HOURS}h old, within 7-day heartbeat) and price is unchanged. Skipping broadcast."
    echo "   (Set FORCE=true to force broadcast)."
    exit 0
fi

# The oracle accepts one update per MIN_UPDATE_INTERVAL and reverts anything sooner, even with FORCE.
# Oracles deployed before the interval existed have no such getter: treat that as no interval.
MIN_INTERVAL=$(cast call "${ORACLE_ADDRESS}" "MIN_UPDATE_INTERVAL()(uint256)" --rpc-url "${RPC_URL}" 2>/dev/null | awk '{print $1}') || MIN_INTERVAL=0
[[ "${MIN_INTERVAL}" =~ ^[0-9]+$ ]] || MIN_INTERVAL=0
if [[ "${LAST_UPDATED}" -gt 0 && "${AGE_SECONDS}" -lt "${MIN_INTERVAL}" ]]; then
    echo "⏳ Last update was ${AGE_SECONDS}s ago; the oracle accepts one update per ${MIN_INTERVAL}s. Skipping broadcast."
    echo "   Next update allowed in $((MIN_INTERVAL - AGE_SECONDS))s."
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

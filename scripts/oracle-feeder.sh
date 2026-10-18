#!/usr/bin/env bash
# ==============================================================================
# Copra Protocol - Automated Commodity Oracle Feeder
# Posts a copra price to CopraOracle on Base Sepolia: a manual override, or an
# observation from a declared source (scripts/oracle_feeder.py), never a default.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env only in local non-CI environments when credentials are not already provided
if [[ -z "${CI:-}" && -z "${GITHUB_ACTIONS:-}" && -z "${ORACLE_FEEDER_KEY:-}" && -z "${PRIVATE_KEY:-}" && -z "${ORACLE_FEEDER_FROM:-}" && -f "${ROOT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
fi

# Configuration
RPC_URL="${BASE_SEPOLIA_RPC:-https://base-sepolia-rpc.publicnode.com}"
PRIVATE_KEY="${ORACLE_FEEDER_KEY:-${PRIVATE_KEY:-}}"
# Permanent CopraRegistry (CREATE2) — the oracle address is resolved from it, so redeploys need no edit here.
REGISTRY_ADDRESS="${COPRA_REGISTRY_ADDRESS:-0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25}"

# Local chains only: sign as ORACLE_FEEDER_FROM, an account the node holds unlocked (the e2e stack
# impersonates the production updater, whose key never leaves the oracle-feeder environment).
# Mirrors DeployCopra.runUnlocked(). A real RPC holds no unlocked accounts, so this cannot sign there.
# Never both: a stray ORACLE_FEEDER_FROM beside a key would otherwise win and fail only at the broadcast.
if [[ -n "${ORACLE_FEEDER_FROM:-}" && -n "${PRIVATE_KEY}" ]]; then
    echo "❌ Error: ORACLE_FEEDER_FROM and ORACLE_FEEDER_KEY/PRIVATE_KEY are both set; set only one signer."
    exit 1
elif [[ -n "${ORACLE_FEEDER_FROM:-}" ]]; then
    SIGNER_ARGS=(--unlocked --from "${ORACLE_FEEDER_FROM}")
elif [[ -n "${PRIVATE_KEY}" ]]; then
    SIGNER_ARGS=(--private-key "${PRIVATE_KEY}")
else
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

# A failed `cast call` is either the oracle answering with a revert or the RPC not answering at all.
# Only the first tells us anything about the oracle, so keep the error to tell them apart.
CAST_ERR="$(mktemp)"
trap 'rm -f "${CAST_ERR}"' EXIT
STALE_PRICE_SELECTOR="0x19abf40e" # CopraOracle.StalePrice()
HEARTBEAT=604800                   # CopraOracle.HEARTBEAT (7 days), pinned by test_Oracle_StorageLayoutReadByFeeder

# Chain time, which the oracle's heartbeat and update interval use; falls back to the local clock.
chain_time() {
    local t
    t=$(cast block latest --field timestamp --rpc-url "${RPC_URL}" 2>/dev/null) || t=""
    [[ "${t}" =~ ^[0-9]+$ ]] || t=$(date +%s)
    echo "${t}"
}

# 1. Fetch current on-chain state
echo "📡 Reading current on-chain oracle state..."
if ONCHAIN_RAW=$(cast call "${ORACLE_ADDRESS}" "getCopraPriceUSD()(uint256,uint256)" --rpc-url "${RPC_URL}" 2>"${CAST_ERR}"); then
    ONCHAIN_PRICE=$(echo "${ONCHAIN_RAW}" | head -n 1 | awk '{print $1}')
    LAST_UPDATED=$(echo "${ONCHAIN_RAW}" | tail -n 1 | awk '{print $1}')
    AGE_SECONDS=$(( $(chain_time) - LAST_UPDATED))
    AGE_HOURS=$((AGE_SECONDS / 3600))

    # Format on-chain price for display (divide by 1e8)
    ONCHAIN_DISPLAY=$(awk -v p="${ONCHAIN_PRICE}" 'BEGIN {printf "%.4f", p/100000000}')
    echo "Current On-Chain Price : \$${ONCHAIN_DISPLAY} USD / kg (${ONCHAIN_PRICE})"
    echo "Last Updated           : ${AGE_HOURS} hours ago (${AGE_SECONDS}s)"
elif grep -q "${STALE_PRICE_SELECTOR}" "${CAST_ERR}"; then
    # Stale means the last update is older than HEARTBEAT, so MIN_UPDATE_INTERVAL has long passed.
    # The oracle still enforces the 20% shift limit against its stored price, so a recovery update further
    # away would revert; the feeder checks it first and refuses. The getter refuses to return
    # a stale price; read it from storage instead (slot 0 copraPriceUSD, slot 1 lastUpdatedAt, pinned by
    # test_Oracle_StorageLayoutReadByFeeder). If the layout ever moves, the reads must fail closed rather
    # than check against garbage: the price must sit in the feeder's own safe band, and the age must agree
    # with the getter's verdict that the oracle is past HEARTBEAT.
    echo "⚠️ Warning: getCopraPriceUSD() reverted with StalePrice. Proceeding with recovery update."
    if ! ONCHAIN_PRICE=$(cast storage "${ORACLE_ADDRESS}" 0 --rpc-url "${RPC_URL}" 2>"${CAST_ERR}" | cast to-dec) \
        || ! LAST_UPDATED=$(cast storage "${ORACLE_ADDRESS}" 1 --rpc-url "${RPC_URL}" 2>"${CAST_ERR}" | cast to-dec) \
        || [[ ! "${ONCHAIN_PRICE}" =~ ^[1-9][0-9]*$ ]] || [[ ! "${LAST_UPDATED}" =~ ^[0-9]+$ ]]; then
        echo "❌ Error: could not read the stale price from ${ORACLE_ADDRESS} storage: $(head -n 1 "${CAST_ERR}")"
        exit 1
    fi
    AGE_SECONDS=$(( $(chain_time) - LAST_UPDATED))
    AGE_HOURS=$((AGE_SECONDS / 3600))
    if [[ "${ONCHAIN_PRICE}" -lt 50000000 || "${ONCHAIN_PRICE}" -gt 500000000 || "${AGE_SECONDS}" -le "${HEARTBEAT}" ]]; then
        echo "❌ Error: implausible stale state in ${ORACLE_ADDRESS} storage (price ${ONCHAIN_PRICE}, age ${AGE_SECONDS}s); has the storage layout changed?"
        exit 1
    fi
    ONCHAIN_DISPLAY=$(awk -v p="${ONCHAIN_PRICE}" 'BEGIN {printf "%.4f", p/100000000}')
    echo "Last On-Chain Price    : \$${ONCHAIN_DISPLAY} USD / kg (${ONCHAIN_PRICE}), stale"
    echo "Last Updated           : ${AGE_HOURS} hours ago (${AGE_SECONDS}s)"
else
    # Never broadcast blind: without the oracle's state we cannot honour the interval or the shift guardrail.
    echo "❌ Error: could not read getCopraPriceUSD() from ${ORACLE_ADDRESS}: $(head -n 1 "${CAST_ERR}")"
    exit 1
fi

# 2. Determine the price, and where it came from
# The feeder never posts a default. A price comes from a manual override (TARGET_PRICE, or the first argument),
# or from a declared source (COMMODITY_FEED_API_URL, resolved by oracle_feeder.py). With neither, or with a
# source that fails, the run fails and nothing is broadcast: the oracle goes stale after HEARTBEAT, and mint
# and redeem revert, which is the safe state (GCPI-001 Invariants 5 and 10).
TARGET_PRICE_INPUT="${1:-${TARGET_PRICE:-}}"
FEED_URL="${COMMODITY_FEED_API_URL:-}"
FORCE_UPDATE="${FORCE:-false}"

if [[ "${FORCE_UPDATE}" == "true" && -z "${TARGET_PRICE_INPUT}" ]]; then
    echo "❌ Error: FORCE re-posts a manual TARGET_PRICE only; a source observation is never re-posted to look fresh."
    exit 1
fi

if [[ -n "${TARGET_PRICE_INPUT}" ]]; then
    # Strictly validate numeric format before passing to awk
    if [[ ! "${TARGET_PRICE_INPUT}" =~ ^([0-9]+(\.[0-9]+)?)$ ]]; then
        echo "❌ Error: Invalid target price format '${TARGET_PRICE_INPUT}'. Expected positive decimal number (e.g. 1.45)."
        exit 1
    fi
    # Manual override, in dollars per kg (e.g. 1.45). Recorded as such: no source published it.
    NEW_PRICE=$(awk -v p="${TARGET_PRICE_INPUT}" 'BEGIN {printf "%.0f", p * 100000000}')
    ACTOR="${GITHUB_ACTOR:-local}"
    [[ "${ACTOR}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]] || ACTOR="unknown"
    # Serialized, not interpolated: the record stays valid JSON whatever the inputs hold (#101 review).
    PROVENANCE=$(python3 -c 'import json, sys
_, actor, price_e8, raw, at = sys.argv
print(json.dumps({"source": "manual override", "entered_by": actor, "price_e8": int(price_e8),
                  "raw_value": raw, "unit": "USD/kg", "retrieved_at": at}, sort_keys=True))' \
        "${ACTOR}" "${NEW_PRICE}" "${TARGET_PRICE_INPUT}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    echo "Price Source           : manual override by ${ACTOR}"
elif [[ -n "${FEED_URL}" ]]; then
    if ! PROVENANCE=$(python3 "${SCRIPT_DIR}/oracle_feeder.py" "${FEED_URL}" 2>"${CAST_ERR}"); then
        echo "❌ Error: price source failed, not broadcasting: $(head -n 1 "${CAST_ERR}")"
        exit 1
    fi
    NEW_PRICE=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["price_e8"])' <<< "${PROVENANCE}")
    echo "Price Source           : ${FEED_URL}"
else
    echo "❌ Error: no price source. Set COMMODITY_FEED_API_URL to a declared source, or TARGET_PRICE for a manual override."
    echo "   The feeder never posts a default price."
    exit 1
fi

if [[ ! "${NEW_PRICE}" =~ ^[0-9]+$ ]] || [[ "${NEW_PRICE}" -lt 50000000 ]] || [[ "${NEW_PRICE}" -gt 500000000 ]]; then
    echo "❌ Error: Computed target price (${NEW_PRICE}) is outside safe bounds [50000000 (\$0.50), 500000000 (\$5.00)]."
    exit 1
fi

NEW_PRICE_DISPLAY=$(awk -v p="${NEW_PRICE}" 'BEGIN {printf "%.4f", p/100000000}')
echo "Target Feeder Price    : \$${NEW_PRICE_DISPLAY} USD / kg (${NEW_PRICE})"
echo "Provenance             : ${PROVENANCE}"

# 3. Guardrail: the oracle reverts a move of more than 20% from its stored price, stale or not.
# A larger move is refused, never clamped: a clamped price is one no source published (GCPI-001 §7.6).
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
        echo "❌ Error: price shift of ${SHIFT_BPS} bps exceeds the oracle's 20% limit. Not broadcasting, and not clamping:"
        echo "   a clamped price is one no source published. If the move is real, step it with manual overrides."
        exit 1
    fi
else
    echo "ℹ️ Skipping shift bps guardrail check (on-chain reference price unavailable)."
fi

# 4. Check whether an update is necessary
# An unchanged price is never re-posted just to refresh updatedAt: that would present an old observation
# as a new one (GCPI-001 §8.2). Only an explicit manual override with FORCE=true re-posts it.
if [[ "${ONCHAIN_PRICE}" -gt 0 && "${DIFF}" -eq 0 && "${FORCE_UPDATE}" != "true" ]]; then
    echo "✅ On-chain oracle is ${AGE_HOURS}h old and the price is unchanged. Skipping broadcast."
    echo "   An unchanged price is not re-posted; the oracle goes stale after its 7-day heartbeat instead."
    exit 0
fi

# The oracle accepts one update per MIN_UPDATE_INTERVAL and reverts anything sooner, even with FORCE.
# Oracles deployed before the interval existed have no such getter (the call reverts): treat that as no interval.
if MIN_INTERVAL=$(cast call "${ORACLE_ADDRESS}" "MIN_UPDATE_INTERVAL()(uint256)" --rpc-url "${RPC_URL}" 2>"${CAST_ERR}"); then
    MIN_INTERVAL=$(echo "${MIN_INTERVAL}" | awk '{print $1}')
elif grep -q "execution reverted" "${CAST_ERR}"; then
    MIN_INTERVAL=0
else
    echo "❌ Error: could not read MIN_UPDATE_INTERVAL() from ${ORACLE_ADDRESS}: $(head -n 1 "${CAST_ERR}")"
    exit 1
fi
if [[ ! "${MIN_INTERVAL}" =~ ^[0-9]+$ ]]; then
    echo "❌ Error: unexpected MIN_UPDATE_INTERVAL() value '${MIN_INTERVAL}'."
    exit 1
fi
if [[ "${LAST_UPDATED}" -gt 0 && "${AGE_SECONDS}" -lt "${MIN_INTERVAL}" ]]; then
    echo "⏳ Last update was ${AGE_SECONDS}s ago; the oracle accepts one update per ${MIN_INTERVAL}s. Skipping broadcast."
    echo "   Next update allowed in $((MIN_INTERVAL - AGE_SECONDS))s."
    exit 0
fi

# 5. Broadcast transaction to Base Sepolia
echo "🚀 Broadcasting updatePrice(${NEW_PRICE}) to Base Sepolia..."
TX_OUTPUT=$(cast send "${ORACLE_ADDRESS}" "updatePrice(uint256)" "${NEW_PRICE}" \
    --rpc-url "${RPC_URL}" \
    "${SIGNER_ARGS[@]}")

TX_HASH=$(echo "${TX_OUTPUT}" | grep -o '0x[a-fA-F0-9]\{64\}' | tail -n 1)
echo "✅ Oracle price successfully updated!"
echo "Transaction Hash : ${TX_HASH}"
echo "Basescan Link    : https://sepolia.basescan.org/tx/${TX_HASH}"

# The provenance record of this update, beside its transaction (#85): one shape in the log and the summary.
# TX_HASH is hex from the grep above and PROVENANCE is already serialized JSON, so this stays valid JSON.
RECORD="{\"tx\": \"${TX_HASH}\", \"observation\": ${PROVENANCE}}"
echo "Provenance Record: ${RECORD}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### Oracle update"
        echo
        echo "Transaction: [${TX_HASH}](https://sepolia.basescan.org/tx/${TX_HASH})"
        echo
        echo '```json'
        echo "${RECORD}"
        echo '```'
    } >> "${GITHUB_STEP_SUMMARY}"
fi

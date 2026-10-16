#!/usr/bin/env bash
# Runs scripts/oracle-feeder.sh against a CopraOracle on a local anvil chain. Pins that the feeder
# skips inside MIN_UPDATE_INTERVAL, recovers a stale oracle, handles oracles without the interval
# getter, and never broadcasts when the RPC fails: a revert is an answer, an unreachable RPC is not.
# The updater key is read from anvil's output at runtime so no key-shaped string is ever committed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
ANVIL_PID=""
# shellcheck disable=SC2329 # invoked by the trap
cleanup() {
    if [[ -n "${ANVIL_PID}" ]]; then kill "${ANVIL_PID}" 2>/dev/null || true; fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

PORT=$((20000 + RANDOM % 20000))
RPC="http://127.0.0.1:${PORT}"
anvil --port "${PORT}" > "${WORK}/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 50); do
    cast chain-id --rpc-url "${RPC}" > /dev/null 2>&1 && break
    sleep 0.2
done

UPDATER_KEY=$(sed -n '/Private Keys/,$p' "${WORK}/anvil.log" | awk '/^\(0\) 0x/{print $2; exit}')
UPDATER=$(cast wallet address --private-key "${UPDATER_KEY}")
ORACLE=$(cd "${ROOT_DIR}" && forge create src/CopraOracle.sol:CopraOracle --rpc-url "${RPC}" \
    --private-key "${UPDATER_KEY}" --broadcast --constructor-args "${UPDATER}" 142000000 2>&1 \
    | awk '/Deployed to/{print $3}')

# Wraps the real cast so the MIN_UPDATE_INTERVAL() read alone can fail like an RPC outage or a revert.
REAL_CAST="$(command -v cast)"
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/cast" <<EOF
#!/usr/bin/env bash
if [[ -n "\${FAKE_INTERVAL_ERROR:-}" && "\$*" == *"MIN_UPDATE_INTERVAL()"* ]]; then
    echo "\${FAKE_INTERVAL_ERROR}" >&2
    exit 1
fi
exec "${REAL_CAST}" "\$@"
EOF
chmod +x "${WORK}/bin/cast"

FAILED=0
# feed <name> <expected exit> <expected output substring> [env assignments...]
feed() {
    local name="$1" want_exit="$2" want_out="$3"
    shift 3
    local out code=0
    out=$(env CI=1 PATH="${WORK}/bin:${PATH}" ORACLE_FEEDER_KEY="${UPDATER_KEY}" COPRA_ORACLE_ADDRESS="${ORACLE}" \
        BASE_SEPOLIA_RPC="${RPC}" TARGET_PRICE=1.45 "$@" "${ROOT_DIR}/scripts/oracle-feeder.sh" 2>&1) || code=$?
    if [[ "${code}" -ne "${want_exit}" || "${out}" != *"${want_out}"* ]]; then
        echo "FAIL: ${name} (exit ${code}, want ${want_exit}; want output containing '${want_out}')"
        printf '    %s\n' "${out//$'\n'/$'\n'    }"
        FAILED=1
    elif [[ "${want_exit}" -ne 0 && "${out}" == *"Broadcasting"* ]]; then
        echo "FAIL: ${name} broadcast despite failing"
        FAILED=1
    else
        echo "PASS: ${name}"
    fi
}

age_past_heartbeat() {
    cast rpc evm_increaseTime 700000 --rpc-url "${RPC}" > /dev/null
    cast rpc evm_mine --rpc-url "${RPC}" > /dev/null
}

feed "skips inside MIN_UPDATE_INTERVAL" 0 "accepts one update per 86400s"
feed "refuses to broadcast when the RPC is unreachable" 1 "could not read getCopraPriceUSD()" \
    BASE_SEPOLIA_RPC="http://127.0.0.1:1"
feed "refuses to broadcast when the interval read fails" 1 "could not read MIN_UPDATE_INTERVAL()" \
    FAKE_INTERVAL_ERROR="Error: error sending request for url (${RPC}/)"

age_past_heartbeat
feed "treats a reverting interval getter as a pre-interval oracle" 0 "successfully updated" \
    FAKE_INTERVAL_ERROR='Error: server returned an error response: error code 3: execution reverted, data: "0x"'

age_past_heartbeat
feed "recovers a stale oracle" 0 "successfully updated"

exit "${FAILED}"

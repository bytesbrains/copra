#!/usr/bin/env bash
# Oracle feeder scenarios (#45): runs scripts/oracle-feeder.sh, unchanged, against the full e2e deployment.
# The feeder resolves the oracle through the canonical registry, as in production; no oracle address is
# passed in. It signs as the production updater, which the node impersonates (ORACLE_FEEDER_FROM), so
# no key is involved. Each scenario runs in an evm_snapshot, so state and time travel are rolled back.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RPC="${RPC_URL:?RPC_URL must be set}"
REGISTRY=0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25
OWNER=0x91d3019b38185b517Bb98B7BB4953c137F5EEb8E # the registry owner, and the oracle updater on testnet
ARTIFACTS="${E2E_OUT_DIR:-${ROOT_DIR}/e2e/.out}/artifacts"
DAY=86400
WORK="$(mktemp -d)"

rpc() { cast rpc "$@" --rpc-url "${RPC}" > /dev/null; }

# Mine per transaction while the suite runs, for speed; leave the chain as we found it (2s blocks).
# shellcheck disable=SC2329 # invoked by the trap
cleanup() {
    if [[ -n "${SNAP:-}" ]]; then rpc evm_revert "${SNAP}" || true; fi
    rpc anvil_stopImpersonatingAccount "${OWNER}" || true
    rpc evm_setIntervalMining 2 || true
    rm -rf "${WORK}"
}
trap cleanup EXIT
rpc evm_setIntervalMining 0
rpc evm_setAutomine true
rpc anvil_impersonateAccount "${OWNER}"

# Wraps the real cast so one read alone (any cast call whose arguments contain FAKE_ON) can fail like an
# RPC outage or a revert, with FAKE_ERROR as the error, or succeed with FAKE_OUTPUT as its answer.
REAL_CAST="$(command -v cast)"
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/cast" <<EOF
#!/usr/bin/env bash
if [[ -n "\${FAKE_ON:-}" && "\$*" == *"\${FAKE_ON}"* ]]; then
    if [[ -n "\${FAKE_OUTPUT:-}" ]]; then echo "\${FAKE_OUTPUT}"; exit 0; fi
    echo "\${FAKE_ERROR}" >&2
    exit 1
fi
exec "${REAL_CAST}" "\$@"
EOF
chmod +x "${WORK}/bin/cast"

# --- chain reads, all through the registry or the oracle it names ---
oracle() { cast call "${REGISTRY}" "oracle()(address)" --rpc-url "${RPC}"; }
price() { cast call "${1:-$(oracle)}" "getCopraPriceUSD()(uint256,uint256)" --rpc-url "${RPC}" | awk 'NR==1{print $1}'; }
updated_at() { cast call "${1:-$(oracle)}" "getCopraPriceUSD()(uint256,uint256)" --rpc-url "${RPC}" | awk 'NR==2{print $1}'; }
now() { cast block latest --field timestamp --rpc-url "${RPC}"; }
warp() {
    rpc evm_increaseTime "$1"
    rpc evm_mine
}
# PriceUpdated events of an oracle, one "oldPrice newPrice timestamp" line each (prices are indexed).
price_events() {
    cast logs --from-block 0 --address "${1:-$(oracle)}" \
        "PriceUpdated(uint256 indexed oldPrice, uint256 indexed newPrice, uint256 timestamp)" --json --rpc-url "${RPC}" \
        | python3 -c 'import json,sys
for l in json.load(sys.stdin): print(int(l["topics"][1],16), int(l["topics"][2],16), int(l["data"],16))'
}
event_count() { price_events | wc -l | tr -d ' '; } # BSD wc pads the count

# --- assertions ---
FAILED=0
CURRENT=""
fail() {
    echo "FAIL: ${CURRENT}: $*"
    FAILED=1
}
expect_eq() { [[ "$1" == "$2" ]] || fail "$3: got $1, want $2"; }

# scenario <name>: rolls the chain back to the deployment, then starts a new snapshot.
scenario() {
    if [[ -n "${SNAP:-}" ]]; then rpc evm_revert "${SNAP}"; fi
    SNAP=$(cast rpc evm_snapshot --rpc-url "${RPC}" | tr -d '"')
    CURRENT="$1"
    EVENTS="${BASE_EVENTS}"
    echo "--- ${CURRENT}"
}

# feed <expected exit> <expected output substring> [env assignments...]: runs the real feeder against
# the stack. A failing run must never have reached the broadcast. The assignments follow the defaults on
# env's command line and env applies them in order, so a scenario can override one (ORACLE_FEEDER_FROM=).
OUT=""
feed() {
    local want_exit="$1" want_out="$2" code=0
    shift 2
    OUT=$(env -i HOME="${HOME:-/tmp}" PATH="${WORK}/bin:${PATH}" CI=1 BASE_SEPOLIA_RPC="${RPC}" \
        ORACLE_FEEDER_FROM="${OWNER}" "$@" bash "${ROOT_DIR}/scripts/oracle-feeder.sh" 2>&1) || code=$?
    if [[ "${code}" -ne "${want_exit}" || "${OUT}" != *"${want_out}"* ]]; then
        fail "feeder exit ${code}, want ${want_exit}; want output containing '${want_out}'"
        printf '    %s\n' "${OUT//$'\n'/$'\n'    }"
    elif [[ "${want_exit}" -ne 0 && "${OUT}" == *"Broadcasting"* ]]; then
        fail "feeder broadcast despite failing"
    fi
}

# expect_update <old> <new>: the last run landed exactly one update, oldPrice -> newPrice, now.
expect_update() {
    local events last
    events=$(event_count)
    expect_eq "${events}" "$((EVENTS + 1))" "PriceUpdated count"
    last=$(price_events | tail -n 1)
    expect_eq "${last}" "$1 $2 $(now)" "last PriceUpdated (old new timestamp)"
    expect_eq "$(price)" "$2" "oracle price"
    expect_eq "$(updated_at)" "$(now)" "oracle updatedAt"
    EVENTS=$((EVENTS + 1))
}
expect_no_update() { expect_eq "$(event_count)" "${EVENTS}" "PriceUpdated count"; }

ORACLE=$(oracle)
P0=$(price)
BASE_EVENTS=$(event_count)
echo "registry ${REGISTRY} -> oracle ${ORACLE}, price ${P0}, ${BASE_EVENTS} PriceUpdated"
expect_eq "${P0}" 142000000 "deployed price"

# ------------------------------------------------------------------------------------------------
scenario "fresh deployment: skips inside MIN_UPDATE_INTERVAL"
feed 0 "the oracle accepts one update per ${DAY}s. Skipping broadcast." TARGET_PRICE=1.45
[[ "${OUT}" == *"Oracle Contract : ${ORACLE}"* ]] || fail "did not resolve ${ORACLE} through the registry"
expect_no_update

scenario "after 1 day: broadcasts, and the oracle and PriceUpdated match, with a provenance record"
warp "${DAY}"
feed 0 "successfully updated" TARGET_PRICE=1.45
expect_update 142000000 145000000
[[ "${OUT}" == *'Provenance Record: {"tx": "0x'*'"price_e8": 145000000, "raw_value": "1.45",'*'"source": "manual override"'* ]] \
    || fail "no provenance record naming the manual override"

scenario "a target more than 20% away is refused, both ways, never clamped (#85)"
warp "${DAY}"
feed 1 "exceeds the oracle's 20% limit" TARGET_PRICE=2.00
expect_no_update
feed 1 "exceeds the oracle's 20% limit" TARGET_PRICE=1.00
expect_no_update
feed 0 "successfully updated" TARGET_PRICE=1.704 # exactly +20%, which the oracle accepts
expect_update 142000000 170400000

scenario "same price within 5 days: skips; FORCE=true broadcasts"
warp "${DAY}"
feed 0 "price is unchanged. Skipping broadcast." TARGET_PRICE=1.42
expect_no_update
feed 0 "successfully updated" TARGET_PRICE=1.42 FORCE=true
expect_update 142000000 142000000

scenario "same price at any age: never re-posted without FORCE, so the oracle goes stale (#85)"
warp $((6 * DAY))
feed 0 "price is unchanged. Skipping broadcast." TARGET_PRICE=1.42
expect_no_update

scenario "FORCE without a manual TARGET_PRICE: exit 1, no broadcast"
warp "${DAY}"
feed 1 "FORCE re-posts a manual TARGET_PRICE only" FORCE=true
expect_no_update

scenario "stale oracle (past HEARTBEAT): recovery update lands, price readable again with age 0"
warp $((7 * DAY + 1))
cast call "${ORACLE}" "getCopraPriceUSD()(uint256,uint256)" --rpc-url "${RPC}" > /dev/null 2>&1 \
    && fail "oracle is not stale after 7 days + 1s"
feed 0 "StalePrice. Proceeding with recovery update." TARGET_PRICE=1.45
expect_update 142000000 145000000

scenario "RPC down: exit 1, no broadcast"
warp "${DAY}"
feed 1 "could not read oracle() from CopraRegistry" TARGET_PRICE=1.45 BASE_SEPOLIA_RPC=http://127.0.0.1:1
expect_no_update

scenario "oracle state read fails: exit 1, no broadcast"
warp "${DAY}"
feed 1 "could not read getCopraPriceUSD()" TARGET_PRICE=1.45 \
    FAKE_ON="getCopraPriceUSD()" FAKE_ERROR="Error: error sending request for url (${RPC}/)"
expect_no_update

scenario "interval read fails: exit 1, no broadcast (#38)"
warp "${DAY}"
feed 1 "could not read MIN_UPDATE_INTERVAL()" TARGET_PRICE=1.45 \
    FAKE_ON="MIN_UPDATE_INTERVAL()" FAKE_ERROR="Error: error sending request for url (${RPC}/)"
expect_no_update

scenario "interval getter reverts: treated as a pre-interval oracle, update lands"
warp "${DAY}"
feed 0 "successfully updated" TARGET_PRICE=1.45 \
    FAKE_ON="MIN_UPDATE_INTERVAL()" \
    FAKE_ERROR='Error: server returned an error response: error code 3: execution reverted, data: "0x"'
expect_update 142000000 145000000

scenario "registry repointed to a new oracle: the next run follows it with no config change, signing with a key"
# The new oracle's updater is anvil account 9, so this run signs as production does (--private-key),
# with the key derived at runtime from anvil's public test mnemonic. Nothing key-shaped is committed.
# deploy <artifact> <constructor signature> <args...>: creates from the exported artifact as the owner.
deploy() {
    local name="$1" sig="$2" bytecode args=""
    shift 2
    bytecode=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bytecode"]["object"])' "${ARTIFACTS}/${name}.json")
    if [[ $# -gt 0 ]]; then args=$(cast abi-encode "${sig}" "$@"); fi
    cast send --unlocked --from "${OWNER}" --rpc-url "${RPC}" --json --create "${bytecode}${args#0x}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["contractAddress"])'
}
send() { cast send --unlocked --from "${OWNER}" --rpc-url "${RPC}" "$@" > /dev/null; }
USDC=$(cast call "${REGISTRY}" "collateral()(address)" --rpc-url "${RPC}")
UPDATER_KEY=$(cast wallet private-key "test test test test test test test test test test test junk" 9)
UPDATER=$(cast wallet address --private-key "${UPDATER_KEY}")
NEW_ORACLE=$(cast to-check-sum-address "$(deploy CopraOracle "constructor(address,uint256)" "${UPDATER}" 150000000)")
NEW_VAULT=$(deploy CopraVault "constructor(address,uint8,address,address,address)" "${USDC}" 6 "${NEW_ORACLE}" "${OWNER}" "${OWNER}")
NEW_TOKEN=$(deploy CopraToken "constructor(address)" "${NEW_VAULT}")
send "${NEW_VAULT}" "setCopraToken(address)" "${NEW_TOKEN}"
send "${REGISTRY}" "setDeployment(address,address,address,address)" "${USDC}" "${NEW_ORACLE}" "${NEW_VAULT}" "${NEW_TOKEN}"
expect_eq "$(oracle)" "${NEW_ORACLE}" "registry oracle after setDeployment"
warp "${DAY}"
EVENTS=$(event_count)
feed 0 "successfully updated" TARGET_PRICE=1.55 ORACLE_FEEDER_FROM= ORACLE_FEEDER_KEY="${UPDATER_KEY}"
[[ "${OUT}" == *"Oracle Contract : ${NEW_ORACLE}"* ]] || fail "feeder did not follow the registry to ${NEW_ORACLE}"
expect_update 150000000 155000000
expect_eq "$(price "${ORACLE}")" 142000000 "old oracle price (must be untouched)"

scenario "no source and no override: exit 1, no broadcast, no default price (#85)"
warp "${DAY}"
feed 1 "no price source" DEFAULT_BENCHMARK=1.45 # the old fallback knob, now ignored
expect_no_update

scenario "source path (python3): an undeclared feed host fails closed, no broadcast (#85)"
warp "${DAY}"
feed 1 "price source failed, not broadcasting: host 'evil.example' is not a declared source" \
    COMMODITY_FEED_API_URL=https://evil.example/price
expect_no_update

scenario "stale oracle and a target more than 20% away: refused before broadcasting, the oracle stays stale"
# The oracle checks the 20% limit against its stored price even when stale, so the feeder reads that price
# from storage and refuses here rather than sending an update that reverts with PriceChangeExceeded.
warp $((7 * DAY + 1))
feed 1 "exceeds the oracle's 20% limit" TARGET_PRICE=2.00
[[ "${OUT}" == *"Last On-Chain Price    : \$1.4200 USD / kg (142000000), stale"* ]] || fail "stale price not read from storage"
expect_no_update

scenario "stale oracle and its storage unreadable: exit 1, no broadcast"
warp $((7 * DAY + 1))
feed 1 "could not read the stale price" TARGET_PRICE=1.45 FAKE_ON="storage" FAKE_ERROR="Error: error sending request for url (${RPC}/)"
expect_no_update

# A moved storage layout must refuse to broadcast, not clamp against whatever the slots now hold.
scenario "stale oracle and slot 0 no longer the price: exit 1, no broadcast"
warp $((7 * DAY + 1))
rpc anvil_setStorageAt "${ORACLE}" 0x0 "$(cast to-uint256 "$(now)")" # a timestamp where the price was
feed 1 "implausible stale state" TARGET_PRICE=1.45
expect_no_update

scenario "stale oracle and slot 1 no longer its update time: exit 1, no broadcast"
warp $((7 * DAY + 1))
feed 1 "implausible stale state" TARGET_PRICE=1.45 FAKE_ON="storage ${ORACLE} 1 " FAKE_OUTPUT="$(cast to-uint256 "$(now)")"
expect_no_update

scenario "both ORACLE_FEEDER_FROM and a key: exit 1 before any read, no broadcast"
warp "${DAY}"
feed 1 "set only one signer" TARGET_PRICE=1.45 ORACLE_FEEDER_KEY="${UPDATER_KEY}"
expect_no_update

echo
if [[ "${FAILED}" -eq 0 ]]; then echo "PASS: oracle feeder scenarios"; else echo "FAIL: oracle feeder scenarios"; fi
exit "${FAILED}"

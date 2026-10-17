#!/usr/bin/env bash
# Verifies the e2e deployment from outside, reading the chain only through the canonical registry,
# and checks the manifest agrees. Exits non-zero on the first mismatch.
set -euo pipefail

RPC="${RPC_URL:-http://127.0.0.1:${E2E_RPC_PORT:-8545}}"
MANIFEST="${1:-$(dirname "${BASH_SOURCE[0]}")/.out/deployment.json}"
REGISTRY=0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25
OWNER=0x91d3019b38185b517Bb98B7BB4953c137F5EEb8E

fail() { echo "FAIL: $*"; exit 1; }
lower() { tr '[:upper:]' '[:lower:]'; }
in_manifest() { grep -qi "\"$1\": \"$2\"" "${MANIFEST}" || fail "manifest $1 is not $2"; }

[[ -f "${MANIFEST}" ]] || fail "no manifest at ${MANIFEST}"
[[ "$(cast chain-id --rpc-url "${RPC}")" == "84532" ]] || fail "chain id is not 84532"
[[ "$(cast code "${REGISTRY}" --rpc-url "${RPC}")" != "0x" ]] || fail "no CopraRegistry at the canonical address ${REGISTRY}"
[[ "$(cast call "${REGISTRY}" "owner()(address)" --rpc-url "${RPC}" | lower)" == "$(echo "${OWNER}" | lower)" ]] \
    || fail "registry owner is not ${OWNER}"

{ read -r USDC; read -r ORACLE; read -r VAULT; read -r TOKEN; read -r VERSION _; } < <(
    cast call "${REGISTRY}" "getDeployment()(address,address,address,address,uint256,uint256)" --rpc-url "${RPC}")
[[ "${VERSION}" == "1" ]] || fail "registry version is ${VERSION}, expected 1 on a fresh chain"

for pair in "usdc ${USDC}" "oracle ${ORACLE}" "vault ${VAULT}" "token ${TOKEN}"; do
    read -r name addr <<< "${pair}"
    [[ "$(cast code "${addr}" --rpc-url "${RPC}")" != "0x" ]] || fail "${name} ${addr} has no code"
    in_manifest "${name}" "${addr}"
done
in_manifest registry "${REGISTRY}"

# Wiring: the set the registry accepted must point at itself, and every role is the production owner.
[[ "$(cast call "${TOKEN}" "vault()(address)" --rpc-url "${RPC}")" == "${VAULT}" ]] || fail "token.vault() is not the vault"
[[ "$(cast call "${VAULT}" "copraToken()(address)" --rpc-url "${RPC}")" == "${TOKEN}" ]] || fail "vault.copraToken() is not the token"
for role in "owner()(address)" "feeRecipient()(address)"; do
    [[ "$(cast call "${VAULT}" "${role}" --rpc-url "${RPC}" | lower)" == "$(echo "${OWNER}" | lower)" ]] || fail "vault ${role} is not ${OWNER}"
done
[[ "$(cast call "${ORACLE}" "feedUpdater()(address)" --rpc-url "${RPC}" | lower)" == "$(echo "${OWNER}" | lower)" ]] \
    || fail "oracle updater is not ${OWNER}"
cast call "${ORACLE}" "getCopraPriceUSD()(uint256,uint256)" --rpc-url "${RPC}" > /dev/null || fail "oracle price is not readable"

echo "PASS: CopraRegistry v${VERSION} at ${REGISTRY}; usdc, oracle, vault and token deployed, wired and matching the manifest"

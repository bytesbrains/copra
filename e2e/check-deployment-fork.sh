#!/usr/bin/env bash
# Verifies the Base-mainnet fork deployment (#48) from outside, as docs/MAINNET_DEPLOY.md's post-deploy
# checks do: through the registry, against real USDC, with four distinct roles. Exits on the first mismatch.
set -euo pipefail

RPC="${RPC_URL:-http://127.0.0.1:${E2E_RPC_PORT:-8545}}"
MANIFEST="${1:-$(dirname "${BASH_SOURCE[0]}")/.out/deployment.json}"
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

fail() { echo "FAIL: $*"; exit 1; }
lower() { tr '[:upper:]' '[:lower:]'; }
field() { grep -o "\"$1\": \"0x[0-9a-fA-F]*\"" "${MANIFEST}" | grep -o '0x[0-9a-fA-F]*' | lower; }
call() { cast call "$@" --rpc-url "${RPC}" | lower; }

[[ -f "${MANIFEST}" ]] || fail "no manifest at ${MANIFEST}"
[[ "$(cast chain-id --rpc-url "${RPC}")" == "8453" ]] || fail "chain id is not 8453"
REGISTRY=$(field registry) OWNER=$(field registryOwner)
[[ "$(cast code "${REGISTRY}" --rpc-url "${RPC}")" != "0x" ]] || fail "no CopraRegistry at ${REGISTRY}"
[[ "$(call "${REGISTRY}" "owner()(address)")" == "${OWNER}" ]] || fail "registry owner is not the multisig ${OWNER}"
[[ "$(cast code "${OWNER}" --rpc-url "${RPC}")" != "0x" ]] || fail "the owner ${OWNER} is not a contract"

{ read -r C; read -r ORACLE; read -r VAULT; read -r TOKEN; read -r VERSION _; } < <(call "${REGISTRY}" "getDeployment()(address,address,address,address,uint256,uint256)")
[[ "${VERSION}" == "1" ]] || fail "registry version is ${VERSION}, expected 1"
[[ "${C}" == "$(echo "${USDC}" | lower)" ]] || fail "collateral ${C} is not Circle's USDC"
for pair in "usdc ${C}" "oracle ${ORACLE}" "vault ${VAULT}" "token ${TOKEN}"; do
    read -r name addr <<< "${pair}"
    [[ "$(field "${name}")" == "${addr}" ]] || fail "manifest ${name} is not ${addr}"
done

[[ "$(call "${VAULT}" "owner()(address)")" == "${OWNER}" ]] || fail "vault owner is not the multisig"
[[ "$(call "${VAULT}" "pendingOwner()(address)")" == "0x0000000000000000000000000000000000000000" ]] || fail "vault ownership still pending"
[[ "$(call "${VAULT}" "collateralToken()(address)")" == "${C}" ]] || fail "vault collateral is not USDC"
[[ "$(call "${VAULT}" "copraToken()(address)")" == "${TOKEN}" ]] || fail "vault.copraToken() is not the token"
[[ "$(call "${TOKEN}" "vault()(address)")" == "${VAULT}" ]] || fail "token.vault() is not the vault"
[[ "$(call "${VAULT}" "feeRecipient()(address)")" == "$(field feeRecipient)" ]] || fail "fee recipient differs from the manifest"
[[ "$(call "${ORACLE}" "feedUpdater()(address)")" == "$(field oracleUpdater)" ]] || fail "oracle updater differs from the manifest"

ROLES=$(printf '%s\n' "$(field deployer)" "${OWNER}" "$(field oracleUpdater)" "$(field feeRecipient)")
[[ "$(sort -u <<< "${ROLES}" | wc -l | tr -d ' ')" == "4" ]] || fail "the deployer, multisig, updater and fee recipient are not four addresses"
cast call "${ORACLE}" "getCopraPriceUSD()(uint256,uint256)" --rpc-url "${RPC}" > /dev/null || fail "oracle price is not readable"

echo "PASS: CopraRegistry v${VERSION} at ${REGISTRY}, owned by the multisig; vault on Circle's USDC; four distinct roles"

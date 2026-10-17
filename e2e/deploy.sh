#!/usr/bin/env bash
# Deploys Copra to the e2e chain the way production was deployed, then writes the manifest.
# Runs in the deployer container (see docker-compose.yml); RPC_URL points at the chain service.
set -euo pipefail

RPC="${RPC_URL:?RPC_URL must be set}"
OUT_DIR="${E2E_OUT_DIR:-/out}"
# The production registry owner. Impersonating it puts CopraRegistry at the canonical CREATE2
# address the dApp and oracle feeder already hardcode, so they need no local override for it.
OWNER=0x91d3019b38185b517Bb98B7BB4953c137F5EEb8E
REGISTRY=0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25

echo "⛓️  chain id $(cast chain-id --rpc-url "${RPC}") at ${RPC}"
cast rpc anvil_impersonateAccount "${OWNER}" --rpc-url "${RPC}" > /dev/null
cast rpc anvil_setBalance "${OWNER}" 0x56BC75E2D63100000 --rpc-url "${RPC}" > /dev/null # 100 ETH

forge script script/DeployCopra.s.sol:DeployCopra --sig "runUnlocked()" \
    --unlocked --sender "${OWNER}" --rpc-url "${RPC}" --broadcast --slow

# Leave the chain as production is: nobody can sign as the owner unless a test impersonates it.
cast rpc anvil_stopImpersonatingAccount "${OWNER}" --rpc-url "${RPC}" > /dev/null

{ read -r USDC; read -r ORACLE; read -r VAULT; read -r TOKEN; read -r VERSION _; } < <(
    cast call "${REGISTRY}" "getDeployment()(address,address,address,address,uint256,uint256)" --rpc-url "${RPC}")
VAULT_OWNER=$(cast call "${VAULT}" "owner()(address)" --rpc-url "${RPC}")
UPDATER=$(cast call "${ORACLE}" "feedUpdater()(address)" --rpc-url "${RPC}")
FEE_RECIPIENT=$(cast call "${VAULT}" "feeRecipient()(address)" --rpc-url "${RPC}")
CHAIN_ID=$(cast chain-id --rpc-url "${RPC}")
USERS=$(cast rpc eth_accounts --rpc-url "${RPC}") # already a JSON array

mkdir -p "${OUT_DIR}"
cat > "${OUT_DIR}/deployment.json" <<JSON
{
  "chainId": ${CHAIN_ID},
  "rpcUrl": "http://127.0.0.1:${E2E_RPC_PORT:-8545}",
  "registryVersion": ${VERSION},
  "contracts": {
    "registry": "${REGISTRY}",
    "usdc": "${USDC}",
    "oracle": "${ORACLE}",
    "vault": "${VAULT}",
    "token": "${TOKEN}"
  },
  "roles": {
    "registryOwner": "${OWNER}",
    "vaultOwner": "${VAULT_OWNER}",
    "oracleUpdater": "${UPDATER}",
    "feeRecipient": "${FEE_RECIPIENT}"
  },
  "users": ${USERS}
}
JSON
# ABI + bytecode for the test suites, which run without Foundry. forge script only compiled what the
# deploy imports, so build the test-only MockCollateral fixture explicitly.
forge build test/mocks/MockCollateral.sol > /dev/null
mkdir -p "${OUT_DIR}/artifacts"
for c in CopraRegistry CopraOracle CopraVault CopraToken TestnetUSDC MockCollateral; do
    cp "$(find "${FOUNDRY_OUT:-out}" -path "*/${c}.sol/${c}.json" | head -n 1)" "${OUT_DIR}/artifacts/${c}.json"
done

echo "📄 manifest written to e2e/.out/deployment.json, artifacts to e2e/.out/artifacts/"

#!/usr/bin/env bash
# Deploys Copra to the Base-mainnet fork (#48) the way mainnet will be deployed: DeployCopraMainnet against
# Circle's USDC with four separate roles, then the multisig's batch, then writes the manifest.
# Runs in the deployer container under docker-compose.fork.yml; RPC_URL points at the forked chain.
set -euo pipefail

RPC="${RPC_URL:?RPC_URL must be set}"
OUT_DIR="${E2E_OUT_DIR:-/out}"
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
# Aave v3's aBasUSDC: the largest USDC holder at the pinned block. Users are funded by transfers from
# it, impersonated, as anyone on mainnet is funded, never by minting.
USDC_HOLDER=0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB
# Four roles, four addresses. The multisig is given code (DeployCopraMainnet refuses an EOA owner) and,
# like the updater and fee recipient, is only ever impersonated: no key exists for any of them.
MULTISIG=0x00000000000000000000000000000000c0b4a547
UPDATER=0x00000000000000000000000000000000c0b4f33d
FEE_RECIPIENT=0x00000000000000000000000000000000c0b4fee5
# The deployer only pays gas. Anvil's public test mnemonic, index 10: outside the 10 user accounts.
DEPLOYER_KEY=$(cast wallet private-key --mnemonic "test test test test test test test test test test test junk" --mnemonic-index 10)

[[ "$(cast chain-id --rpc-url "${RPC}")" == "8453" ]] || { echo "not a Base-mainnet fork"; exit 1; }
echo "⛓️  Base fork at block $(cast block-number --rpc-url "${RPC}") via ${RPC}"
cast rpc anvil_setCode "${MULTISIG}" 0x00 --rpc-url "${RPC}" > /dev/null
for a in "${MULTISIG}" "${UPDATER}" "${FEE_RECIPIENT}" "${USDC_HOLDER}" "$(cast wallet address "${DEPLOYER_KEY}")"; do
    cast rpc anvil_setBalance "${a}" 0x56BC75E2D63100000 --rpc-url "${RPC}" > /dev/null # 100 ETH
done
# The suite funds users from this holder: require far more than it ever moves (1,000,000 USDC, 6 decimals).
MIN_HELD=1000000000000
HELD=$(cast call "${USDC}" "balanceOf(address)(uint256)" "${USDC_HOLDER}" --rpc-url "${RPC}" | cut -d' ' -f1)
(( HELD >= MIN_HELD )) || { echo "USDC holder ${USDC_HOLDER} holds ${HELD} at this block, under ${MIN_HELD}: pick another"; exit 1; }

FROM_BLOCK=$(( $(cast block-number --rpc-url "${RPC}") + 1 ))
LOG=$(PRIVATE_KEY="${DEPLOYER_KEY}" COPRA_OWNER="${MULTISIG}" COPRA_ORACLE_UPDATER="${UPDATER}" \
    COPRA_FEE_RECIPIENT="${FEE_RECIPIENT}" COPRA_COLLATERAL="${USDC}" COPRA_COLLATERAL_DECIMALS=6 \
    COPRA_INITIAL_PRICE=142000000 \
    forge script script/DeployCopraMainnet.s.sol:DeployCopraMainnet --rpc-url "${RPC}" --broadcast --slow | tee /dev/stderr)
addr() { grep -m1 "$1 deployed at:" <<< "${LOG}" | grep -o '0x[0-9a-fA-F]\{40\}'; }
REGISTRY=$(addr CopraRegistry) ORACLE=$(addr CopraOracle) VAULT=$(addr CopraVault) TOKEN=$(addr CopraToken)
[[ -n "${REGISTRY}" ]] || REGISTRY=$(grep -m1 "CopraRegistry" <<< "${LOG}" | grep -o '0x[0-9a-fA-F]\{40\}')
# The addresses come from the script's log: if its wording changes, stop here, not in a cast call or the manifest.
for pair in "CopraRegistry ${REGISTRY}" "CopraOracle ${ORACLE}" "CopraVault ${VAULT}" "CopraToken ${TOKEN}"; do
    read -r name a <<< "${pair}"
    [[ "${a}" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "no ${name} address in DeployCopraMainnet's output"; exit 1; }
done

# The multisig's batch, as docs/MAINNET_DEPLOY.md has it signed: accept the vault, then go live.
cast rpc anvil_impersonateAccount "${MULTISIG}" --rpc-url "${RPC}" > /dev/null
cast send "${VAULT}" "acceptOwnership()" --from "${MULTISIG}" --unlocked --rpc-url "${RPC}" > /dev/null
cast send "${REGISTRY}" "setDeployment(address,address,address,address)" "${USDC}" "${ORACLE}" "${VAULT}" "${TOKEN}" \
    --from "${MULTISIG}" --unlocked --rpc-url "${RPC}" > /dev/null
cast rpc anvil_stopImpersonatingAccount "${MULTISIG}" --rpc-url "${RPC}" > /dev/null

VERSION=$(cast call "${REGISTRY}" "version()(uint256)" --rpc-url "${RPC}")
USERS=$(cast rpc eth_accounts --rpc-url "${RPC}")

mkdir -p "${OUT_DIR}"
cat > "${OUT_DIR}/deployment.json" <<JSON
{
  "chainId": 8453,
  "rpcUrl": "http://127.0.0.1:${E2E_RPC_PORT:-8545}",
  "forkBlock": ${E2E_FORK_BLOCK:-null},
  "fromBlock": ${FROM_BLOCK},
  "collateral": "USDC",
  "usdcHolder": "${USDC_HOLDER}",
  "registryVersion": ${VERSION},
  "contracts": {
    "registry": "${REGISTRY}",
    "usdc": "${USDC}",
    "oracle": "${ORACLE}",
    "vault": "${VAULT}",
    "token": "${TOKEN}"
  },
  "roles": {
    "deployer": "$(cast wallet address "${DEPLOYER_KEY}")",
    "registryOwner": "$(cast call "${REGISTRY}" "owner()(address)" --rpc-url "${RPC}")",
    "vaultOwner": "$(cast call "${VAULT}" "owner()(address)" --rpc-url "${RPC}")",
    "oracleUpdater": "$(cast call "${ORACLE}" "feedUpdater()(address)" --rpc-url "${RPC}")",
    "feeRecipient": "$(cast call "${VAULT}" "feeRecipient()(address)" --rpc-url "${RPC}")"
  },
  "users": ${USERS}
}
JSON
# ABI + bytecode for the test suites, as deploy.sh does.
forge build test/mocks/MockCollateral.sol > /dev/null
mkdir -p "${OUT_DIR}/artifacts"
for c in CopraRegistry CopraOracle CopraVault CopraToken TestnetUSDC MockCollateral; do
    cp "$(find "${FOUNDRY_OUT:-out}" -path "*/${c}.sol/${c}.json" | head -n 1)" "${OUT_DIR}/artifacts/${c}.json"
done

echo "📄 fork manifest written to e2e/.out/deployment.json, artifacts to e2e/.out/artifacts/"

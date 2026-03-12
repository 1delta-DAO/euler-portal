#!/usr/bin/env bash
# Deploy contracts to a specific chain by chain ID.
# Usage: ./script/deploy.sh <chain-id> [extra forge flags...]
#
# Example:
#   ./script/deploy.sh 1                          # Ethereum mainnet
#   ./script/deploy.sh 42161                       # Arbitrum
#   ./script/deploy.sh 8453 --gas-price 0.01gwei   # Base with extra flags

set -euo pipefail

CHAIN_ID=${1:?"Usage: ./script/deploy.sh <chain-id> [extra forge flags...]"}
shift # remaining args passed through to forge

# Source all chain-indexed env vars
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

# ── Resolve chain-specific variables ────────────────────────────────

rpc_var="RPC_URL_${CHAIN_ID}"
evc_var="EVC_${CHAIN_ID}"
verifier_var="VERIFIER_${CHAIN_ID}"
verifier_url_var="VERIFIER_URL_${CHAIN_ID}"
api_key_var="ETHERSCAN_API_KEY_${CHAIN_ID}"

RPC_URL="${!rpc_var:?$rpc_var is not set in .env}"
EVC="${!evc_var:?$evc_var is not set in .env}"
VERIFIER="${!verifier_var:-etherscan}"
VERIFIER_URL="${!verifier_url_var:-}"
CHAIN_API_KEY="${!api_key_var:-}"

# ── Build forge command ─────────────────────────────────────────────

# Use chain-specific key if set, otherwise fall back to global key.
# Skip verification entirely if VERIFIER_{chainId}=none.
VERIFY_FLAGS=()
if [[ "$VERIFIER" == "none" ]]; then
    echo "⚠ Verification disabled for chain $CHAIN_ID"
elif [[ -n "$CHAIN_API_KEY" || -n "${ETHERSCAN_API_KEY:-}" ]]; then
    VERIFY_FLAGS=(--verify --verifier "$VERIFIER")
    [[ -n "$VERIFIER_URL" ]] && VERIFY_FLAGS+=(--verifier-url "$VERIFIER_URL")
    VERIFY_FLAGS+=(--etherscan-api-key "${CHAIN_API_KEY:-$ETHERSCAN_API_KEY}")
else
    echo "⚠ No API key for chain $CHAIN_ID — skipping verification"
fi

echo "=== Deploying to chain $CHAIN_ID ==="
echo "RPC:      $RPC_URL"
echo "EVC:      $EVC"
echo "Verifier: $VERIFIER"
echo ""

EVC="$EVC" forge script script/Deploy.s.sol \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --private-key "$PRIVATE_KEY" \
    "${VERIFY_FLAGS[@]}" \
    "$@"

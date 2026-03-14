#!/usr/bin/env bash
# Deploy PriceLens to all chains (or a single chain).
#
# Usage:
#   ./script/deployPriceLens.sh              # deploy to all chains
#   ./script/deployPriceLens.sh 1            # deploy to mainnet only
#   ./script/deployPriceLens.sh 42161        # deploy to arbitrum only

set -euo pipefail

# Source env vars
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

# Chains we have deployed to (from broadcast history)
ALL_CHAINS=(1 56 130 143 146 999 8453 9745 42161 43114 59144 80094)

if [[ $# -gt 0 ]]; then
    CHAINS=("$@")
else
    CHAINS=("${ALL_CHAINS[@]}")
fi

for CHAIN_ID in "${CHAINS[@]}"; do
    echo ""
    echo "════════════════════════════════════════"
    echo "  Deploying PriceLens to chain $CHAIN_ID"
    echo "════════════════════════════════════════"

    rpc_var="RPC_URL_${CHAIN_ID}"
    verifier_var="VERIFIER_${CHAIN_ID}"
    verifier_url_var="VERIFIER_URL_${CHAIN_ID}"
    api_key_var="ETHERSCAN_API_KEY_${CHAIN_ID}"

    RPC_URL="${!rpc_var:?$rpc_var is not set in .env}"
    VERIFIER="${!verifier_var:-etherscan}"
    VERIFIER_URL="${!verifier_url_var:-}"
    CHAIN_API_KEY="${!api_key_var:-}"

    # Build verification flags
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

    forge script script/DeployPriceLens.s.sol \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --private-key "$PRIVATE_KEY" \
        "${VERIFY_FLAGS[@]}" \
        || { echo "✗ Chain $CHAIN_ID failed"; continue; }

    echo "✓ Chain $CHAIN_ID done"
done

echo ""
echo "=== All deployments complete ==="

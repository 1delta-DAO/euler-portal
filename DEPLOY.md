# Deployment

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Deployer EOA private key
- EVC address on the target chain

## Environment

Copy `.env.example` and fill in values:

```bash
cp .env.example .env
```

All chain-specific variables are indexed by chain ID:

```
PRIVATE_KEY=0x...
ETHERSCAN_API_KEY=...

# Per-chain values use {chainId} suffix
RPC_URL_1=https://eth.drpc.org
RPC_URL_42161=https://1rpc.io/arb

EVC_1=0x...
EVC_42161=0x...

# Optional per-chain verifier overrides (defaults to etherscan)
VERIFIER_8453=blockscout
VERIFIER_URL_8453=https://base.blockscout.com/api
```

## Deploy

```bash
# Deploy to Ethereum mainnet (chain ID 1)
./script/deploy.sh 1

# Deploy to Arbitrum (chain ID 42161)
./script/deploy.sh 42161

# Pass extra forge flags after the chain ID
./script/deploy.sh 8453 --gas-price 0.01gwei
```

The script resolves `RPC_URL_{chainId}`, `EVC_{chainId}`, and verifier settings from `.env` automatically.

## Same addresses across chains

To get identical contract addresses on every chain, use the same deployer EOA at the same nonce. The easiest way is to use a fresh EOA dedicated to deployment.

## Verify (manual)

If verification wasn't done at deploy time:

```bash
source .env

# Use indirect variable expansion for the chain you need
CHAIN_ID=1
eval RPC_URL=\${RPC_URL_${CHAIN_ID}}
eval EVC=\${EVC_${CHAIN_ID}}

forge verify-contract <orchestrator-address> Orchestrator --rpc-url $RPC_URL
forge verify-contract <payments-address> Payments --rpc-url $RPC_URL \
  --constructor-args $(cast abi-encode "constructor(address)" $EVC)
```

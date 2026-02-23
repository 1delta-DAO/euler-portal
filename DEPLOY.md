# Deployment

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Deployer EOA private key
- RPC URL for the target chain
- EVC address on the target chain

## Environment

Copy `.env.example` and fill in values:

```bash
cp .env.example .env
```

```
# .env
PRIVATE_KEY=0x...
RPC_URL=https://...
EVC=0x...
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
VERIFIER=etherscan
VERIFIER_URL=
ETHERSCAN_API_KEY=
```

## Deploy

```bash
source .env
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY --verify
```

For Blockscout-based explorers, set `VERIFIER=blockscout` and `VERIFIER_URL=https://explorer.example.com/api`.

## Same addresses across chains

To get identical contract addresses on every chain, use the same deployer EOA at the same nonce. The easiest way is to use a fresh EOA dedicated to deployment.

## Verify (manual)

If verification wasn't done at deploy time:

```bash
source .env
forge verify-contract <swapper-address> Swapper --rpc-url $RPC_URL
forge verify-contract <payments-address> Payments --rpc-url $RPC_URL \
  --constructor-args $(cast abi-encode "constructor(address,address)" $EVC $PERMIT2)
```

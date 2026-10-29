# VEX EVM mainnet

**Chain ID:** 6736

**EVM RPC:** `https://vexascan.com/rpc`

**Native API:** `https://vexascan.com:8443`

**Launch:** 29 October 2026, 15:13:01 UTC (22:13:01 WIB)

Other EVM RPC endpoints are listed at [Chainlist](https://chainlist.org/chain/6736). Check that an endpoint reports chain ID `6736` before using it.

## Contract addresses

| Contract | Address |
| --- | --- |
| ZoruToken | `0xb972753d17C5131D127B6c22DDE79B91a3132D03` |
| ZoruLedger | `0xFf53a9079C2853C39C5adBfca788cb0f12aCFF03` |
| ZoruKeccakEngine | `0x9eD52C07691Cd26758ed1Ebe05d86698a9e54e8C` |
| ZoruDrandBeacon | `0x562249B5c3922fAfa31f350EfDb89E4F3F9a82fE` |
| ZoruAdminAdapter | `0xF5A9911A70aD0D9456C4228c08B74d161786F410` |

**Owner:** `0x0dad2Ad1C030e2e67E7c01a952bab3ce81D4bfFC`

**Token issuer:** ZoruLedger proxy

**Deployment block:** 11036432

**Initial difficulty bits:** 19

## Release files

- `release/deployment-record.json` — confirmed deployment parameters
- `release/mainnet.json` — addresses, code hashes and release metadata
- `release/build-manifest.json` — compiler settings and build fingerprints
- `release/abi/` and `release/layout/` — ABI and storage layout references

Manifest SHA-256: `c2a89d2439f00fc768ce585e9b122b79b3dc6e0f3b201ad06c2d683b9bce0401`.

The checksum detects changes to the manifest; it does not authenticate its publisher.

## Verify deployment

Run these commands from the repository root with Foundry's `cast` and Python 3:

```sh
export EVM_RPC=https://vexascan.com/rpc
export VEX_NATIVE_RPC=https://vexascan.com:8443

cast chain-id --rpc-url "$EVM_RPC"
cast call 0xb972753d17C5131D127B6c22DDE79B91a3132D03 \
  'owner()(address)' --rpc-url "$EVM_RPC"
cast call 0xb972753d17C5131D127B6c22DDE79B91a3132D03 \
  'issuer()(address)' --rpc-url "$EVM_RPC"

python3 tools/release_manifest.py \
  --deployment release/deployment-record.json \
  --read "$EVM_RPC" --native "$VEX_NATIVE_RPC" \
  --output /tmp/zoru-mainnet-check.json
```

The verifier checks the chain, contract bytecode, proxy implementations, owner, issuer and protocol configuration. A newly generated checksum also depends on the current source tree; keep the original `release/mainnet.json` for existing releases. For wallet and mining commands, see `zoru-miner`.

The current launch timestamp is configured on-chain. No additional launch transaction is required.

# VEX EVM mainnet

**Chain ID:** 6736

**EVM RPC:** `https://api.windcrypto.com/rpc`

**Native RPC:** `https://api.windcrypto.com`

**Launch:** 29 October 2026, 15:13:01 UTC (22:13:01 WIB)

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

Run from the repository root with Foundry's `cast` and Python 3:

```sh
cast chain-id --rpc-url https://api.windcrypto.com/rpc
cast call 0xb972753d17C5131D127B6c22DDE79B91a3132D03   'owner()(address)' --rpc-url https://api.windcrypto.com/rpc
cast call 0xb972753d17C5131D127B6c22DDE79B91a3132D03   'issuer()(address)' --rpc-url https://api.windcrypto.com/rpc
python3 tools/release_manifest.py   --deployment release/deployment-record.json   --read https://api.windcrypto.com/rpc   --native https://api.windcrypto.com   --output release/mainnet.json
```

The manifest verifier checks the chain, contract bytecode, proxy implementations, owner, issuer and protocol configuration. For mining and wallet instructions, use the companion `zoru-miner` repository.

The current launch timestamp is configured on-chain. No additional launch transaction is required.

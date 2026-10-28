# ZORU PoW

ZORU is a Keccak proof-of-work token on **Vexanium EVM mainnet (chain ID 6736)**. Miners submit proofs to the Ledger. Rewards are allocated across accepted proofs in nonempty 60-second epochs.

- **RPC:** `https://api.windcrypto.com/rpc`
- **Token:** 8 decimals; lifetime mint cap of 21,000,000 ZORU
- **Launch:** 29 October 2026 at 15:13:01 UTC (22:13:01 WIB)
- **Deployment:** [contract addresses and verification](docs/MAINNET.md)

## Contracts

| Contract | Role |
| --- | --- |
| `ZoruToken` | ERC-20 issuance and lifetime supply cap |
| `ZoruLedger` | Proof admission, epochs, rewards and claims |
| `ZoruKeccakEngine` | Keccak proof verification |
| `ZoruDrandBeacon` | Verification of scheduled drand randomness |
| `ZoruAdminAdapter` | Upgrade and recovery administration |

The Token is not upgradeable. The Ledger, Engine and Beacon use upgradeable proxies. The owner can upgrade these modules and change the token issuer. See [Security](docs/SECURITY.md).

## Build and test

Requires Solidity 0.8.38, Foundry and the dependencies specified by `package-lock.json`.

```sh
npm ci
cd contracts
forge build
forge test --threads 1
```

## Documentation

[Deployment](docs/MAINNET.md) · [Protocol](docs/PROTOCOL.md) · [Security](docs/SECURITY.md) · [Release policy](docs/RELEASE_POLICY.md) · [Validation](VALIDATION.md) · [References](docs/REFERENCES.md).

The companion `zoru-miner` project provides the Rust CLI and Qt desktop.

# Release policy

A release consists of matching contract source, build settings, deployed bytecode, miner binaries and deployment manifest.

Before publishing a new version:

1. Review changes to storage layout, mining rules, issuance, signing and ownership.
2. Run contract tests and miner regressions, including recovery and rollback tests when relevant.
3. Verify mainnet chain identity, contract addresses, implementations, owner and issuer.
4. Record source revisions, artifact checksums and deployment receipts.
5. Check installation and protocol compatibility against the intended release manifest.

Emergency upgrades require explicit owner authorization, documented effects on mining and claims, and a recovery plan. Contract upgrades do not change the Token's immutable lifetime cap.

## Authority

The owner can change the token issuer and upgrade the Ledger, Engine and Beacon. These are on-chain privileges, not restrictions enforced by this release policy. See [Security](SECURITY.md).

The Token uses two-step ownership transfer. A transfer is complete only after the nominated owner accepts it.

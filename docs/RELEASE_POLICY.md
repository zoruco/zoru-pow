# Release policy

A release consists of matching contract source, build settings, deployed bytecode, miner binaries and deployment manifest.

Before publishing a new version:

1. Review changes to storage layout, mining rules, issuance, signing and ownership.
2. Run contract tests and miner regressions, including recovery and rollback tests when relevant.
3. Verify mainnet chain identity, contract addresses, implementations, owner and issuer.
4. Record source revisions, artifact checksums and deployment receipts.
5. Check installation and protocol compatibility against the intended release manifest.

Emergency upgrades require explicit owner authorization, documented effects on mining and claims, and a recovery plan. Contract upgrades do not change the Token's immutable lifetime cap.

## Storage migration recovery

Keep both contract pauses active until the final implementations, historical records and reward balances are verified. Stopping a miner does not replace these controls. Preserve the inventory, exact signed transactions, batch receipts and state directory across interruptions.

If a submission cannot be reconciled, stop additional signing for that account. Check the canonical receipt, transaction hash and both pending and confirmed nonces; compare the native account nonce when necessary. Reuse retained signed bytes only after establishing that their nonce remains unused. A relay acknowledgement is not native finality.

After any original proof or epoch row has been cleared, the original implementation is no longer a safe recovery target. Recovery must preserve the canonical mappings. The reviewed migration implementation can keep execution frozen while records and receipts are reconciled. Do not restart completed migration initialization after temporary counters have been retired; resume the recorded release stage.

Activate mining only after cleanup, native irreversibility and final implementation verification. Retain the existing miner wallet and journal directories, install the matching manifest and binaries, then verify accepted work, epoch sealing and automatic claims on the intended network.

## Authority

The owner can change the token issuer and upgrade the Ledger, Engine and Beacon. These are on-chain privileges, not restrictions enforced by this release policy. See [Security](SECURITY.md).

The Token uses two-step ownership transfer. A transfer is complete only after the nominated owner accepts it.

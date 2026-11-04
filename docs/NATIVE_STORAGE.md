# Native storage

ZORU pays for persistent EVM state through the native `vex.evm` account. EVM gas and native RAM are separate resources. A successful gas estimate does not establish that the native account has enough RAM for execution.

## Accounting

The measured native charge for a nonzero EVM storage row is **346 bytes**. Creating the first row in an account scope also creates a **112-byte** table. Replacing an existing value costs no additional RAM. Deleting a row reclaims 346 bytes; deleting the last row also reclaims the table. Recreating a deleted row allocates that space again.

These numbers were reproduced with the deployed native WASM hash `6ba6867a6a791db805aa9d01b970a38e6e7fbca638386cb3707ab221f5d59f64` on isolated chain 46736. A log-only call and an EVM-reverted call added no RAM after the participating accounts existed. Receipts and transaction history belong to node databases; retaining a receipt does not create another native contract storage row.

Contract creation has a separate account and code cost. The upstream state implementation shares identical runtime code by code hash and reference count. A repeat deployment can therefore cost less RAM than the first deployment of those bytes. Nonces and balances update existing account rows. Creating beneficiaries and their first token balance remains an additional cost.

## Protocol records

| Record | Original storage | Canonical storage |
| --- | --- | --- |
| Unclaimed proof | 2 nonzero rows, 692 bytes | 1 row, 346 bytes |
| Claimed proof | 3 nonzero rows, 1,038 bytes | The same row, 346 bytes |
| Opened epoch | Up to 9 nonzero rows | 3 rows, 1,038 bytes |
| Beacon publication | 2 rows per published epoch, 692 bytes | 3 fixed rows, then reuse |
| Claim status change | Creates a proof status row | Updates the existing proof row |

Proofs retain the beneficiary, epoch, complete 32-bit index and claim status. Claims continue to pay the original beneficiary. Accepted records remain available after payment for ownership, duplicate prevention and historical inspection.

An epoch retains its target, authenticated seed, budget, proof count, generation, closing timestamp and sealed status. Permanent module addresses and the saturating work estimate are derived. Closing timestamps remain snapshots, including after clock recovery. Epoch budgets, token supply, reward rounding and mining rules are unchanged.

The Beacon accepts only the scheduled, authenticated signature for the current epoch. Its rolling cache occupies three fixed rows. Historical authenticated seeds remain in the Ledger and publication events. Public mining and claims require no new coordinator, server or proof format.

The final Ledger uses only the canonical mappings. Original mapping locations remain reserved at slots 12 and 13; canonical epochs and proofs use slots 21 and 16. The temporary migration methods are absent from the final implementation. Migration receipts occupy a fixed number of reserved global slots.

## Design choices

| Approach | Native RAM and operational effect | Decision |
| --- | --- | --- |
| Packed proof and epoch records | Fewer native rows; unchanged submission and claim format | Selected |
| Claim bitmap alone | Saves the status row but retains separate ownership and index records | Less reduction than a single complete proof record |
| Epoch aggregation alone | Cannot preserve individual permissionless ownership and exact claims | Insufficient |
| Merkle or commitment claims | Requires data availability and a commitment publication process | Adds unnecessary operational dependencies |
| Stateless submission | Persistent duplicate protection and unpaid entitlements still need an authoritative record | Insufficient |
| Delete paid canonical proofs | Removes durable ownership and duplicate evidence | Rejected |
| Reuse beacon cache | Bounds cache growth without changing signature authentication | Selected |

## Measurements

The isolated native test completed **20,000 accepted proofs and 20,000 claims**, using 1,402 bounded transactions. Its deterministic accounting engine isolates storage and settlement costs; it is not a measurement of Keccak mining throughput. Proof milestones were 100, 1,000, 10,000 and 20,000. The complete run took 5,493.14 seconds and used 1,617,591,919 EVM gas. All allocated, funded, paid and minted amounts reconciled, and the Ledger had no remaining funded balance after settlement.

A separate test used the production Keccak engine and authenticated drand signatures. Two independent miners accepted 12 proofs. Automatic claiming, restart, a dropped accepted-transaction response, a ten-second HTTP outage and 250 ms injected latency were exercised. All rewards were settled. Activating both contract pauses stopped hashing and signing without consuming a miner nonce.

Steady-state single-proof gas in the isolated migration test fell from 186,482 to 134,661 with its accounting engine. Claims after accounts and counters existed used 67,360 gas and did not allocate another proof status row. Production Keccak and BLS calls have their own gas costs and are measured separately.

## Capacity model

For settled operation with a fixed set of beneficiaries, use:

`additional RAM = 346 × accepted proofs + 1,038 × opened epochs + fixed setup costs`

The following projections assume continuous activity, 365 days per year, timely claims, and no future changes to native accounting. They exclude new beneficiary accounts, first token balances, new implementation code and unrelated EVM applications. Values are decimal GB; these are capacity estimates, not reserved quota.

| Activity | Proofs/min | Opened epochs/min | 30 days | 90 days | 1 year | 3 years | 5 years |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Low | 1 | 0.5 | 0.0374 | 0.1121 | 0.4546 | 1.3639 | 2.2732 |
| Expected | 6 | 1 | 0.1345 | 0.4036 | 1.6367 | 4.9102 | 8.1836 |
| High | 60 | 1 | 0.9417 | 2.8250 | 11.4570 | 34.3710 | 57.2850 |

Monitor actual proof and epoch rates, native RAM usage and quota, allocation failures, receipt age, pending nonces, RPC failovers and the oldest unpaid entitlement. Alert when free native quota falls below seven days of measured growth; escalate below one day. Maintain extra space for the largest allowed transaction and deployment operations. The native account is shared, so ZORU's own model cannot predict all usage. Purchasing RAM without reducing persistent rows only postpones exhaustion.

`monitor_mainnet.py` checks chain identity, active implementations, token authority, reward backing and native capacity. Its local capacity history is bounded to one day. It reports alerts and never sends transactions or controls mining.

## Reproduction and migration

`native_ram_probe.py`, `testnet_migration.py`, `testnet_beacon.py`, `testnet_load.py` and `testnet_miner.py` accept explicit isolated-chain credentials and refuse the mainnet native identity. Keep signing material outside the repository.

`proof_inventory.py` reconciles events, individual records, indices, ownership, claims, epoch budgets and token balances at a confirmed block. `native_storage_inventory.py` separately scans the complete native storage scope and rejects unknown, missing or different rows. This supplies the enumeration that Solidity mappings do not provide.

`proof_migration.py` copies bounded batches, independently checks the destination and accounting, then clears the old rows in a separate transaction. Confirmed batch receipts make interruptions resumable and repeated operations idempotent. `release_mainnet.py` requires published source, exact reviewed implementation bytes, both pauses, complete inventories and native irreversibility before final activation. Existing proxy addresses, ownership, token issuer and economics are preserved.

See [References](REFERENCES.md) for the pinned upstream implementation and the limit of source attribution for the native wrapper.

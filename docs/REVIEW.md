# Protocol review — 4 November 2026

The review covers the Token, Ledger, Keccak Engine, authenticated drand Beacon, transparent proxies, ProxyAdmins, upgrade coordinator, historical accounting and Rust miner. Deployment evidence is maintained separately from test evidence. A local fork is not a mainnet deployment.

## Findings and changes

| Area | Finding | Result |
| --- | --- | --- |
| Native RAM availability | Permissionless publication of authentic historical beacon rounds accumulated two cache rows per epoch without accepted mining work | Publication is restricted to the current scheduled epoch; three cache rows are reused |
| Proof storage | Ownership and index occupied two rows; claiming allocated a third row permanently | One complete record retains ownership, epoch, index and payment status |
| Epoch storage | Permanent module addresses and derivable work counters were repeated in historical records | Three rows retain the authoritative epoch state; permanent pointers and work estimates are derived |
| Historical migration | Solidity mappings cannot establish their own complete key inventory | Event and accounting reconciliation is checked against a complete independent native storage scan |
| Nonce recovery | Older production code could fail to locate a consumed nonce outside its recent search window | Historical nonce lookup locates the consuming block; canonical replacement receipts are required before resolving a journal |
| Submission recovery | A missing HTTP response does not establish whether the relay accepted a transaction | The signed hash and nonce are retained before submission; failover does not blindly replay writes |
| Maintenance | Admission and settlement are separate contract controls; pausing admission alone allows settlement | The tested procedure uses both pauses; the claim worker also respects the settlement pause before sealing |
| Miner history | A stale history cursor caused repeated state queries for old finalized proofs | Recent reorganization checks use the current head; historical logs are indexed and pending claims are verified before signing |
| Hashing | The constant proof domain prefix was hashed repeatedly | A prepared Keccak prefix is reused, with differential tests including full-width nonces |
| RPC recovery | An alternate endpoint can belong to another chain | Trusted manifest fallbacks must pass chain identity checks; application reverts do not trigger failover |

Review of access control, initialization, arithmetic, duplicate protection, payment ordering, bounded loops and issuance accounting did not identify an unresolved critical or high-severity defect in the reviewed changes. This is a source and operational review, not an independent security certification.

## Accounting and upgrade invariants

The original proof mapping remains at slot 13 and the original epoch mapping at slot 12. Their declarations and inherited initializer storage remain reserved. Canonical mappings are appended at slots 16 and 21. Official OpenZeppelin validation checks the original release, frozen fixtures, migration implementation and final implementation without unsafe overrides.

Migration blocks proof submission, epoch creation, sealing and claims until the canonical records are complete. Copying and clearing use separate bounded transactions. Every destination, original entitlement, token balance and global accounting counter is checked before cleanup. Unknown native storage rows prevent cleanup. The final implementation contains neither historical-reader fallback nor temporary migration methods.

The full mainnet-state rehearsal includes claimed and unclaimed records, interrupted batches, restart, idempotency, complete cleanup, the original proxy addresses, final activation, historical payment and rejection of double claims. Temporary inventory markers and migration counters are cleared after reconciliation; their eight reserved positions remain zero. Mainnet execution additionally waits for native irreversibility after the last migration operation and before activating the final implementation.

## Verification

| Check | Evidence |
| --- | --- |
| Solidity | 143 tests in the complete suite; 15 targeted boundary, storage and cleanup tests, including four additional boundary and receipt retirement cases; no failed final tests |
| Storage layout | Six original/migration/final comparisons in [storage-validation.json](../release/storage-validation.json) |
| Rust library | 51 passed; two external-fixture tests excluded from that command |
| Rust updater | Three passed |
| Local signed miner integration | Recovery, claim reorganization, automatic claiming and the accepted-proof limit passed on disposable Anvil fixtures |
| Native integration | Existing implementation → migration → cleared source → final implementation → historical and new claims, preserving proxy addresses |
| Native load | 100, 1,000, 10,000 and 20,000 proofs; 20,000 claims; complete allocation and balance reconciliation |
| Native miner | Production Keccak and authenticated drand; two miners, restart, automatic claims, lost submission response, HTTP outage, latency, both pauses |
| Linux desktop | Four test groups passed with the software rendering backend |
| Packaging | Ten package policy tests passed |
| Release safeguards | 41 Python tests passed, including rejection of transfers, wrong chains, excessive fees, incomplete cleanup, missing receipt blocks, native finality checkpoints, duplicate signing, unsafe rebroadcast and lost or rejected submission responses |

Native receipts, RAM deltas and integration metrics are in [testnet-verification.json](../release/testnet-verification.json). Storage assumptions and 30-day through five-year projections are in [Native storage](NATIVE_STORAGE.md). The synthetic accounting load must not be presented as production PoW throughput.

One early oversized native batch exceeded the isolated chain's 150 ms CPU limit and did not consume an EVM nonce. The load was rerun with bounded batches and completed. A separate admission-only pause test correctly stopped proof work while the independently enabled settlement worker sealed an epoch; all its rewards were reconciled, and the complete two-pause procedure passed. A local mining test on an overloaded host performed no hashes because its resource guard activated; the same compiled test passed on an otherwise idle isolated host. These observations were retained rather than counted as successful original attempts.

## Cryptography and authority

The drand BN254 BLS dependency remains pinned to `11af179a8287d978659aae07adb66aa60f64b8a6`. Its upstream is experimental and lacks an independent audit. The review checked scheduled round encoding, trusted public key, signature domain, on-curve validation, the pairing precompile, malformed signatures, subgroup rejection, independently generated RFC 9380 vectors and real authenticated native publications. No signature-verification bypass was identified. Tests do not replace an independent cryptographic audit; dependency provenance remains a documented risk.

The existing owner can replace implementations or the token issuer within the lifetime cap and can pause admission or claims. This authority was preserved. No multisignature policy, economic rule, beneficiary ownership or token ownership was changed. Drand availability, VEX consensus and native administration, RPC availability, signing-host security and continuing native RAM capacity remain operational dependencies. Exact build provenance for the native VEX wrapper was unavailable; the deployed WASM identity and accounting measurements are recorded in [References](REFERENCES.md).

Canonical proof history continues to grow by one row per accepted proof. New epochs continue to consume three rows. Resource alerts must use measured activity and the shared native account's actual quota; storage reduction does not make operation free or unbounded.

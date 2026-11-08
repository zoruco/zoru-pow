# Continuous mining work

The Ledger exposes `miningWork()` as one atomic context: epoch, closing timestamp, authenticated seed, target, generation, pending-beacon status and admission status. Miners obtain the context at one block and compare the digest domain with `digestFor()` before using a changed job.

Authenticated preceding-epoch work remains admissible for up to 30 seconds beyond its nominal 60-second boundary while the next scheduled beacon remains unavailable. Only the immediately preceding epoch may use this window. An unopened preceding epoch can receive its first proof in this window using its verified beacon seed. Its target is derived from closed parent work; an opened epoch retains its stored seed and target. Admission stops when the next authenticated seed is available, at the stored closing timestamp, after sealing, or when the coordinated generation changes. `openEpoch()` cannot end an eligible transition while the next seed is missing.

The drand schedule, public key, signature verification and randomness derivation remain unchanged. A future seed is neither guessed nor exposed early. Once the next seed is authenticated, the preceding proof count cannot increase, so the next target uses a fixed parent count.

A reward budget can be sealed once its transition has ended. A working next beacon permits settlement at the nominal boundary; otherwise the stored deadline bounds the delay to 30 seconds. A retired generation or scheduled activation cannot keep a closed budget locked. An old, already stored closing timestamp is never extended. Each nonempty epoch still allocates one budget, and cumulative-floor payouts still distribute exactly that budget to accepted beneficiaries.

The coordinator checks the clock epoch for transition admission. This prevents previous-epoch submissions from bypassing a scheduled upgrade. The normal generation checkpoint and external proxy administration remain in force.

The implementation adds no storage slots, changes no stored struct layout and retains the existing proof and epoch records. Reserved proxy slots remain reserved. The immutable token, cap, public proxy addresses and issuer do not change.

The Rust engine uses this protocol directly. Hashing has a bounded 15-second job lease to tolerate brief RPC delays; signing, beacon preparation and settlement retain a five-second freshness requirement. An expired job, paused admission, exhausted capacity or unavailable next beacon beyond the transition can still stop useful hashing. Network and resource outages cannot be hidden by displaying an invented rate.

Validation covers signed transition proofs, continuous measured hashing with a delayed seed, stale-candidate rejection before nonce consumption, reward conservation, premature sealing, arbitrary epoch opening, generation changes, scheduled upgrade activation and a pinned mainnet fork with a real unclaimed proof.

References: [drand protocol specification](https://docs.drand.love/docs/specification/), [OpenZeppelin storage rules](https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable).

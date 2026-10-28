# Security

## Owner permissions

The Token has a lifetime cap of 21 million ZORU. Its owner can change the token issuer and authorize upgrades to the Ledger, Engine and Beacon. The owner can also pause proof admission or claims. **Proof-of-work-only issuance is an operating policy, not an immutable contract guarantee.** A replacement issuer could mint tokens within the remaining cap without proof-of-work.

The current owner is a single account; there is no enforced multisignature threshold or timelock. Ownership can be transferred using the Token's two-step acceptance mechanism. Loss or compromise of the owner account may affect issuance, mining and claims.

## Upgrades and recovery

The Ledger, Engine and Beacon use transparent proxies controlled through external ProxyAdmins. The Admin Adapter coordinates upgrades and maintains implementation records. Upgradeability does not protect the immutable Token or a broken proxy shell. Storage corruption, completed transfers and lost keys may not be recoverable.

Changes to implementations require compatible storage layout, preserved reward accounting and verification of the active generation. Previously cached drand results are invalidated for mining when the verification configuration, implementation or suite revision changes. The `invalidateEpochs` function is restricted to the Beacon's ProxyAdmin.

## Randomness and mining

The Beacon verifies scheduled drand evmnet BN254 BLS signatures. The verifier dependency is experimental; its trusted public key, network hash, signature domain and round schedule are security-sensitive. Mining also depends on RPC and drand availability.

Valid proofs require VEX gas and may not be profitable. On-chain proof records incur persistent storage costs. The protocol does not guarantee ASIC resistance, equal hardware performance or transaction inclusion.

Report security issues privately to the maintainers without sharing wallet passwords or private keys.

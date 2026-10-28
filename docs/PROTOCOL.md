# Protocol

ZORU mining is an application on Vexanium EVM. Vexanium supplies transaction ordering and consensus.

## Token and authority

`ZoruToken` is an immutable, non-proxy ERC-20. It has 8 decimals, no initial supply and a lifetime mint cap of 21,000,000 tokens. Burning does not restore mint capacity. Only the configured issuer can mint. The token contains no mining, epoch, reward or halving policy.

One active owner controls the protocol through `token.owner()`. Ownership transfer uses acceptance by the next owner. Renouncing ownership is disabled. There is no timelock, governance vote or required multisig. The owner may later be changed to a reviewed threshold smart-contract wallet using the existing two-step ownership flow. No threshold wallet is currently configured; individual signer approvals are enforced by that wallet rather than the ZORU contracts.

## Work

The work preimage is Solidity `abi.encode` of:

```text
keccak256("ZORU-FLOWPOW-PROOF-1"), chainId, ledgerProxy, token,
generation, epoch, seed, beneficiary, nonce
```

Generation and nonce are full uint256 values; epoch is uint48. The Keccak digest must be strictly below the epoch target. The beneficiary is part of the digest. Copying a submission cannot redirect its reward. A digest is accepted once. Reusing a nonce with another beneficiary, seed, epoch or generation creates different work.

Anybody may publish the scheduled drand evmnet signature. The Beacon verifies its BN254 BLS signature and binds cached randomness to the verification configuration, active Beacon implementation and coordinated suite revision. On a suite upgrade, old cached randomness is automatically treated as untrusted, without deleting each historical epoch. Fresh mining may require republication of the authentic drand signature. RPC and drand availability remain dependencies. The network chain hash, trusted key, round schedule and domain separator must be reviewed together.

## Epochs and rewards

The initial epoch lasts 60 seconds and targets approximately 60 accepted proofs. Difficulty uses accepted work and elapsed epochs, with bounded changes and an explicit easiest target. It cannot measure every miner's unsubmitted work.

The first accepted proof reserves a budget. An empty epoch consumes no allocation. The initial budget is 5 ZORU and halves every 2,100,000 allocated nonempty epochs. Reward amounts are integer multiples of 10⁻⁸ ZORU. Twenty-nine eras produce exactly 20,999,999.727 ZORU; a final 0.273 ZORU budget at emission index 60,900,000 brings the total to exactly 21,000,000 ZORU. No subsidy remains after that. These rules belong to the upgradeable Ledger.

An epoch's payout is the difference between consecutive cumulative floors: `floor(budget × (index + 1) / proofs) − floor(budget × index / proofs)`, calculated in base units. The resulting amounts sum to the complete epoch budget even if some very late-era proofs receive zero base units. Reaching the lifetime cap requires enough nonempty epochs and settlement; it is not guaranteed by elapsed calendar time.

The token enforces the lifetime cap, but the current owner can replace the issuer and the owner-controlled Ledger can be upgraded. Consequently **PoW-only issuance is not immutable in the current source**. A release promising that all ZORU is mined must first enforce issuance and proof validity through a mechanism that an arbitrary owner-appointed issuer or implementation cannot bypass.

Any caller may seal a closed epoch or claim an accepted proof. Claims always pay the recorded beneficiary, regardless of who submits the transaction. Unclaimed rewards remain liabilities of the Ledger, and claims do not expire under the current rules.

An opened epoch stores its closing timestamp. Clock changes cannot reopen a sealed epoch or delay an already mature budget. Allocation, funded backing, paid rewards and outstanding liabilities are accounted separately.

## Upgrades

Ledger, Engine and Beacon each use an OpenZeppelin TransparentUpgradeableProxy. The public proxy addresses, token address, issuer and module pointers stay fixed during routine implementation upgrades. Replacement implementations have new addresses.

The external coordinator owns each ProxyAdmin and takes authority from the token owner. Normal upgrades are scheduled for an epoch boundary. Emergency repairs advance the generation and checkpoint the Ledger. Accepted proofs and funded claims remain recorded through rollback. A failed implementation cannot prevent its external ProxyAdmin from replacing it.

Storage changes require review of field order, packing, nested structures and initializer state. Code hashes identify reviewed code; they do not prove storage safety. Proxy shells, the immutable token and external coordinator have their own limits, described in the security model.

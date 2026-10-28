# Cryptographic dependency

The ZORU beacon verifier uses the BN254 BLS implementation from
[randa-mu/bls-solidity](https://github.com/randa-mu/bls-solidity), pinned at
commit `11af179a8287d978659aae07adb66aa60f64b8a6`.

The files `BLS.sol`, `ModExp.sol` and `Precompiles.sol` are exact copies of
`src/libraries/` at that revision, included under the upstream MIT license.
See `LICENSE` in this directory. The upstream repository is archived and
labels the implementation experimental and unaudited.

The G2 curve helpers do not establish subgroup membership. The released
verifier relies on the EIP-197 pairing precompile for that check.

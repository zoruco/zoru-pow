# Validation

## Contracts

Run from the repository root:

```sh
npm ci
cd contracts
forge build
forge test --threads 1 --no-match-test testTenThousandSybilWalletsReceiveOnlyTheirAcceptedWorkShare
forge test --threads 1 --match-test testTenThousandSybilWalletsReceiveOnlyTheirAcceptedWorkShare
FOUNDRY_PROFILE=runtime forge build --threads 1
```

Tests cover proof acceptance, duplicate prevention, emission accounting, epoch sealing, claims, recovery and upgrade behavior. Environment-dependent tests must be reported separately.

## Mainnet verification

Check contract bytecode, proxy implementations, Token owner and issuer, launch configuration, and the manifest against chain 6736. The verification command and addresses are in [Mainnet](docs/MAINNET.md).

A successful build or read-only network check does not establish that signed mining and claims have completed on mainnet.

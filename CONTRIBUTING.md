# Contributing

Bug reports, security improvements, tests, documentation, and focused code changes are welcome.

Open an issue before proposing a substantial protocol change. In a pull request, explain the problem, describe the change, and include test commands, results, and known limitations. Keep unrelated work in separate pull requests.

## Testing

Run relevant Foundry tests. Changes to proof admission, rewards, accounting, ownership, storage, upgrades, or cryptography require the full regression suite, fuzz and invariant checks, and the large accounting fixture when applicable.

Review storage layouts and upgrade rollback behavior. Coordinate interface or mining-rule changes with the companion Rust miner. See [Mainnet](docs/MAINNET.md) and [Validation](VALIDATION.md).

Do not include wallet credentials, signing journals, private deployment records, or local operational logs in commits or issues. Preserve third-party licenses. Report exploitable vulnerabilities privately through the maintainer's published security channel.

## Review

Maintainers approve source changes and releases separately. A merged pull request does not authorize a deployment, ownership transfer, or signed transaction. See the [release policy](docs/RELEASE_POLICY.md) for approval requirements.

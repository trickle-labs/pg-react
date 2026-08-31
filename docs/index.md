# pg-react documentation

This is the starting point for current pg-react documentation. M40 / extension
`0.37.0` is the current qualified release. It adds a bounded, read-only
why-not question for one expected result while keeping the earlier explain
output unchanged when the option is absent. M41 end-to-end causal paths is the
current planning milestone and targets extension `0.38.0`. The prepared
`1.0.0-rc.1` candidate remains outside the current release sequence.

## Start

- [Glossary](../GLOSSARY.md)
- [Getting Started](getting-started.md)
- [Order Review Tutorial](order-review-tutorial.md)
- [Runnable Order Review Package](../showcase/order-review/README.md)
- [Concepts](concepts.md)

## Build

- [Authoring Rules and Policies](v1-authoring.md)
- [Changing Policies Safely](changing-policies.md)
- [Hypothetical Fact Simulation](m35-api-reference.md)
- [Historical Replay](m36-api-reference.md)
- [Comparative Backtesting](m37-api-reference.md)
- [Why-changed comparison](m38-api-reference.md)
- [Simulation qualification](m39-api-reference.md)
- [Bounded why-not](m40-api-reference.md)
- [API Reference](v1-api-reference.md)

## Operate

- [Installation](v1-installation.md)
- [Operations](v1-operations.md)
- [Security](v1-security.md)
- [Backup and Restore](v1-backup-restore.md)
- [Upgrade](v1-upgrade.md)
- [Troubleshooting](v1-troubleshooting.md)

## Reference

- [M40 bounded why-not contract](m40-contract.md)
- [M39 simulation contract](m39-contract.md)
- [M34 v1 baseline contract](v1-contract.md)
- [Limits](v1-limits.md)
- [Support Matrix](v1-support-matrix.md)
- [Known Limitations](v1-known-limitations.md)
- [Release Notes](m40-release-notes.md)

## Project / History

- [Roadmap](../ROADMAP.md)
- [Historical milestone documentation](history.md#milestone-documentation)
- [Qualification evidence](history.md#qualification-evidence)

Milestone records are retained for maintainers and auditors. They are not the
normal installation, authoring, or operations path.

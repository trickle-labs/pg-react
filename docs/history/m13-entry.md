# M13 entry evidence

M13 product work is authorized by the immutable `v0.9.0` release at commit
`3cff99f84f463862534eea7d34d4ef2c82ba30c9`. The public non-draft,
non-prerelease GitHub release was published on 2026-08-12 by successful release
workflow run
[`31597152095`](https://github.com/trickle-labs/pg-react/actions/runs/31597152095).

The published `linux/amd64` artifacts are:

- archive: `pg-react-v0.9.0-linux-amd64.tar.gz`;
- archive SHA-256: `d7ee93024387ac8d586afa8bbc73ed3552d535dbfbae780715687b4d18d3a56b`;
- OCI image: `ghcr.io/trickle-labs/pg-react:v0.9.0`;
- OCI digest: `sha256:2cbaeb1f3bd67b738025ad5712de19f67520aac24ff3e1821e39606fe48ee6ad`;
- release: <https://github.com/trickle-labs/pg-react/releases/tag/v0.9.0>.

The checksum manifest, release notes, populated `0.8.0 -> 0.9.0` upgrade,
worker, failure, restart, physical-recovery, and inherited gates satisfy the
M13 entry boundary. The frozen M13 fixtures are `m13-api.sql`,
`m13-concurrency-setup.sql`, `m13-hold-run.sql`, `m13-drift.sql`,
`m13-program.sql`, `m13-upgrade.sql`, and `m13-recovery-*.sql`.

# M12 entry evidence

M12 product work is authorized by the immutable `v0.8.0` release at commit
`97acd5c8e9265915ae67ebcfe94e039c94214dd4`. The local and remote tag resolve
to that same commit, and the public GitHub release was published on
2026-08-12 as a non-draft, non-prerelease release.

The published `linux/amd64` archive was downloaded and verified against its
manifest:

- archive: `pg-react-v0.8.0-linux-amd64.tar.gz`;
- archive SHA-256: `4ca2efe53f71572cbddaccbb771a9505d549ad2169718f793780501ca1418f07`;
- OCI image: `ghcr.io/trickle-labs/pg-react:v0.8.0`;
- OCI digest: `sha256:5abe5923308d7b2b97732ae7ebd0b51cd979f2db86feea2c2d797595ffa2c42f`;
- release: <https://github.com/trickle-labs/pg-react/releases/tag/v0.8.0>.

The release notes disclose the `0.7.0 -> 0.8.0` populated upgrade, unchanged
PostgreSQL/pg_trickle/pgrx/Linux boundary, physical recovery, worker protocols
1 and 2, resource limits, and at-least-once external effects. `tests/m11.sh`
is the exact executable M11 qualification and upgrade baseline inherited by
M12.

The frozen M12 reference workload is `tests/m12-reference.sql`: future,
equality, overdue, advancement, postponement, deletion, downtime, backward
and forward samples, restart, physical recovery, and upgrade have exact
lifecycle, agenda, clock, diagnostic, status, and explanation expectations.

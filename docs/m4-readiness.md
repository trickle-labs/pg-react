# M4 readiness: v1 general availability

M4 is implemented for extension and crate version `0.1.1`, worker protocol `1`,
outbox envelope `1`, and the immutable direct `0.1.0 -> 0.1.1` migration. It
freezes the narrow M3 compatibility matrix; it does not widen maintenance
modes, RLS, key codecs, PostgreSQL versions, operating systems, or
architectures.

## Gate assessment

| GA requirement | Direct evidence | Status |
| --- | --- | --- |
| M3 gates pass on the release artifact | [`tests/m4.sh`](../tests/m4.sh) builds one `linux/amd64` image, checks its image ID, and runs M0, M1, scale, M2, and M3 against it | Complete |
| SQL API, protocol, migration, compatibility, and delivery are frozen | [`v1-contract.md`](v1-contract.md) and [`tests/m4-api.sql`](../tests/m4-api.sql) | Complete |
| Task-oriented documentation | v1 [installation](v1-installation.md), [authoring](v1-authoring.md), [operations](m3-operations.md), [security](v1-security.md), [backup/restore](v1-backup-restore.md), [upgrade](v1-upgrades.md), and [troubleshooting](v1-troubleshooting.md) guides | Complete |
| Exact README workflow runs on the artifact | [`tests/m4-reference.sh`](../tests/m4-reference.sh) executes the copied example through the packaged `pg-reactd` | Complete |
| Correctness and recoverability audit | M0–M3 suites plus the physical recovery pilot; unsupported logical live-rule restore is rejected and published as a limitation | Complete within the supported matrix |
| Artifacts, checksums, notes, and limitations publish together | [release workflow](../.github/workflows/release.yml) gates, pushes, packages, checksums, records the OCI digest, and creates the exact `v0.1.1` release | Ready on tag |
| Internal production exercise | [`m4-pilot.md`](m4-pilot.md) records install, normal operation, injected failure, physical restore, resumed work, and direct upgrade | Complete |

The requirement-by-requirement record is in [`m4-evidence.md`](m4-evidence.md).
The release must be cut only from this validated commit: push it, create the
exact `v0.1.1` tag, let the release workflow publish the tested bytes, and
verify the attached checksum and registry digest. M5 work starts only after
that publication succeeds.

## Important recovery boundary

Physical backup/PITR is the supported v1 recovery mechanism. A logical
`pg_dump`/`pg_restore` of live pg-react rules is unsupported with pinned
pg_trickle `0.81.0`: its public restore functions do not rebuild restored
source OIDs and differential change tracking. Treating that path as supported
could silently miss a later lifecycle transition, so M4 fails it closed and
documents the boundary instead of shipping partial catalog repair.

# M7 readiness

## Repository state

The `0.4.0` implementation, direct `0.3.0 -> 0.4.0` migration, maintained derived catalogs, public query/explanation/repair APIs, rule-pack graph lifecycle, documentation, and Docker-backed gate are implemented. The inherited support boundary remains `linux/amd64`, PostgreSQL 18.3, pg_trickle 0.81.0, `READ COMMITTED`, coordinator-owned `DIFFERENTIAL`, one non-null `bigint` key, physical recovery, and no RLS source views.

`tests/m7.sh pg-react:v0.4.0` reruns M0–M6 before exact M7 lifecycle, order, conflict, boundary, pack, upgrade, crash-restart, and physical-restore checks. Fresh `0.4.0` installation SQL is mechanically identical to the `0.3.0` installation followed by the M7 upgrade script.

## External entry and release state

The M7 entry gate is satisfied by the exact public `v0.3.0` tag, archive, `linux/amd64` OCI manifest, checksums, and successful release/CI workflows recorded in `docs/m7-entry.md`.

The exact `v0.4.0` release was published and verified on 2026-08-09. Its tag,
successful release run, archive checksum, and `linux/amd64` OCI digest are
recorded in `docs/m8-entry.md`.

# v1 support matrix

This matrix is intentionally narrow. “Unqualified” means the repository has
not produced support evidence; it does not mean best-effort compatibility.

## Qualified support boundary

| Area | Supported | Unqualified or unsupported |
| --- | --- | --- |
| PostgreSQL | 18.3 | Other PostgreSQL versions |
| pg_trickle | 0.81.0 from the pinned release image | Other pg_trickle versions |
| OS / CPU | Linux amd64 | Other operating systems and architectures |
| pg-react artifact | Published `0.31.0` OCI image and extension files containing the v1 feature set | No `1.0.0-rc.1` or `1.0.0` artifact exists yet |
| Preload | `shared_preload_libraries = 'pg_trickle,pg_react'` | Loading only pg_trickle |
| Isolation | `READ COMMITTED` | Other isolation modes are unqualified |
| pg_trickle settings | `user_triggers=auto`, scheduler off, differential ratio `1.0` | pg_trickle automatic scheduling or uncoordinated refresh |
| Maintenance | PostgreSQL-managed polling and coordinated explicit differential refresh | Independent refresh scheduling |
| Runtime topology | One PostgreSQL-managed worker per unique configured database, using worker protocol 2 | A global cross-database coordinator; `pg-reactd` as the primary runtime |
| Evaluated sources | Schema-qualified, caller-readable, non-RLS PostgreSQL relations | RLS-protected, unauthorized, or private pg-react sources |
| Comparison | Current authoritative facts; `rule`, `decision_program`, and `policy_set`; bounded evidence; matching target kind/name | Hypothetical fact changes, historical replay, backtesting, or other kinds |
| Comparable rule key | One non-null unique `bigint` key | UUID, text, or composite rule keys in `pgreact.compare` |
| Physical recovery | Qualified physical backup/restore, PITR, crash restart, standby behavior, and primary promotion within the supported tuple | Other replication/failover topologies |
| Logical restore | Application schema/data plus declaration replay, followed by rebuild/reconciliation and verification | Restoring live pg-react private catalogs as a portable logical backup |
| External delivery | Transactional outbox with at-least-once delivery | Exactly-once external effects |

## Build facts

The 0.31.0 extension is built with pgrx 0.18.0 and Rust 1.89.0. These identify
the release build toolchain; they are not promises that arbitrary pgrx or Rust
versions are user-supported configurations.

## Runtime caveats before the first RC

- `src/managed.rs` runs cycles only for an installed extension whose version
  string is exactly `0.31.0`; RC/GA version handling is not implemented.
- Fresh 0.31.0 role configuration does not reapply the M34 comparison grants;
  installation must grant comparison explicitly to author, operator, and
  reader roles.
- `pg_react.batch_size` accepts `1..1000`, but the public work claim is limited
  to `1..100`.

These are RC blockers, not broader support promises.

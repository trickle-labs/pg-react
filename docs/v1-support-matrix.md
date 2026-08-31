# v1 support matrix

This matrix is intentionally narrow. “Unqualified” means the repository has
not produced support evidence; it does not mean best-effort compatibility.

## Qualified support boundary

| Area | Supported | Unqualified or unsupported |
| --- | --- | --- |
| PostgreSQL | 18.3 | Other PostgreSQL versions |
| pg_trickle | 0.81.0 from the pinned release image | Other pg_trickle versions |
| OS / CPU | Linux amd64 | Other operating systems and architectures |
| pg-react artifact | `v0.37.0` release image and extension files; documented adjacent update `0.36.0 -> 0.37.0` | Releases before `0.31.0`; unreleased or untracked candidate versions |
| Preload | `shared_preload_libraries = 'pg_trickle,pg_react'` | Loading only pg_trickle |
| Isolation | `READ COMMITTED` | Other isolation modes are unqualified |
| pg_trickle settings | `user_triggers=auto`, scheduler off, differential ratio `1.0` | pg_trickle automatic scheduling or uncoordinated refresh |
| Maintenance | PostgreSQL-managed polling and coordinated explicit differential refresh | Independent refresh scheduling |
| Runtime topology | One PostgreSQL-managed worker per unique configured database, using worker protocol 2 | A global cross-database coordinator; `pg-reactd` as the primary runtime |
| Evaluated sources | Schema-qualified, caller-readable, non-RLS PostgreSQL relations | RLS-protected, unauthorized, or private pg-react sources |
| Simulation | Current or typed hypothetical comparison; caller-supplied replay; at most two backtest sides; bounded why-changed evidence; bounded why-not for modeled current results | History capture or reconstruction; durable simulation jobs; more than two sides; general why-not answers |
| Comparable rule key | One non-null unique `bigint` key | UUID, text, or composite rule keys in `pgreact.compare` |
| Physical recovery | Qualified physical backup/restore, PITR, crash restart, standby behavior, and primary promotion within the supported tuple | Other replication/failover topologies |
| Logical restore | Application schema/data plus declaration replay, followed by rebuild/reconciliation and verification | Restoring live pg-react private catalogs as a portable logical backup |
| External delivery | Transactional outbox with at-least-once delivery | Exactly-once external effects |

## Build facts

The `v0.37.0` extension is built with pgrx 0.18.0 and Rust 1.89.0. These identify
the release build toolchain; they are not promises that arbitrary pgrx or Rust
versions are user-supported configurations.

## Current release boundaries

- The managed runtime accepts extension versions `0.31.0` through `0.37.0`,
  `1.0.0-rc.N`, and `1.0.0`.
- `pgreact_api.configure_roles(...)` authoritatively configures
  comparison execution permissions (`pgreact.compare`, `pgreact.compare_results`)
  across application roles.
- PostgreSQL-managed worker cycles cap job claims to `least(batch_size, 100)`
  items, respecting the `1..100` public work-claim limit even when
  `pg_react.batch_size` is configured higher.

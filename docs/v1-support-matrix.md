# v1 support matrix

This is the narrow, tested boundary. A tuple not listed here is unsupported
or experimental; it is not best-effort compatible.

| Property | Supported value |
| --- | --- |
| PostgreSQL | 18.3 |
| pg_trickle | 0.81.0, pinned release image |
| pgrx / Rust | pgrx 0.18.0 / Rust 1.89.0 |
| OS / CPU | Linux / amd64 |
| Packaging | published OCI image and extension files |
| Maintenance | coordinator-owned explicit `DIFFERENTIAL` |
| Isolation | `READ COMMITTED` |
| Preload | `pg_trickle, pg_react` |
| Runtime | PostgreSQL-managed worker with configured database and role |
| RLS | unsupported for evaluated source dependencies; `doctor()` blocks |
| Replication | physical backup/PITR and supported primary promotion |
| Logical restore | supported only through the documented reconciliation policy |
| External delivery | transactional outbox, at least once |

Automatic scheduler refresh, uncoordinated refresh, arbitrary RLS evaluation,
other architectures, and exactly-once external effects are outside v1.

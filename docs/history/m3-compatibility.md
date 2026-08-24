# M3 compatibility matrix

M3 supports one deliberately small production-candidate tuple. Any row not listed here is unsupported and must fail rather than silently downgrade behavior.

| Component | Supported value | Operational decision |
| --- | --- | --- |
| PostgreSQL | 18.3 | Primary or promoted primary only; workers never claim on a standby. |
| `pgrx` | 0.18.0 | Build validation uses `cargo test --no-default-features`; the shipped SQL image has no pg-react preload library. |
| `pg_trickle` | 0.81.0 at `ba41c9c2e2bbf2195917fcdcc89efa8ab3089dcb` | `pg_trickle.enabled=off`, `user_triggers=auto`, and `differential_max_change_ratio=1.0`. |
| OS / architecture | Linux container, `linux/amd64` | The pinned image digest in `Dockerfile` is the reproducible RC artifact. macOS is supported only as a Docker host. |
| Maintenance | Coordinator-owned explicit `DIFFERENTIAL` | `AUTO`, `FULL`, `IMMEDIATE`, scheduler refresh, early deferred-trigger firing, and uncoordinated refresh remain unsupported. |
| Isolation | `READ COMMITTED` | The coordinator and extension reject any other command-rule isolation level. |
| Semantic keys | One non-null `bigint`, codec v1 | No additional codecs are approved. |
| RLS / evaluation role | Rejected | Sources with enabled or forced RLS fail validation; execution remains the rule owner through its exact dispatcher. |
| pg-react extension | 0.1.1, upgradeable from 0.1.0 | The migration installs M3 catalog/API changes; `rebuild_transient_metadata()` repairs local OID references afterward. |
| Worker protocol | `1` | Rolling workers may overlap only while `pgreact.worker_protocol_compatible(1)` is true. |

The M0 adapter contract remains authoritative for the pg_trickle boundary. M3 adds operational support around it; it does not broaden it.

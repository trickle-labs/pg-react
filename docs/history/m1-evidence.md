# M1 evidence

| M1 requirement | Executable evidence |
| --- | --- |
| Public view-backed constraint and activate-only command registration, validation, preview, inspection, pause/resume, drained replacement, and removal | `tests/m1.sql` |
| Coordinator-only `DIFFERENTIAL` refresh without adaptive `FULL` fallback, bigint-v1 key limit, and barrier protocol | `tests/m0.sh`, `bin/pg-reactd`, `docs/m1-readiness.md` |
| One-item lease, atomic typed execution, failed-attempt audit, manual requeue, and expiry sweep | `tests/m1.sql` |
| Immutable source snapshot and visible drift | `tests/m1.sql`, `pgreact.health_check()` |
| Owner authorization, hidden pg-react private catalog, direct RLS-source rejection, and fixed dispatcher path | `tests/m1.sql` |
| Compatible source drift warning, incompatible row-signature claim block, and consequence-binding invalidation | `tests/m1.sql`, `pgreact.health_check()` |
| Lifecycle, key safety, restart, DDL serialization, and reconciliation invariants inherited by alpha | `cargo test --no-default-features`, `tests/m0.sh` |
| Fixed-shape scale smoke for activation bursts, no-change refresh, many rules, repeated replacement, and payload growth | `tests/m1-scale.sh`, `m1-scale-baseline.md` |

Run the complete local evidence with `docker compose up -d --build`, wait until `pgreact` exists, then run `bash tests/m0.sh && bash tests/m1.sh && bash tests/m1-scale.sh`.

The pinned `pg_trickle` line requires rule authors to have its documented catalog privileges; pg-react keeps `pgreact_internal` and payload relations private.

M1 deliberately does not add change/deactivation consequences, automatic retry, heartbeat, multi-worker claiming, outbox delivery, or a wider pg_trickle/key-codec support matrix.

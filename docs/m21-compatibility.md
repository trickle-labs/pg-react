# M21 compatibility inventory

| Area | M21 contract |
| --- | --- |
| Extension | `0.18.0`; direct upgrade from `0.17.0` |
| PostgreSQL | `18.3` only |
| pg_trickle | `0.81.0` only; `user_triggers=auto` |
| Isolation | `READ COMMITTED` only |
| Policy | disabled by default |
| Operator boundary | configure, remove, preview, apply, and audit are operator-only |
| Safety | current/executable state, active supports/open windows, and pending work are protected |
| Execution | bounded, idempotent batches |
| Diagnostics | exact loss-of-detail diagnostics from preview and apply |
| Next milestone | M22 — Bounded support provenance |

# M13 evidence

`tests/m13.sh pg-react:v0.10.0` is the repository gate. It runs inherited
M0–M12 qualification and then M13 fresh-install, inventory, overload,
resolution, terminology, privilege, concurrency, failure, program, worker,
upgrade, crash/restart, and physical-recovery fixtures.

| Requirement | Executable evidence |
| --- | --- |
| Named common authoring and exact arguments | `m13-api.sql` authors constraint, activation-only, lifecycle, and deadline rules and freezes complete context-free/context-aware effects |
| Safe immutable action selection | `m13-api.sql` freezes missing, ambiguity, defaults, variadic, polymorphic, unauthorized, and search-path-decoy results; `m13-drift.sql` proves post-deployment drift rejection |
| One complete dependency-ordered run | `m13-api.sql` combines source and deadline changes; `m13-program.sql` proves program-before-downstream observation in the same run |
| Repetition, failure, and concurrency | `m13-api.sql` proves no-op repetition and complete injected rollback; `m13-hold-run.sql` plus `m13-concurrency-result.sql` prove transaction-lock serialization and exact state |
| Exact role matrix and escalation failure | `m13-api.sql` compares every facade overload granted to all four roles and executes a denied reader mutation |
| Friendly vocabulary with lossless history | `m13-api.sql` freezes `status`, `explain`, `matches`, `jobs`, and `attempts` inventory while retaining the advanced compatibility calls |
| Populated direct upgrade and grant repair | `m13-upgrade.sql` compares complete M12 rows across `0.9.0 -> 0.10.0`, repairs stale broad grants, and runs a new context-free rule |
| Worker and inherited protocols | `m13.sh` runs the bundled worker through the canonical facade and exact M12 worker result, while nested M0–M12 gates retain both protocols |
| Crash, restart, restore, grants, and action parity | `m13-recovery-*.sql` through `m6-recovery.sh` verifies the role map, binding digest, context-free effects, deadline catch-up, and exact physical state |

M13 adds no benchmark target: coordinator work remains the same bounded
incremental engine calls under one lock. The inherited M3, M6, M8, M10, and M12
resource and performance gates remain authoritative.

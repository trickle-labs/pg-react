# M0 evidence

| Requirement | Executable evidence |
| --- | --- |
| Pure planner, bigint codec, deterministic identity, and identical physical history/reference outcome from the same seed | `cargo test --no-default-features` |
| Installable pinned environment and adapter checks | `Dockerfile`, `docker-compose.yml`, `pgreact_internal.assert_m0_compatibility()` |
| Rollback and atomic typed consequence completion | `tests/m0.sql` rollback blocks |
| Final-state delete-plus-insert coalescing and generation 2 reactivation | `tests/m0.sql` lifecycle blocks |
| Opposite-side join transactions | `tests/m0.sh` concurrent customer/order transactions |
| Null/duplicate runtime-key abort and durable disconnect barrier | `tests/failed_refresh.sql`, driven by `tests/m0.sh` |
| No claim inside the refresh window | `tests/hold_barrier.sql`, driven by `tests/m0.sh` |
| Claim-excluding, idempotent, no-work `STATE_ONLY` reconciliation equivalent to differential state | `tests/m0.sql` reconciliation block and the reconciliation race in `tests/m0.sh` |
| Consequence/dispatcher DDL serialization | `tests/m0.sh` lock-timeout race |
| Restart durability and logical dump/restore identity fixtures | final blocks of `tests/m0.sh` |

Run the complete gate with `docker compose up -d --build && bash tests/m0.sh`.

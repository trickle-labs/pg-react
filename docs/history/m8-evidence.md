# M8 evidence

M8 is extension `0.5.0`. `tests/m8.sh` is the complete repository gate.

| ROADMAP gate | Authoritative evidence |
| --- | --- |
| Published `v0.4.0` entry artifacts and frozen recursive fixture | Exact tag, release run, archive checksum, OCI digest, program, stages, and explanations in `docs/m8-entry.md` |
| Exact least fixed point for the chain, cycle, alternatives, and seed removal | Frozen V1 frontiers and exact facts, support counts, components, downstream events, and clean recomputation in `tests/m8.sql` |
| Equivalent delta order, scheduling, timing, restart points, and histories | Normalized histories from `tests/m8-order.sql` are compared byte-for-byte by `tests/m8.sh`; restart state is compared in `tests/m8-recovery-setup.sql` and `tests/m8-recovery-restore.sql` |
| One atomic frontier; evaluation and resource failure preserve prior state | Exact injected-phase rollback in `tests/m8.sql` and `tests/m8-pack.sql`; public `FAILED` history in `tests/m8-author.sql`; exact resource rollback and durable diagnostic in `tests/m8-resource-failure.sql` |
| Exact pre-mutation rejection of every frozen unsupported program | Every frozen diagnostic, standalone `UNION`, malformed limits, graph-closure guards, and unchanged catalog/runtime snapshots in `tests/m8-boundary.sql` |
| Drift, injected failure, replacement, removal, DDL/refresh serialization, and component split/merge | Exact V1-to-V2-to-V3 graphs, previews, rollback, and history in `tests/m8-pack.sql`; lock orchestration in `tests/m8.sh`; teardown in `tests/m8-pack-remove.sql` |
| Exact reconciliation of every corrupt state | Missing, extra, stale, circular-only, and wrong-frontier repair output plus second no-op in `tests/m8.sql` |
| Restart, physical restore, and direct `0.4.0 -> 0.5.0` upgrade | Exact inherited and recursive state in `tests/m8-upgrade.sql`, `tests/m8-recovery-setup.sql`, and `tests/m8-recovery-restore.sql` |
| Finite grounded explanation that terminates on cycles | Exact alternative proof paths, stable input edges, cycle marker, seed retraction, and SQL `NULL` output in `tests/m8.sql` |
| Complete M0-M7 and public-behavior compatibility | Every inherited gate is invoked first by `tests/m8.sh` against the `0.5.0` candidate |
| Public end-to-end workflow | An explicitly granted non-superuser deploys, queries, explains, observes a failed run, retries, and reconciles in `tests/m8-author.sql`; replacement, promotion, upgrade, and recovery continue in the remaining M8 fixtures |

The exact published `v0.5.0` artifacts and qualification are recorded in
`docs/m9-entry.md`.

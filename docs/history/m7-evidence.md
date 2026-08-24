# M7 evidence

M7 is extension `0.4.0`. `tests/m7.sh` is the complete repository gate.

| Requirement | Authoritative evidence |
|---|---|
| Versioned typed relation, immutable derivation, portable identity, ownership, and no agenda | Catalog constraints and exact lifecycle assertions in `tests/m7.sql` and `tests/m7-boundary.sql` |
| Two supports, partial removal, last-support retraction, restoration, exact provenance, and frontier no-op | Frozen F0–F4 output in `tests/m7.sql` |
| Ordering independence and clean-state equivalence | Opposite addition/removal order fixtures with exact normalized output in `tests/m7-order.sql` |
| Atomic support/fact state and conflicting-payload rollback | Exact transaction rollback in `tests/m7-conflict-setup.sql` and `tests/m7-conflict-result.sql` |
| Non-recursion, read-only public relation, ownership, and provenance retention | Exact rejection and retained-history output in `tests/m7-boundary.sql` |
| Missing, extra, and stale support/fact repair with public diagnostics | Injected corruption, exact F4 repair, exact diagnostic list, and second no-op in `tests/m7.sql` |
| Atomic pack add, replace, remove, preview drift, injection rollback, and dependency ordering | Exact manifests, previews, histories, and graph states in `tests/m7-pack.sql` |
| Concurrent refresh, replacement, and source/relation/downstream DDL | Lock serialization, native dependency rejection, and exact surviving graph in `tests/m7-concurrency-setup.sql` and `tests/m7-concurrency-result.sql` |
| Direct upgrade and inherited state continuation | Exact claimed M6 batch preservation/continuation and post-upgrade derived workflow in `tests/m7-upgrade.sql` |
| Crash restart and physical restore | Byte-exact derived catalog, fact, support, frontier, diagnostic, and explanation snapshots in the M7 fixtures run by `tests/m6-recovery.sh` |
| M0–M6 compatibility | Complete inherited gate invoked by `tests/m7.sh` on `0.4.0` |
| Public workflow | Definition, refresh, observation, explanation, retraction, reconciliation, pack, and recovery instructions in `docs/m7-contract.md` |

The exact `v0.3.0` entry evidence is frozen in `docs/m7-entry.md`. The published
`v0.4.0` tag, successful release run, archive checksum, and `linux/amd64` OCI
digest are recorded in `docs/m8-entry.md`.

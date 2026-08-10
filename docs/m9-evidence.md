# M9 evidence

M9 is extension `0.6.0`. `tests/m9.sh` is the complete repository gate.

| ROADMAP gate | Authoritative evidence |
| --- | --- |
| Published `v0.5.0` entry artifacts and frozen stratified fixture | Exact tag, release run, archive checksum, OCI digest, program, stages, and explanations in `docs/m9-entry.md` |
| Exact stratified result and deletion-sensitive truth | Exact facts, supports, graph, strata, frontiers, negative evidence, and downstream events in `tests/m9-slice2.sql` through `tests/m9-slice4.sql` |
| Equivalent delta and scheduling orders; one atomic frontier | Byte-exact forward/reverse results in `tests/m9.sh`; injected rollback and repeated refresh in `tests/m9-slice3.sql` and `tests/m9-slice4.sql` |
| Exact pre-mutation rejection and PostgreSQL `NULL` behavior | Frozen diagnostics, unchanged state, and keyed `NULL` fixtures in `tests/m9-slice2.sql` |
| Atomic preview, replacement, removal, DDL serialization, and stratum changes | Exact plans and states in `tests/m9-slice5.sql`; lock orchestration and removal fixtures in `tests/m9.sh` |
| Exact explanation and reconciliation | Grounded proof with negative checks plus missing, extra, stale, wrong-stratum, and wrong-frontier repair in `tests/m9-slice6.sql` |
| Restart, physical restore, and direct `0.5.0 -> 0.6.0` upgrade | Exact state in `tests/m9-upgrade.sql`, `tests/m9-recovery-setup.sql`, and `tests/m9-recovery-restore.sql` |
| Complete M0-M8 compatibility | Every inherited gate is invoked first by `tests/m9.sh` against the `0.6.0` candidate |
| Public end-to-end workflow | An explicitly granted non-superuser validates, previews, deploys, queries, explains, invalidates, restores, retries, reconciles, and replaces a stratified program in `tests/m9-author.sql` |

Candidate behavior is qualified from one locally built `linux/amd64` image.
Release qualification must repeat `tests/m9.sh` against the exact published
`0.6.0` bytes.

# M27 compatibility inventory

| Area | M27 contract |
| --- | --- |
| Extension | `0.24.0`; direct upgrade from `0.23.0` |
| PostgreSQL | 18.3; `READ COMMITTED` |
| Decision model | M26 versioned decision program with one proposed version under analysis |
| Population | One finite typed PostgreSQL relation and semantic key |
| Candidate catalog | One declared catalog of candidate identities |
| Frontier | One complete committed frontier with recorded relation fingerprints |
| Findings | Ties, forbidden overlap, missing defaults, unreachable candidates, uncovered subjects, and distribution limits |
| Evidence | Canonically ordered, bounded, with truncation disclosure |
| Distribution | Exact current/proposed counts and deltas by candidate identity |
| Admission | Blocking requirements checked against the analyzed snapshot; stale reports rejected |
| Authorization | Inherited PostgreSQL ownership, grants, and reader/author/reviewer/deployer/operator boundaries |
| Recovery | Inherited coordinator, retention, restore, standby-promotion, and worker paths |
| Upgrade | Populated direct `0.23.0 -> 0.24.0` path |
| Next milestone | M28 — Public API convergence and ergonomics |

M27 does not provide a predicate parser, proof over hypothetical or undeclared
facts, policy-set gating, per-key deployment impact simulation, replay,
backtesting, cross-program conflict analysis, or a new authoring language.

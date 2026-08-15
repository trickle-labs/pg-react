# M26 compatibility inventory

| Area | M26 contract |
| --- | --- |
| Extension | `0.23.0`; direct upgrade from `0.22.0` |
| PostgreSQL | 18.3; `READ COMMITTED` |
| pg-trickle | 0.81.0; inherited differential stream path |
| Decision model | One versioned program over one maintained PostgreSQL candidate relation |
| Subject identity | Stable declared semantic key |
| Candidate identity | Stable declared candidate key; unique `(subject, candidate)` |
| Selection | Lowest non-null `bigint` priority wins; tied best candidates are ambiguous |
| Results | One or more supported typed result columns; no generated policy language |
| Public states | Never observed, no candidate, winner, or ambiguity |
| Evidence | Bounded, canonical competitor ordering with truncation disclosure |
| Maintenance | Affected-subject recomputation through the inherited coordinator |
| Versions | Atomic deployment and replacement; no mixed-version winners |
| Authorization | Ordinary PostgreSQL ownership, grants, reader, author, deployer, operator, and worker boundaries |
| Security | Ownership, dependency, RLS, drift, grant, and unauthorized-result checks |
| Recovery | Inherited lifecycle, agenda, retention, restore, standby-promotion, and managed-worker paths |
| Consequences | Asynchronous and at-least-once; no synchronous or exactly-once guarantee |
| Upgrade | Populated direct `0.22.0 -> 0.23.0` path |
| Next milestone | M27 — Decision coverage and conflict analysis |

M26 does not provide a decision-table DSL, multi-winner or weighted selection,
arbitrary tie-breakers, defaults, coverage analysis, conflict analysis,
hypothetical facts, backtesting, replay, policy-set gating, visual authoring,
AI authoring, or domain packages. M27 owns coverage and conflict analysis.

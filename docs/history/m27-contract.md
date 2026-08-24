# M27 contract — decision coverage and conflict analysis

M27 is planned for extension `0.24.0`, with a direct upgrade from `0.23.0`.
It makes a proposed M26 decision version easier to review before deployment.
The analysis compares ordinary, materialized PostgreSQL relations at one
complete committed frontier. It does not parse SQL predicates or claim proof
about facts that were not declared for analysis.

## Public model

An analysis declaration is attached to one M26 decision program and records:

1. one finite, typed population relation and its semantic key;
2. one candidate catalog;
3. the current and proposed decision-version identities;
4. required-default and overlap requirements; and
5. winner-distribution limits, ownership, and grants.

The population says which subjects must be considered. The candidate catalog
names candidates that are expected to be relevant. PostgreSQL remains the
source of truth for keys, candidates, priorities, and results.

## Findings and evidence

Analysis reports exact findings for tied best candidates, forbidden overlap,
missing required defaults, unreachable catalog candidates, uncovered
population subjects, and winner-distribution changes beyond configured limits.
Each finding has a stable identity, severity, blocker status, remediation,
affected count, and canonically ordered bounded evidence. If evidence is
limited, the result says that it was truncated.

The report also includes exact current and proposed winner counts and deltas by
candidate identity. A successful report describes only its recorded complete
frontier and relation fingerprints. Later population, candidate, parameter,
or version changes can make the report stale.

## Deployment admission

Deployment admission evaluates blocking requirements against the same complete
snapshot and relation fingerprints as the analysis. A failed or stale analysis
is rejected before policy, lifecycle, provenance, or work state changes. A
successful admission does not create activations, execute consequences, or
mutate the authoritative policy or fact relations by itself.

Analysis is deterministic and bounded. Repeating it over the same frontier and
fingerprints produces the same public result regardless of row order, query
plan, transaction order, maintenance timing, restart, or standby promotion.

## Boundary and non-goals

M27 inherits the M26 decision, lifecycle, coordinator, security, recovery,
retention, provenance, diagnostics, and usability boundaries. It covers one
program, one current version, one proposed version, one declared population,
and one candidate catalog.

M27 does not add a predicate parser, theorem prover, SAT/SMT integration,
generated test data, hypothetical facts, per-key deployment simulation,
historical replay, comparative backtesting, cross-program analysis, policy-set
gating, a decision-table DSL, or a second evaluation engine. Policy-set gating
is planned for M28.

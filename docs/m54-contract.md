# M54 contract — adoption hardening

M54 is pg-react `0.43.1`, adjacent to `0.43.0`. It makes the existing
PostgreSQL-native product easier to adopt without adding rule, decision,
temporal, reasoning, workflow, or distributed-system semantics.

## Public additions

- `pgreact.review_token(jsonb)` converts a successful preview into bounded,
  opaque reviewed-plan evidence.
- `pgreact.deploy(declaration, review_token, preconditions)` deploys a reviewed
  rule, decision, or complete package while retaining normal safety checks.
- Stable-name recovery overloads delegate to the existing UUID-oriented
  implementations.
- Ordinary declarations carry `change_columns` and `conflict_key_columns`
  through validation, preview, deployment, replacement, and inspection.

## Invariants

Existing evaluators, lifecycle rules, work handling, authorization, and package
planning remain authoritative. Review tokens grant no permission and stale
reviewed plans fail. Existing JSON-precondition and specialized compatibility
APIs remain installed. The adjacent update performs no deployment, retry,
reconciliation, cancellation, or source-data mutation by itself.

## Boundary

The actively qualified adoption tuple is PostgreSQL 18.3, pg_trickle 0.81.0,
pgrx 0.18.0, Rust 1.89.0, Linux amd64, READ COMMITTED, and the
PostgreSQL-managed runtime. `1.0.0` remains postponed indefinitely.

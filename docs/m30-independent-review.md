# M30 independent-review record

## Review scope

This record makes the M30 foundation independently reviewable before M31:

- canonical match and subject identity normalization;
- codec-v2 type and order boundaries;
- relational eligibility keys and indexes;
- immutable scope mode and member disposition;
- migration classification for M28 metadata and M29 policy sets;
- public views, bounded evidence, and invalid-source findings;
- direct-upgrade preservation and no silent scope activation.

## Review result

The implementation is intentionally foundation-only. The exact executable
fixture in `tests/m30.sql` proves valid eligibility, composite identity
determinism, duplicate rejection, read-before-refresh preservation, relational
refresh, and empty scope-support state. The populated upgrade fixtures prove
identity preservation and `NEEDS_SCOPE_MIGRATION`.

Runtime adapters, coordinator lock ordering, lifecycle transitions, claimed
work revalidation, recovery, and external effects are explicitly deferred to
M31. This boundary prevents a schema milestone from implying behavior that it
does not yet implement.

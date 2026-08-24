# M11 pre-entry fixture

M11 product work starts only after the immutable `v0.7.0` release is
published. The release must tag the corrected qualification commit, rebuild
`tests/m10.sh`, and publish the archive, checksum manifest, release notes, and
`linux/amd64` OCI digest required by [the release workflow](../../.github/workflows/release.yml).

Until that happens, this document freezes the replacement-API task baseline;
it is not an M11 API contract.

## Frozen tasks and results

| Task | Existing executable baseline | Exact result that M11 must retain |
| --- | --- | --- |
| Constraint and command rules | `tests/m1.sh` | lifecycle transitions, diagnostics, and durable work |
| Pack validation, preview, deployment, promotion | `tests/m5.sh` | complete plan, digest, history, and atomic deployment state |
| Protocol 1 and audited protocol 2 workers | `tests/m6.sh` | claimed work, attempts, external-effect boundary, and recovery |
| Non-recursive derivation | `tests/m7.sh` | facts, supports, provenance, explanation, and repair |
| Positive recursion | `tests/m8.sh` | grounded fixed point, components, frontiers, and finite explanation |
| Stratified negation | `tests/m9.sh` | facts, negative evidence, strata, and deletion-sensitive lifecycle |
| Stratified aggregation | `tests/m10.sh` | facts, supports, graph, strata, aggregate evidence, explanations, lifecycle state, and work |
| Status, diagnostics, reconciliation, physical recovery, and upgrade | `tests/m10.sh` through its inherited suites | exact normalized durable state and user-visible diagnostics |

`tests/m10.sh pg-react:v0.7.0` is the single pre-entry command. Its nested
suites assert complete values, not row counts: `m10-slice1.sql` fixes the
aggregate reference transitions and evidence, and `m9-upgrade.sql` followed
by `m10-upgrade.sql` fixes the populated upgrade state. M11 replacement tests
must invoke only the replacement surface, then compare those same normalized
results. They must intentionally replace API presentation snapshots rather
than preserve them as aliases.

## Provisional inventory baseline

The exact provisional `0.7.0` inventory is the installed extension defined by
[`sql/pg_react--0.7.0.sql`](../../sql/pg_react--0.7.0.sql), with its upgrade chain,
and the current worker invocation in [`bin/pg-reactd`](../../bin/pg-reactd). Its public
SQL inventory is exercised by `tests/m4-api.sql`, `tests/m5-api.sql`, and
`tests/m6-api.sql`; pack manifest fields are exercised by `tests/m5-setup.sql`,
`tests/m7-pack.sql`, and `tests/m8-pack.sql`.

The M11 implementation contract must classify every item in that inventory as
`REMOVE`, `BRIDGE`, or `RETAIN`, name its replacement when applicable, and
state the compatibility start release. No provisional name is implicitly
retained. The new allow-list must separately cover schemas, types, views,
functions, grants, manifest fields, worker commands and configuration,
diagnostic envelopes, and documentation entry points.

## Release-gate record

The entry gate is satisfied by `v0.7.0` at
`8e1d29eaf4a09cfba2567b10cba5ab328c6a2d39`:

- successful qualification: [31567048695](https://github.com/trickle-labs/pg-react/actions/runs/31567048695);
- archive SHA-256: `890fc7e082cb18d381c58c93d9446d6ed446c8b1df520f7a652c506e04382589`;
- checksum asset SHA-256: `2d20b7646afeb005f52b75aa09897e1cd6a6e028f3879f2124a41a269d51efe8`.

This fixture remains the M11 semantic baseline; M11 product work is authorized.

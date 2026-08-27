# M37 contract: comparative backtesting

M37 targets extension `0.34.0`. It runs the deployed policy and one optional
candidate policy against the same starting rows and the same ordered history.
It is a read-only answer to: “Would these two policy versions have behaved
differently over this supplied history?”

## SQL surface

```text
pgreact.backtest(candidate, deployed, initial_snapshot, replay_steps, options)
pgreact.backtest_results(candidate, deployed, initial_snapshot, replay_steps, options)
```

The candidate may be `NULL`. That compares the deployed policy with itself and
is useful for checking that a history is reproducible. A non-null candidate
must have the same target kind and name. M36 then checks its declaration,
source, identity, schema, permissions, row images, timestamps, frontiers, and
limits.

## Shared history

The caller supplies one M36 snapshot and one finite ordered list of replay
steps. M37 validates that input once in effect by sending the exact same JSON,
security context, and limits to both M36 evaluations. It never looks for
missing history or substitutes current source rows.

Each side returns M36 initial, step, delta, and final envelopes. M37 aligns
their rows by result set, replay ordinal, subject key, and result key. A row is
`ADDED`, `REMOVED`, `CHANGED`, or `UNCHANGED`. Changed-row evidence contains
the relevant value, work, and source evidence from both sides.

## Limits and safety

`options` accepts the M36 limits `evidence_limit`, `max_steps`, `max_changes`,
`max_snapshot_rows`, and `max_total_changes`. `evidence_limit` bounds changed
row evidence as well as each side’s M36 evidence. A `partial` result never
claims exact difference counts.

The result includes both complete side results, shared input fingerprints,
per-side semantic cost counters, separately measured elapsed time, comparison
costs, and a comparison fingerprint. Successful and rejected calls do not write
source tables, pg-react state, lifecycle, work, attempts, history, frontiers,
or external effects.

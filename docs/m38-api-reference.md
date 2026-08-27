# M38 API reference

## Explain a changed backtest row

Pass `why_changed: true` with the existing limits:

```sql
SELECT pgreact.backtest(
    :candidate,
    :deployed,
    :initial_snapshot,
    :replay_steps,
    jsonb_build_object('evidence_limit', 100, 'why_changed', true)
);
```

Read `differences.rows`. Rows with `change` equal to `ADDED`, `REMOVED`, or
`CHANGED` contain `why_changed`. An `UNCHANGED` row does not contain that key.

The same option works with:

```text
pgreact.compare(proposed, deployed, options)
pgreact.compare(proposed, deployed, change_set, options)
pgreact.replay(proposed, deployed, initial_snapshot, replay_steps, options)
pgreact.backtest(proposed, deployed, initial_snapshot, replay_steps, options)
```

Use `compare_results`, `replay_results`, or `backtest_results` when you want SQL
rows. The existing `evidence` value carries the explanation. No relational
column was added.

## Read the explanation

Use `why_changed.state` to decide how much to trust the answer:

- `complete` accounts for the supported causes within the limit.
- `partial` reports the bound and the causes it returned.
- `unavailable` says that the originating result did not retain enough evidence.
- `unsupported` is reserved for evidence that M38 does not model.

Use `causes[*].path` to locate the differing public value. Use
`causes[*].public_evidence` to see the evidence from both sides. Use
`explanation_digest` to compare semantic explanations across runs.

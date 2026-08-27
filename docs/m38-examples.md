# M38 examples

## Explain a changed policy result

```sql
SELECT result -> 'differences' -> 'rows'
FROM (
    SELECT pgreact.backtest(
        :candidate,
        :deployed,
        :initial_snapshot,
        :replay_steps,
        jsonb_build_object('evidence_limit', 100, 'why_changed', true)
    ) AS result
) comparison;
```

For a row whose `change` is `CHANGED`, read `why_changed.causes`. The first
cause is ordered by its public path. Use `why_changed.state` before treating the
cause list as complete.

## Keep the old output

```sql
SELECT pgreact.backtest(
    :candidate, :deployed, :initial_snapshot, :replay_steps,
    jsonb_build_object('evidence_limit', 100)
);
```

This call does not add `why_changed` to its rows. Set the option to `false` when
you need to build the options object in shared application code.

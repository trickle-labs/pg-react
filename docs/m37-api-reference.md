# M37 API reference

## Compare two policy versions

```sql
SELECT pgreact.backtest(
    pgreact.decision(
        'orders-policy', 'app.order_candidates'::regclass,
        'order_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['candidate_id']::name[], '2026-08-27 09:00:00+00'),
    pgreact_api.target('decision_program', 'orders-policy'),
    :initial_snapshot,
    :replay_steps,
    jsonb_build_object('evidence_limit', 100));
```

The JSON result has `baseline`, `candidate`, and `differences` sections.
`baseline` and `candidate` are the M36 results for the deployed declaration
and the candidate declaration. `differences.rows` identifies the replay point
and the public result identity, then shows both sides’ value, work, and
evidence. `differences.counts` contains `added`, `removed`, `changed`, and
`unchanged` counts.

`state = 'ready'` means all returned bounds are exact. `state = 'partial'`
means a documented limit bounded the evidence.

## Relational results

```sql
SELECT side, result_set, step_ordinal, subject_key, result_key,
       state, change, baseline_value, candidate_value,
       baseline_work, candidate_work
FROM pgreact.backtest_results(
    :candidate, :deployed, :initial_snapshot, :replay_steps, '{}')
ORDER BY CASE side WHEN 'baseline' THEN 1 WHEN 'candidate' THEN 2 ELSE 3 END,
         step_ordinal, result_set, subject_key, result_key;
```

Rows with `side = 'baseline'` or `side = 'candidate'` expose each side’s
initial, step, delta, and final evidence. Rows with `side = 'difference'`
expose the bounded canonical comparison. `complete` and the fingerprint
columns make the result suitable for an audit record without private catalog
identifiers.

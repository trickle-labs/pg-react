# M39 examples

M39 does not require a new call shape. Keep using the M34–M38 functions and
compare their public semantic output:

```sql
SELECT pgreact.compare(
    :declaration,
    :target,
    jsonb_build_object('evidence_limit', 100, 'why_changed', true)
);

SELECT pgreact.replay(
    :declaration, :target, :snapshot, :steps,
    jsonb_build_object('evidence_limit', 100, 'why_changed', true)
);

SELECT pgreact.backtest(
    :candidate, :target, :snapshot, :steps,
    jsonb_build_object('evidence_limit', 100, 'why_changed', true)
);
```

For qualification, remove `elapsed_ms` before comparing digests. Compare public
keys and payloads in canonical order; do not compare private UUIDs or physical
row order. A simulation remains read-only even when it predicts lifecycle or
would-be work.

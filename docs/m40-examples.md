# M40 examples

An operator can check one expected result without reading private tables:

```sql
SELECT pgreact.explain(
    'manual-review-required',
    '1001'::jsonb,
    '{"why_not":{"result_kind":"rule_match","result_key":"1001"}}'
);
```

If the source view has no row for `1001`, the answer says `complete` and points
to `source.order_id`. If the source row exists but the installed match is not
active, the answer says `unavailable` and asks for a refresh. The second result
is deliberately less certain.

For a decision, ask about one candidate:

```sql
SELECT pgreact.explain(
    'order-routing', '1001'::jsonb,
    '{"why_not":{"result_kind":"decision_result","result_key":"9001"}}'
);
```

The result distinguishes a missing candidate from a candidate that lost to a
lower-priority winner. Both answers contain public source names and keys only.

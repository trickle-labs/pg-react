# M34 API reference

> [!NOTE]
> Versioned `0.31.0` reference retained for history. The canonical v1 lookup
> path is [`v1-api-reference.md`](v1-api-reference.md).

## Compare before deploying

```sql
SELECT pgreact.compare(
    pgreact.rule(
        'orders-rule',
        'app.orders_proposed'::regclass,
        'order_id'::name
    ),
    pgreact_api.target('rule', 'orders-rule'),
    jsonb_build_object('evidence_limit', 100)
);
```

The result says what is currently true, what the proposal would make true,
and the difference:

| Result | Meaning |
| --- | --- |
| `current` | Active behavior in the deployed target |
| `proposed` | Bounded behavior read from the proposed source |
| `delta` | `ADDED`, `REMOVED`, `CHANGED`, or `UNCHANGED` by typed subject key |

Use `compare_results()` when SQL needs rows rather than one JSON document:

```sql
SELECT result_set, subject_key, delta, current_value, proposed_value
FROM pgreact.compare_results(
    pgreact.rule('orders-rule', 'app.orders_proposed'::regclass, 'order_id'::name),
    pgreact_api.target('rule', 'orders-rule')
)
ORDER BY result_set, subject_key;
```

`partial` means the evidence limit was reached. A partial result never claims
that its delta counts are complete.

The envelope also includes `lifecycle` rows for affected transitions and
`work` rows for work that would be requested. Both are read-only projections
of the same bounded comparison; they do not create work.

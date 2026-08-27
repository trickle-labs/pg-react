# M35 API reference

## Compare hypothetical row changes

```sql
SELECT pgreact.compare(
    pgreact.rule(
        'orders-rule',
        'app.orders'::regclass,
        'order_id'::name
    ),
    pgreact_api.target('rule', 'orders-rule'),
    jsonb_build_array(jsonb_build_object(
        'relation', 'app.orders',
        'operation', 'UPDATE',
        'ordinal', 1,
        'key', jsonb_build_object('order_id', 10),
        'before', jsonb_build_object('order_id', 10, 'status', 'review'),
        'after', jsonb_build_object('order_id', 10, 'status', 'approved')
    )),
    jsonb_build_object('evidence_limit', 100)
);
```

The result compares the deployed behavior with the behavior after the supplied
row change. It does not execute the update. `INSERT`, `UPDATE`, and `DELETE`
use the same six-field change shape. See the [contract](m35-contract.md) for
the required images.

Use `compare_results()` when SQL needs rows:

```sql
SELECT result_set, subject_key, delta, current_value, proposed_value,
       change_set_digest, source_checksum_before, source_checksum_after
FROM pgreact.compare_results(
    pgreact.rule('orders-rule', 'app.orders'::regclass, 'order_id'::name),
    pgreact_api.target('rule', 'orders-rule'),
    '[]'::jsonb,
    '{}'::jsonb
)
ORDER BY result_set, subject_key;
```

`ready` means the bounded result is complete. `partial` means the evidence
limit was reached. An error means validation stopped before evaluation.

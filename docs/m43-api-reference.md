# M43 API reference

## Compare policy fields

```sql
SELECT pgreact_api.semantic_diff(
    pgreact_api.declaration(
        'rule',
        'high-value-review',
        jsonb_build_object(
            'condition', 'app.proposed_orders',
            'semantic_key', 'order_id',
            'kind', 'CONSTRAINT',
            'salience', 20)),
    pgreact_api.target('rule', 'high-value-review', '1'));
```

Use `state = 'complete'` when every modeled field was inspected. A complete
result may still contain `opaque` records: pg-react proved that a public SQL
object changed but cannot describe its business meaning. `partial` means a
declared bound stopped the comparison. `invalid` and `unsupported` are safe
review failures; `unavailable` intentionally reveals no target details.

The operation uses declaration normalization first. Omitted rule defaults,
accepted relation spelling, JSON object key order, and policy-set member order
therefore do not create false differences. List order remains meaningful.

The internal field inventory is useful for tooling and review documentation:

```sql
SELECT pgreact_internal.m43_field_inventory('decision_program');
```

The function is not an application API and remains inaccessible to `PUBLIC`.

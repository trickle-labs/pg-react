# M35 executable example

The example below asks what happens if order `10` changes status. The source
table is not updated.

```sql
SELECT pgreact.compare(
    pgreact.rule('orders-rule', 'app.orders'::regclass, 'order_id'::name),
    pgreact_api.target('rule', 'orders-rule'),
    '[{"relation":"app.orders","operation":"UPDATE","ordinal":1,"key":{"order_id":10},"before":{"order_id":10,"status":"review"},"after":{"order_id":10,"status":"approved"}}]'::jsonb,
    '{"evidence_limit":100}'::jsonb
) -> 'delta';
```

The response lists the changed subject and includes identical source and
authoritative checksums before and after the comparison. Run `tests/m35.sql`
for insert, update, delete, stale-image, duplicate-ordinal, limit, and no-effect
checks.

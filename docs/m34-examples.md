# M34 executable example

```sql
SELECT comparison -> 'summary'
FROM (
    SELECT pgreact.compare(
        pgreact.rule(
            'orders-rule',
            'app.orders_proposed'::regclass,
            'order_id'::name
        ),
        pgreact_api.target('rule', 'orders-rule'),
        jsonb_build_object('evidence_limit', 100)
    ) AS comparison
) example;
```

Run `tests/m34.sql` for the complete fixture. It checks that the proposal is
read without deployment and that the authoritative checksum is unchanged.

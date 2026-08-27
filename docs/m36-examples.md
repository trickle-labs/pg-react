# M36 executable example

This example asks what the rule would have reported as an order changed over
time. The caller supplies both the starting rows and the later change; the
source table is never updated.

```sql
SELECT pgreact.replay(
    pgreact.rule('orders-rule', 'app.orders'::regclass, 'order_id'::name),
    pgreact_api.target('rule', 'orders-rule'),
    '{"relations":[{"relation":"app.orders","schema_fingerprint":"<catalog fingerprint>","rows":[
      {"order_id":10,"status":"review","amount":100}
    ]}],
      "source_frontier":"2026-08-27 09:00:00+00",
      "sampled_time":"2026-08-27 09:00:00+00",
      "event_time_watermark":"2026-08-27 09:00:00+00"}'::jsonb,
    '[{"ordinal":1,
      "source_frontier":"2026-08-27 09:00:01+00",
      "sampled_time":"2026-08-27 09:00:01+00",
      "event_time_watermark":"2026-08-27 09:00:01+00",
      "change_set":[{"relation":"app.orders","operation":"UPDATE","ordinal":1,
        "key":{"order_id":10},
        "before":{"order_id":10,"status":"review","amount":100},
        "after":{"order_id":10,"status":"approved","amount":100}}]}]'::jsonb,
    '{}'::jsonb
) -> 'steps' -> 0 -> 'delta';
```

The same input always produces the same semantic result and replay digest.
Run `tests/m36.sql` for inserts, updates, time-only steps, stale images,
nonmonotone steps, exact row output, checksums, and the relational result.

# M37 examples

The shortest useful example is a comparison of a deployed policy with a
candidate declaration over a caller-owned snapshot and replay sequence:

```sql
SELECT pgreact.backtest(
    :candidate,
    pgreact_api.target('rule', 'orders-rule'),
    '{
       "relations": [{
         "relation": "app.orders",
         "schema_fingerprint": "<fingerprint>",
         "rows": [{"order_id": 10, "status": "review", "amount": 100}]
       }],
       "source_frontier": "2026-08-27 09:00:00+00",
       "sampled_time": "2026-08-27 09:00:00+00",
       "event_time_watermark": "2026-08-27 09:00:00+00"
     }'::jsonb,
    '[{
       "ordinal": 1,
       "source_frontier": "2026-08-27 09:00:01+00",
       "sampled_time": "2026-08-27 09:00:01+00",
       "event_time_watermark": "2026-08-27 09:00:01+00",
       "change_set": []
     }]'::jsonb,
    '{"evidence_limit": 100}'::jsonb);
```

If the candidate is `NULL`, the two sides should have the same declaration,
replay, and difference fingerprints except for separately measured elapsed
time. That is a compact reproducibility check.

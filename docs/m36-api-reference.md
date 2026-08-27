# M36 API reference

## Replay a supplied history

```sql
SELECT pgreact.replay(
    pgreact.rule('orders-rule', 'app.orders'::regclass, 'order_id'::name),
    pgreact_api.target('rule', 'orders-rule'),
    '{
       "relations": [{"relation": "app.orders", "schema_fingerprint": "<catalog fingerprint>", "rows": [
         {"order_id": 10, "status": "review", "amount": 100}
       ]}],
       "source_frontier": "2026-08-27 09:00:00+00",
       "sampled_time": "2026-08-27 09:00:00+00",
       "event_time_watermark": "2026-08-27 09:00:00+00"
     }'::jsonb,
    '[{
       "ordinal": 1,
       "source_frontier": "2026-08-27 09:00:01+00",
       "sampled_time": "2026-08-27 09:00:01+00",
       "event_time_watermark": "2026-08-27 09:00:01+00",
       "change_set": [{
         "relation": "app.orders", "operation": "UPDATE", "ordinal": 1,
         "key": {"order_id": 10},
         "before": {"order_id": 10, "status": "review", "amount": 100},
         "after": {"order_id": 10, "status": "approved", "amount": 100}
       }]
     }]'::jsonb,
    '{"evidence_limit": 100}'::jsonb
);
```

The result has `initial`, `steps`, and `final` envelopes. Each envelope has
the bounded evaluated rows. Step envelopes also have `delta`, `lifecycle`, and
`work`. `state = 'ready'` means every returned bound is complete. `state =
'partial'` means an evidence limit was reached.

Use `replay_results()` when SQL needs one row per initial, step, delta, or final
result:

```sql
SELECT result_set, step_ordinal, subject_key, delta, proposed_value,
       event_time_watermark, replay_digest
FROM pgreact.replay_results(:declaration, :target, :snapshot, :steps, '{}')
ORDER BY step_ordinal, result_set, subject_key;
```

M36 is read-only. It does not find missing history, execute source DML, deploy
a rule, create work, call a consequence, or send a message.

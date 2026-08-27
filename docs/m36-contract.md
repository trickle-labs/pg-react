# M36 contract: historical replay

M36 targets extension `0.33.0`. It replays a caller-supplied typed history
without reading old source rows and without changing the database.

## SQL surface

```text
pgreact.replay(proposed, deployed, initial_snapshot, replay_steps, options)
pgreact.replay_results(proposed, deployed, initial_snapshot, replay_steps, options)
```

`options` defaults to `{}`. `proposed` may be `NULL`; in that case the deployed
declaration is replayed. A non-null proposal must have the same kind and name
as the deployed target. The target must be a deployed `rule`,
`decision_program`, or `policy_set` that the caller may inspect.

## Initial snapshot

The snapshot is one JSON object. M36 currently supports one direct table with
one non-null `bigint` identity, the same boundary as M35:

```json
{
  "relations": [{
    "relation": "app.orders",
    "rows": [{"order_id": 10, "status": "review", "amount": 100}],
    "schema_fingerprint": "catalog-fingerprint"
  }],
  "source_frontier": "2026-08-27 09:00:00+00",
  "sampled_time": "2026-08-27 09:00:00+00",
  "event_time_watermark": "2026-08-27 09:00:00+00"
}
```

`schema_fingerprint` is required and must match the resolved table schema.
`rows` must contain every visible column with its PostgreSQL type. An empty
table is represented by `"rows": []`; omitting the relation is not equivalent.
M36 checks the table kind, `SELECT` permission, RLS status, identity type,
schema fingerprint, row shape, null identities, and duplicate identities.

## Replay steps

Steps are supplied in increasing ordinal order:

```json
{
  "ordinal": 1,
  "source_frontier": "2026-08-27 09:00:01+00",
  "sampled_time": "2026-08-27 09:00:01+00",
  "event_time_watermark": "2026-08-27 09:00:01+00",
  "change_set": [{
    "relation": "app.orders",
    "operation": "UPDATE",
    "ordinal": 1,
    "key": {"order_id": 10},
    "before": {"order_id": 10, "status": "review", "amount": 100},
    "after": {"order_id": 10, "status": "approved", "amount": 100}
  }],
  "final": false
}
```

`INSERT`, `UPDATE`, and `DELETE` use the M35 row-image contract. An empty
`change_set` is a time-only step. Ordinals, frontiers, sampled times, and event
watermarks cannot move backward. A final step ends the replay; later steps are
rejected. Every step produces bounded rows, deltas, lifecycle transitions, and
would-be work.

## Limits and safety

`options` accepts `evidence_limit` (1–1000), `max_steps` (1–1000),
`max_changes` (1–1000), `max_snapshot_rows` (1–100000), and
`max_total_changes` (1–100000). A partial result says it is partial and does
not claim exact affected-subject counts.

The result includes declaration, snapshot, and replay digests, time and source
frontiers, schema and authoritative checksums, causal evidence, and costs.
Successful and rejected replays leave source data, pg-react state, frontiers,
work, attempts, and effects unchanged.

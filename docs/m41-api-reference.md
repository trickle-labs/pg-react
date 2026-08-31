# M41 API reference

## Function

```text
pgreact.explain(name text, subject jsonb, options jsonb) returns jsonb
```

The M41 option is:

```json
{
  "causal_path": {
    "root_kind": "decision_result | rule_work | decision_work",
    "result_key": "1000",
    "work_id": "42",
    "generation": 1,
    "revision": 0,
    "event_kind": "ACTIVATE | DEACTIVATE",
    "consequence_identity": "schema.function",
    "node_limit": 256,
    "edge_limit": 512,
    "path_limit": 64,
    "depth_limit": 16,
    "fanout_limit": 64,
    "payload_limit": 65536
  }
}
```

Only fields needed by the selected root are used. Unknown fields and invalid
limits return `unsupported` with `M41_OPTIONS_INVALID`.

## Output fields

`root`, `nodes`, and `edges` identify only public modeled objects. `paths` lists
canonical root-to-boundary or root-to-fact walks. `boundaries` records missing,
inaccessible, unsupported, cyclic, schema-drift, inactive-time, and over-limit
endpoints. `findings` explains why a path is incomplete. `digests.semantic`
covers the ordered semantic answer; `cost` separates semantic counters from
`elapsed_ms`.

The function remains safe for ordinary readers because every inaccessible
predecessor is represented by one opaque boundary and no private identifier is
returned.

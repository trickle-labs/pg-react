# M41 contract: end-to-end causal paths

M41 lets an operator follow one current decision result or work item back to
the facts that pg-react can prove. The question is read-only and opt-in.

## Request

Use the existing explanation function and add one `causal_path` object:

```sql
SELECT pgreact.explain(
    'order-routing',
    '10'::jsonb,
    '{"causal_path":{"root_kind":"decision_result","result_key":"1000"}}'
);
```

The accepted root forms are:

| Root | Required public identity |
| --- | --- |
| `decision_result` | `result_key` |
| `rule_work` | `work_id`, `generation`, `event_kind`; `revision` and `consequence_identity` may further disambiguate it |
| `decision_work` | `work_id`, `generation`, `revision` |

`work_id` is never used by itself. Keys are business keys or public work
identities; private UUIDs, transaction IDs, and catalog IDs are not roots.
The supported limits are `node_limit` 256, `edge_limit` 512, `path_limit` 64,
`depth_limit` 16, `fanout_limit` 64, and `payload_limit` 65536.

Omit `causal_path`, or set it to `false`, to retain the exact `0.37.0`
explanation. M40 `why_not` remains unchanged when M41 is not requested.

## Result

The result uses contract version `27` and contains `state`, `root`, `nodes`,
`edges`, `paths`, `boundaries`, `findings`, `limits`, `cost`, and `digests`.
States are:

- `complete`: every supported predecessor in the bounded model reaches an
  accessible authoritative fact.
- `partial`: a cycle, stale frontier, missing retained fact, or resource limit
  stops one or more paths.
- `unavailable`: authorization, RLS, schema drift, or changed revisions prevent
  a safe answer.
- `unsupported`: the request or dependency is outside this adapter.

Nodes and edges have stable public identities and canonical ordering. A
boundary is explicit and does not reveal hidden node names, values, counts, or
path shape. Semantic digests and cost counters are deterministic; elapsed time
is reported separately. The function reads one PostgreSQL statement snapshot
and never writes source, runtime, lifecycle, work, history, or evidence state.

## Supported links

M41 follows work to lifecycle, lifecycle to a rule match, decision results to
selection and candidates, policy applicability and active time, derived facts
to modeled support, and modeled support to authoritative source rows. It does
not infer lineage from arbitrary SQL or query plans.

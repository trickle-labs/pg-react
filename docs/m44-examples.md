# M44 explanation examples

These examples use the existing operations. M44 does not change their SQL.

## Check an absent result

```sql
SELECT pgreact.explain(
    'order-review',
    '42'::jsonb,
    '{"why_not":{"result_kind":"rule_match","result_key":"42"}}'
);
```

Use `state = 'complete'` when pg-react checked the supported causes. Use
`partial` when the result names a reached limit. Use `unavailable` when the
operation could not read safe evidence. Use `unsupported` when the question is
outside the operation's model.

## Follow a decision result

```sql
SELECT pgreact.explain(
    'order-routing',
    '10'::jsonb,
    '{"causal_path":{"root_kind":"decision_result","result_key":"1000"}}'
);
```

The root, nodes, edges, paths, boundaries, findings, limits, costs, and
digests retain the M41 meanings. Public business keys identify the question.

## Read a retained answer

```sql
SELECT pgreact_api.read_evidence_snapshot(
    pgreact_api.target('decision_program', 'order-routing', '1'),
    'causal_path:decision_result:order-routing:1:1000',
    'audit-2026-09'
);
```

The outer result tells you whether the snapshot is available. The nested
`snapshot` member is the exact M41 answer captured at the earlier evidence
point. Do not treat it as current state.

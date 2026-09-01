# M44 API reference

M44 documents existing calls. No M44-specific call exists.

## Explain a current target

```sql
SELECT pgreact.explain('order-routing', '10'::jsonb);
```

The ordinary result keeps the installed current-state contract. Add
`why_not` for one expected result or `causal_path` for one supported root.
Omit both options to preserve the ordinary result.

```sql
SELECT pgreact.explain(
    'order-routing',
    '10'::jsonb,
    '{"why_not":{"result_kind":"decision_result","result_key":"1000"}}'
);

SELECT pgreact.explain(
    'order-routing',
    '10'::jsonb,
    '{"causal_path":{"root_kind":"decision_result","result_key":"1000"}}'
);
```

The why-not contract uses result version `26`. The causal-path contract uses
result version `27`. Their states and findings remain origin-specific.

## Explain a current comparison

```sql
SELECT pgreact.compare(
    :proposed_declaration,
    pgreact_api.target('rule', 'order-review', '1'),
    '{"why_changed":true}'::jsonb
);
```

The current `pgreact.compare` call returns its installed comparison result and
adds the existing M38 why-changed evidence to changed rows. The why-changed
result version is `25`. Replay and backtest accept the same option, but M44
does not qualify their historical answers.

## Read retained evidence

```sql
SELECT pgreact_api.read_evidence_snapshot(
    pgreact_api.target('decision_program', 'order-routing', '1'),
    :root_identity,
    'audit-2026-09'
);
```

The M42 result uses version `28`. Its `snapshot` member is the exact captured
M41 result, including version `27`. The outer state reports snapshot
availability. The nested state reports explanation completeness.

## Interpret an answer

Read the origin's `state`, `findings`, `limits`, evidence or graph members,
semantic digest, and semantic cost together. Treat elapsed time as a separate
measurement. Do not compare answers across origins unless their public
question and evidence identities are equal.

The previous operation-specific references remain authoritative:
[M40 why-not](m40-api-reference.md), [M41 causal paths](m41-api-reference.md),
[M42 snapshots](m42-api-reference.md), and [M38 why-changed comparison](m38-api-reference.md).

# Explain an outcome

Use this guide when a result is present, missing, changed, or retained for
later review. Start with the question. Each operation keeps its own result
shape, but the interpretation rules are the same.

| Question | Operation |
|---|---|
| What is true for this subject now? | `pgreact.explain(name, subject)` |
| Why is one expected result absent? | `pgreact.explain` with `why_not` |
| Which facts led to a decision or work item? | `pgreact.explain` with `causal_path` |
| Why did a current comparison result change? | `pgreact.compare` with `why_changed` |
| Which modeled declaration fields changed? | `pgreact_api.semantic_diff` |
| What causal answer was retained earlier? | `pgreact_api.read_evidence_snapshot` |

## Start with current state

```sql
SELECT pgreact.explain('order-routing', '10'::jsonb);
```

Use the stable target name and the business subject key. Do not use a private
UUID or catalog row identity.

If an expected result is absent, ask one finite why-not question:

```sql
SELECT pgreact.explain(
    'order-routing',
    '10'::jsonb,
    '{"why_not":{"result_kind":"decision_result","result_key":"1000"}}'
);
```

If a decision or work item exists, follow its bounded causal path:

```sql
SELECT pgreact.explain(
    'order-routing',
    '10'::jsonb,
    '{"causal_path":{"root_kind":"decision_result","result_key":"1000"}}'
);
```

## Read the answer

Read these parts together:

- Public identity tells you which target, subject, result, root, or comparison
  the answer describes.
- The evidence point tells you which declaration, source definition, time,
  frontier, revision, or comparison side the operation used.
- `complete` means that the operation checked every cause it supports within
  its limits. It does not claim to explain arbitrary SQL.
- `partial` names the limit or missing evidence that stopped the operation.
- `unavailable` means that pg-react could not return a safe answer.
- `unsupported` means that the question is outside the operation's model.
- Findings and boundaries explain incomplete or rejected traversal.
- The semantic digest covers stable meaning. Elapsed time does not.

Do not read a limit as proof that no omitted cause exists. Fix the named
boundary or narrow the question, then run the operation again.

## Separate policy change from outcome cause

Use `pgreact_api.semantic_diff` to inspect modeled declaration fields. Use
`pgreact.compare` with `why_changed` to explain supported current result
differences. A changed policy field is review evidence, not proof that the
field caused a specific outcome.

```sql
SELECT pgreact_api.semantic_diff(
    :proposed_declaration,
    pgreact_api.target('rule', 'order-review', '1')
);

SELECT pgreact.compare(
    :proposed_declaration,
    pgreact_api.target('rule', 'order-review', '1'),
    '{"why_changed":true}'::jsonb
);
```

## Compare two answers safely

Compare answers only when all identity inputs that both operations expose are
equal:

1. Match the target kind, stable name, and immutable version.
2. Match the typed subject or result and the root or comparison point.
3. Match the declaration and source-definition digests.
4. Match sampled time, frontier, lifecycle or decision revision, and
   comparison sides where present.
5. Use the same authorization context.

If any required value is absent or differs, treat the answers as different
observations. Do not fill one answer from another.

A retained M42 snapshot is historical. Its outer state says whether the
snapshot is available. The nested M41 state says whether the captured causal
answer was complete. Never present the snapshot as current truth.

For exact request fields and limits, use the [explanation API
reference](m44-api-reference.md). For policy-field comparison, use the
[semantic-difference API reference](m43-api-reference.md).

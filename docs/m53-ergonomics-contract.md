# M53 ergonomics contract

This is the first M53 implementation slice for extension `0.42.0`. It adds
names-first task calls over the installed M40–M44 evaluators. It does not add a
second evaluator, change an inherited result contract, or package the later
policy-set release work.

## Public functions

```sql
pgreact.why_not(text, jsonb, text, jsonb) returns jsonb
pgreact.trace(text, jsonb, jsonb) returns jsonb
pgreact.trace(text, text) returns jsonb
pgreact.trace(jsonb) returns jsonb
pgreact.compare(pgreact_api.declaration, boolean default false) returns jsonb
pgreact.semantic_diff(pgreact_api.declaration) returns jsonb
pgreact.explanation_summary(jsonb) returns jsonb
pgreact.explanation_capabilities(text default null) returns jsonb
pgreact.capture_evidence(jsonb, text) returns jsonb
pgreact.read_evidence(text) returns jsonb
pgreact.delete_evidence(text) returns jsonb
```

`pgreact.explain(text, jsonb, jsonb)` keeps its existing result for every valid
ordinary, `why_not`, and `causal_path` request. A request enabling both
questions returns `M53_EXPLAIN_QUESTION_CONFLICT` before an evaluator runs.

## References and summaries

An `explanation_ref` is versioned public JSON containing the target, typed
subject, and causal root. It contains no private UUID, catalog identifier,
transaction identifier, source value, or elapsed time. References over 65,536
bytes are rejected. Snapshot identities are validated before lookup and may
not exceed 4,096 bytes.

`explanation_summary` is immutable and read-only. It preserves the detailed
answer's origin state and findings, maps completeness to the shared vocabulary,
and emits structured `next_actions`. It never copies graph nodes, edges,
paths, causes, comparison rows, declaration fields, or retained payloads.

## Security and compatibility

New delegated calls use `SECURITY DEFINER` with `search_path = pg_catalog,
pg_temp`. Target and snapshot authorization remains the installed owner,
operator, reader, and RLS behavior. Missing and unauthorized target data stays
fail-closed. Snapshot capture and delete retain their documented writes;
summary and capability functions do not write state.

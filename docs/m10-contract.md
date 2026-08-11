# M10 contract — stratified aggregation

M10 is extension `0.7.0`. It adds one keyed `COUNT(*)` threshold dependency
to the existing M8/M9 derivation-program model without admitting recursive
aggregation or changing the inherited platform boundary.

## Program declaration

An aggregate rule adds exactly one `aggregate_input` to the existing program
rule object:

```json
{
  "name": "risk.group_to_alert",
  "definition": "risk.group_source",
  "key": "id",
  "target": "risk.alert",
  "version": 1,
  "inputs": [],
  "aggregate_input": {
    "relation": "risk.item_source",
    "key": "id",
    "comparison": ">=",
    "threshold": 2
  }
}
```

`definition` supplies one positively bound, non-null group key. It is the
derived fact's semantic key and must be projected unchanged. `aggregate_input`
names raw rows from one authoritative relation or one active lower-stratum
derived relation; its `key` must be the same `bigint` key. pg-react evaluates
`COUNT(*) WHERE key = group_key` after the lower stratum has converged.

The only comparisons are `=`, `<`, `<=`, `>`, and `>=`; `threshold` is a JSON
integer accepted by PostgreSQL as a non-negative `bigint`. PostgreSQL's normal
`COUNT(*)` and comparison semantics are used.

The declaration is closed. Aggregates in rule SQL, `COUNT(expression)`,
`DISTINCT`, `FILTER`, grouping SQL, windows, more than one aggregate input,
unbound keys, unresolved relations, same-stratum aggregate edges, and every
cycle containing an aggregate or negative edge are rejected before deployment.

## Evaluation and evidence

Refresh locks source, negative-input, aggregate-input, and target relations,
checks their stored definition and row signatures, then evaluates components in
stratum order at one program frontier. A count update that does not flip the
comparison updates the aggregate evidence without creating or retracting the
higher support; a crossing creates or retracts it. Reconciliation rebuilds the
complete program atomically, so resource or evaluation failure leaves the prior
complete frontier visible.

`pgreact.derivation_dependency_graph` reports aggregate edges as
`polarity = 'AGGREGATE'`. `pgreact.aggregate_dependency_evidence` exposes the
stable evidence identity, group key, counted relation, exact count, comparison,
threshold, source/target strata, and lower frontier. It is evidence, not an
authoritative fact. `pgreact.explain_recursive_fact` includes the same finite
condition under each support's `aggregate_conditions`; it does not enumerate
counted rows.

Pack mapping, validation, preview digest, deployment, replacement, removal,
source-drift detection, recovery, and the `0.6.0 -> 0.7.0` extension upgrade
all include aggregate inputs. The inherited M0–M9 public API remains valid.

## Boundary

M10 does not add aggregate cycles, same-stratum or recursive aggregation,
other aggregates, temporal semantics, aggregate-row lineage, new execution
modes, or a broader PostgreSQL, `pg_trickle`, RLS, key-codec, recovery, or
platform matrix.

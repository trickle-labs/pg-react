# M16 contract — richer stratified aggregation

M16 is extension `0.13.0` and public contract version `5`. It extends the
existing keyed `COUNT(*)` aggregate dependency with one typed `COUNT`, `SUM`,
`MIN`, or `MAX` input column per rule.

## Program declaration

A typed aggregate uses the existing `aggregate_input` object with an immutable
named input column:

```json
{
  "relation": "risk.item_source",
  "key": "id",
  "function": "SUM",
  "expression": "amount",
  "comparison": ">=",
  "threshold": 100
}
```

`COUNT(*)` retains its inherited four-field declaration. Typed declarations
name one schema-qualified finite lower-stratum relation, one positively bound
group key, one named column, one function, comparison, and threshold. The
expression is a column name, not arbitrary SQL; project casts or calculations
into the input view first.

`COUNT` ignores null expressions. `SUM`, `MIN`, and `MAX` ignore null inputs
and produce PostgreSQL's typed null result for an empty non-null set. PostgreSQL
casts, comparison, collation, and overflow behavior are authoritative within
the frozen type matrix: built-in scalar `COUNT`; supported numeric `SUM`; and
numeric, `text COLLATE "C"`, date/time, and `uuid` `MIN`/`MAX`.

## Evaluation and evidence

Aggregate input is resolved and authorized at validation time without
search-path retargeting. Unsupported functions, expressions, types,
collations, comparisons, thresholds, unqualified relations, and unreadable
columns fail before durable state changes.

Evaluation remains dependency ordered and commits complete affected strata at
one frontier. A value update that does not cross the comparison updates exact
aggregate evidence without a false fact or lifecycle transition. A crossing
creates or retracts exactly the corresponding higher support.

`pgreact_api.reconcile_program(text)` gives configured operators a public-name
repair path for aggregate evidence, values, truth, supports, and frontiers.

Public aggregate evidence and unified explanation retain the group key,
function, named value expression, input/result types, exact current value,
comparison, threshold, lower frontier, and truth result. They remain finite
summary evidence, not input-row lineage.

## Boundary

M16 retains M15's public API, workers, typed keys, security, recovery, and
usability boundary. It does not add aggregate cycles, same-stratum or recursive
aggregation, multiple aggregate dependencies, `DISTINCT`, `FILTER`, `AVG`,
ordered-set or user-defined aggregates, arbitrary expressions, temporal
windows, or general tuple lineage.

The supported direct extension upgrade is `0.12.0 -> 0.13.0`.

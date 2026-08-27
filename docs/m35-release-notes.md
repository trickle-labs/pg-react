# M35 hypothetical fact simulation (`0.32.0`)

M35 lets you ask one practical question before you change data:

> If these rows were inserted, updated, or deleted, what would pg-react report?

The answer is read-only. pg-react does not change the source table, deploy a
rule, create work, call a consequence, or send a message.

## What changed

- `pgreact.compare()` accepts an ordered JSON change set in a new overload.
- Each change names its table, operation, ordinal, bigint identity, and full
  typed row images.
- Inserts, updates, and deletes are checked against the current source rows.
- Results show current behavior, simulated behavior, the delta, lifecycle rows,
  and work that would be requested.
- Results include declaration and change-set digests, source and pg-react
  checksums, snapshot times, changed row images, causal evidence, and cost.
- The same overload is available as `pgreact.compare_results()` for SQL rows.

## What stays safe

M35 rejects stale row images, duplicate ordinals, conflicts, unknown fields,
unsupported sources, unauthorized sources, and row-level security. A partial
answer says that it is partial. It does not present incomplete counts as exact.

M35 keeps the existing three-argument M34 comparison functions. It does not add
historical replay, a scenario store, a custom rule language, or a second
evaluator. The first release supports direct table sources with one non-null
`bigint` identity column.

## Upgrade

Upgrade from `0.31.0` after a verified backup:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.32.0';
```

The release gate is `tests/m35.sh complete`. Tag and push `v0.32.0` after the
full packaged lane passes. The next logical milestone is M36, historical
replay. The roadmap lists it as a planning option, not a committed release.

# M16 public tasks

## Declare and run a typed aggregate

Project the aggregate value as a stable named column, then use the existing
program declaration flow with one typed aggregate input:

```json
{
  "relation": "app.order_line",
  "key": "customer_id",
  "function": "SUM",
  "expression": "amount",
  "comparison": ">=",
  "threshold": 100
}
```

The relation must be schema-qualified. The key remains positively bound and is
the derived fact key. Use `COUNT(expression)` for non-null values; use `SUM`, `MIN`, or
`MAX` only with a supported source type. For text ordering, project the value
with deterministic `COLLATE "C"`.

Validate and deploy through the inherited public program API, then call `run`.
Use public status and explain output to inspect the aggregate function, exact
value, threshold, frontier, and truth result. Do not query private aggregate
catalogs.

An operator audits and repairs one active program by public name:

```sql
SELECT pgreact_api.reconcile_program('app.customer_totals');
```

The result is the exact number of recorded repairs. A clean result is `0`.

## Recover and upgrade

For replacement, recovery, and upgrade, stop claims and take a verified
physical backup first. Follow [`m16-upgrade.md`](m16-upgrade.md), then compare
public facts, supports, aggregate evidence, and explanation to the captured
exact outputs. Keep workers stopped and restore the verified backup if health
checks fail.

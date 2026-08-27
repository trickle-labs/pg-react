# M37 comparative backtesting (`0.34.0`)

M37 answers a practical question:

> “If I had used this other policy version, what would have changed?”

You provide the starting rows and the later changes. pg-react runs the
deployed policy and an optional candidate policy over that same history and
shows where their answers differ.

## What changed

- `pgreact.backtest()` compares two policy versions over one caller-supplied
  typed history.
- The result includes each side’s starting state, every replay step, final
  state, lifecycle/delta evidence, would-be work, measured costs, and stable
  fingerprints.
- Differences are labeled `ADDED`, `REMOVED`, `CHANGED`, or `UNCHANGED` and
  identify the replay point and public result row.
- `pgreact.backtest_results()` turns the same information into SQL rows.
- A `NULL` candidate compares the deployed policy with itself, which is useful
  for checking reproducibility.

## What stays safe

Backtesting is read-only. It does not update source tables, deploy a policy,
create work, execute consequences, send messages, or advance pg-react state.
The same M36 validation and authorization rules apply to both sides. If a
limit bounds the evidence, the result says `partial` instead of pretending the
omitted rows did not exist.

## Upgrade

Back up the database first, install the `0.34.0` files, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.34.0';
```

There is no in-place downgrade. Restore a verified `0.33.0` backup if you need
to roll back. The release gate is `tests/m37.sh complete`; tag and push
`v0.34.0` only after the complete packaged lane passes.

The logical next milestone is M38, why-changed comparison. It is a planning
option, not a commitment: choose it only after reviewing M37 evidence and user
traction.

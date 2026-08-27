# M36 historical replay (`0.33.0`)

M36 lets you ask:

> “Given these starting rows and these later changes, what would pg-react have
> reported at each point in time?”

You provide the history. pg-react does not search for old data or change your
database while it answers.

## What changed

- `pgreact.replay()` evaluates one deployed rule, decision program, or policy
  set against a complete starting snapshot and a finite ordered history.
- Each step can contain inserts, updates, deletes, or only a new time and event
  watermark.
- The result shows the starting state, every step, the changes between steps,
  and the final state.
- Results include plain evidence: which rows were supplied, which times and
  source frontiers were used, what the policy would have matched, and what work
  would have been requested.
- `pgreact.replay_results()` makes the same information available as SQL rows.
- Results include stable declaration, snapshot, and replay fingerprints, plus
  cost and no-change checksums so a replay can be repeated and checked.

## What stays safe

Replay is read-only. It does not update source tables, deploy rules, create
work, execute consequences, send messages, or advance pg-react state. Invalid
or incomplete inputs fail closed with stable M36 finding codes. A partial
answer says it is partial instead of pretending that omitted rows were
counted.

The M34 and M35 comparison APIs remain available and unchanged.

## Upgrade

Back up the database first, then install the `0.33.0` files and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.33.0';
```

There is no in-place downgrade. Restore the verified `0.32.0` backup if you
need to roll back.

The release gate is `tests/m36.sh complete`. Tag and push `v0.33.0` only after
that complete packaged lane passes. The next planned milestone is M37,
comparative backtesting: running two frozen policy versions over the same
caller-supplied history.

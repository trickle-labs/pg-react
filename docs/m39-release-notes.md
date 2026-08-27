# M39 — simulation qualification (`0.36.0`)

M39 makes the existing simulation tools easier to trust. It does not add a new
feature or a new SQL command. It checks that the comparison, hypothetical
change, replay, backtesting, and “why did this change?” tools describe the same
kind of evidence when they are given the same facts.

## What users get

- The existing `compare`, `replay`, and `backtest` calls keep their names,
  defaults, options, and return types.
- Results can be matched using public names and business keys. Private database
  IDs and physical row order are not needed.
- Complete and partial results say clearly what was covered and where a limit
  stopped the work. Missing evidence is not presented as proof of absence.
- JSON and relational results refer to the same public rows, identities, and
  digests.
- Simulation remains a dry run. It does not change source data, deploy a
  policy, create work, advance a frontier, or send an external message.

## What this release does not do

M39 does not add general “why not?” answers, retained evidence, end-to-end
causal paths, semantic policy diffs, a durable simulation job, a new rule
language, or another evaluator. Those are not part of this release.

## Upgrade

Back up the database first, install the `0.36.0` files, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.36.0';
```

There is no in-place downgrade. Restore a verified `0.35.0` backup if you need
to roll back. The exact upgrade and rollback procedure is in
[`m39-migration.md`](m39-migration.md).

## Release status and next step

The `v0.36.0` release was published after `tests/m39.sh complete` passed against
the packaged image and the inherited M0 through M38 gates passed.

No later milestone is selected. M40 bounded why-not remains a candidate. Select
the next milestone after field use of the M39 journey identifies the next
adoption blocker.

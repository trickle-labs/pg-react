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

This commit prepares `0.36.0`; it is a release only after
`tests/m39.sh complete` passes against the packaged image and the inherited
M0–M38 gates pass. Then tag and push `v0.36.0` to start the release workflow.

The logical next milestone is **M40 — bounded why-not**: explain a missing
result only for finite cases that pg-react already models. M40 is proposed, not
automatic; select it after reviewing M39 evidence and user traction.

# M38 why-changed comparison (`0.35.0`)

M38 answers a follow-up question:

> "The result changed. Which facts changed with it?"

## What changed

- Add `{"why_changed": true}` to `pgreact.compare`, `pgreact.replay`, or
  `pgreact.backtest`.
- Read a bounded `why_changed` object on each changed result row.
- See the two sides, the replay or comparison point, the differing public path,
  the cause kind, and the evidence used for that cause.
- Use the existing relational functions. Their return types stay the same.

The default remains off. Calls that omit the option keep the earlier output.

## What stays safe

Why-changed evidence is read-only. It does not write source tables, deploy a
policy, create work, execute consequences, retain evidence, or send messages.
M38 uses the same source, history, authorization, RLS, schema, and resource
limits as the originating operation.

If the evidence is incomplete, the result says `partial` or `unavailable`. It
does not claim that a missing cause did not exist. Arbitrary SQL remains opaque.

## Upgrade

Back up the database first, install the `0.35.0` files, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.35.0';
```

The release gate is `tests/m38.sh complete`. Tag the verified commit as
`v0.35.0` only after the packaged lane passes. The next proposed milestone is
M39, simulation qualification. M39 is not selected automatically.

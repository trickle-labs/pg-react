# M40, bounded why-not (`0.37.0`)

M40 gives operators a direct answer when one result they expected is missing.
Ask about one target, one subject, and one expected result. pg-react checks the
evidence it already has and tells you what it can prove.

## What changed

- Add an opt-in `why_not` question to `pgreact.explain`.
- Explain missing rule input, derived facts, policy applicability, inactive
  policy time, and decision candidates or selection when the installed adapter
  has that proof.
- Return clear states: `complete`, `partial`, `unavailable`, `unsupported`, or
  `already_present`.
- Show public names, business keys, modeled values, limits, and stable causes.
- Keep the old `pgreact.explain` result unchanged when `why_not` is absent or
  false.

## What did not change

M40 does not inspect arbitrary SQL, guess at a cause, recommend a data or policy
change, retain a question, add a background job, or write source and runtime
state. RLS and existing authorization rules still fail closed.

## Upgrade

Back up the database, install the `0.37.0` files, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.37.0';
```

There is no in-place downgrade. Restore a verified `0.36.0` backup if you need
to roll back. See [`m40-migration.md`](m40-migration.md) for the exact steps.

## Next step

The next logical candidate is M41, end-to-end causal paths. It would connect a
decision or work item through lifecycle and derived facts to authoritative
facts. It is a candidate, not a release commitment. First use M40 in real
financial-exception and access-drift work, then decide whether the missing
cross-step path is the next adoption problem.

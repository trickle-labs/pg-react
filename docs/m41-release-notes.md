# M41, end-to-end causal paths (`0.38.0`)

M41 helps an operator answer a practical question: “This decision or piece of
work exists—what facts led to it?” Start with one current decision result or
work item and pg-react follows the evidence it already records.

## What changed

- Added an optional `causal_path` question to the existing `pgreact.explain`
  function.
- Added paths for decision results, rule work, and decision work.
- Connected modeled decision selection, rule lifecycle, policy applicability,
  derived support, and authoritative source facts.
- Added clear `complete`, `partial`, `unavailable`, and `unsupported` states.
- Added stable public identities, findings, limits, digests, and cost counters.

## What did not change

Normal explanations still return the same result. M40 `why_not` still works the
same way. M41 does not inspect arbitrary SQL, guess at causes, save a copy of
the evidence, or change database or pg-react state.

## Upgrade

Back up the database, install the `0.38.0` files, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.38.0';
```

There is no in-place downgrade. Restore a verified `0.37.0` backup if you need
to go back. See [`m41-migration.md`](m41-migration.md).

## What to do next

Use M41 with a real financial-exception or access-drift workload. Check that
the returned path answers the operator’s question and record any missing links.
The logical next candidate is M42, opt-in evidence snapshots, but it should be
selected only if that field evidence shows that ordinary evidence expires too
soon.

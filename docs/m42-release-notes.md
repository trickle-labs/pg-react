# pg-react 0.39.0: save one past decision answer

M42 lets you keep one decision explanation for later. You choose this when an
audit may outlast the source data that normally supports the explanation.
These notes use plain English for operators and application owners.

## What changed

- Add `evidence_snapshot` to a canonical `decision_program` declaration.
- Capture one complete M41 `decision_result` path with a caller-chosen key.
- Read the saved answer after source rows or detailed history expire.
- Delete the saved answer after its declared retention period.
- Review snapshot rows, bytes, deletions, and tombstones through M21 retention
  tools.

The saved answer is the exact M41 answer from capture. pg-react labels it as
historical evidence. It does not claim that the decision is still current.

## What did not change

Snapshots are off unless a declaration opts in. pg-react does not copy every
evaluation, keep source history, inspect arbitrary SQL, or run another evaluator.
Existing M41 explanations remain read-only.

## Upgrade

Back up the database, install `0.39.0`, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.39.0';
```

The supported upgrade is `0.38.0 -> 0.39.0`. Restore a verified `0.38.0` backup
if you need to go back. See [`m42-migration.md`](m42-migration.md).

## What to do next

Use a real financial-exception or access-drift workload. Capture only the
decision results that need a longer audit record, and set a finite retention
period for each declaration. The next planned candidate is M43, semantic policy
differences. It is not a release commitment until M42 evidence and user demand
support it.

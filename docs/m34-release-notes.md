# M34 — deployment-impact simulation (`0.31.0`)

> [!NOTE]
> Historical `0.31.0` release record. Statements below that place M35 before
> the first RC are superseded: M34 is the v1 feature boundary and M35 is
> post-v1. Current users should start at [`index.md`](index.md).

**In plain English:** before changing a rule, decision, or policy set, you can
ask pg-react what would change. It shows what is true now, what the proposal
would change, and the difference. It does not change your database.

## What users get

- `pgreact.compare(...)` returns current, proposed, and changed results.
- `pgreact.compare_results(...)` returns those results as normal SQL rows.
- Results identify added, removed, changed, and unchanged subjects.
- The response tells you which current snapshot was read, how much evidence is
  complete, and what work would be requested without actually doing it.
- A before/after checksum proves that the authoritative state did not change.

## Important limits

M34 compares one proposal with one current snapshot. It does not replay the
past, invent hypothetical facts, deploy anything, call an action, or send an
external message. Evidence is bounded by `evidence_limit`; a partial answer
is labeled partial instead of pretending to be complete. Unsupported
declaration kinds and protected sources fail closed.

## Upgrade

Upgrade from `0.30.0` with `ALTER EXTENSION pg_react UPDATE TO '0.31.0'`.
The next planned milestone is **M35 (`0.32.0`)**, which adds explicitly typed
hypothetical inserts, updates, and deletes while keeping this same evaluator,
authorization, limits, evidence, and no-effect boundary. After M35, the
logical release step is **`1.0.0-rc.1`**, not GA.

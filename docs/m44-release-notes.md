# pg-react 0.41.0: read explanations with the same expectations

M44 qualifies the explanation results that pg-react already provides. It does
not add a new command.

## What this release gives you

- One contract that explains what each supported answer means.
- Clear rules for public identity, evidence time, completeness, limits, and
  authorization.
- A clear distinction between a complete answer, a partial answer, an answer
  that is unavailable, and a question that pg-react does not support.
- The same rules for current outcomes, why-not answers, causal paths, current
  comparison changes, and retained causal-path answers.
- A reference corpus and executable checks for financial exception, access drift,
  and retained decision reviews.

## What does not change

Your existing SQL calls, options, JSON shapes, result versions, finding codes,
authorization checks, and retention rules stay the same. M44 adds no new
explanation function, response wrapper, stored row, evaluator, or default
option.

Elapsed time can vary between calls. It is a measurement, not part of the
answer's identity. A retained answer is historical evidence. It does not say
that the decision is still current.

## Upgrade

Back up the database, install `0.41.0`, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.41.0';
```

The supported upgrade is `0.40.0 -> 0.41.0`. Restore a verified `0.40.0`
backup if you need to roll back. See [the migration guide](m44-migration.md).

## Before publishing

M44 requires one external financial-exception or access-drift review that uses
at least two explanation origins. The repository fixture is not that review.
Publish `v0.41.0` only after that record and the complete release workflow pass.

## What comes next

The roadmap names M45, rolling and hopping windows, as the next candidate. It
is not a commitment. Select it only after M44 evidence and user demand support
the time-window problem.

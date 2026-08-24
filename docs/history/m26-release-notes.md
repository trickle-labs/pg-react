# pg-react 0.23.0 — clear winners, visible ties

M26 adds decision tables to pg-react. In ordinary PostgreSQL terms, you keep
possible answers in one normal SQL table. pg-react watches that table and
records which answer currently applies to each subject, along with enough
history and evidence to explain the result.

For each subject, the candidate with the lowest `bigint` priority wins. If two
or more candidates share the best priority, pg-react does not guess: it marks
the subject **ambiguous** until the candidates are fixed. If a previously
known subject has no candidates left, it reports **no candidate** and does not
invent a default. A subject never seen by the decision program is reported as
**never observed**, which is different from no candidate.

Status, history, preview, and explanation show the selected candidate and
result, or the exact state above. They also show a bounded, consistently
ordered set of relevant competitors and say when that evidence was truncated.
Changes to a candidate recompute only affected subjects. A changed result for
the same winner is a revision; a winner replacement closes the old activation
and opens the new one. Deploying or replacing a decision version is atomic, so
readers do not see winners from mixed versions.

This release keeps PostgreSQL as the policy language. It does not add a
spreadsheet-like DSL, generated SQL, visual or AI editor, multi-winner or
weighted scoring, arbitrary tie-breakers, defaults, coverage/conflict
analysis, hypothetical facts, backtesting, replay, policy-set gating, or
synchronous or exactly-once external effects. The logical next milestone is
M27 — Decision coverage and conflict analysis.

Upgrade directly from `0.22.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.23.0';
```

Existing rules and parameter families continue unchanged until a decision
program is explicitly declared and deployed. The upgrade does not invent
decision candidates or winners.

Release `v0.23.0` only after the fast and complete validation commands in
`docs/m26-readiness.md` pass, including inherited behavior, security,
concurrency, failure, recovery, retention, compatibility, direct-upgrade,
checksums, SBOM, provenance, and usability evidence.

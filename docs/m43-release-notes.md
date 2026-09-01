# pg-react 0.40.0: see what changed in a policy

M43 helps a reviewer answer a simple question before a policy update: “What is
different from the version running now?”

## What changed

- Add `pgreact_api.semantic_diff` for one proposed declaration and one deployed target.
- Describe changes to modeled rule, decision-program, and policy-set fields.
- Show typed before-and-after values, including dates, names, relations, lists,
  keyed policy members, nulls, and missing fields.
- Show when a relation definition or action-function body changed without
  pretending to understand the SQL.
- Bound large declarations and return the exact limit when the answer is partial.
- Keep the operation read-only: it does not deploy, evaluate, refresh, create
  work, or change the database.

## What did not change

Existing declarations, decisions, snapshots, comparisons, explanations,
lifecycle state, work, and retention keep their previous behavior. M43 does not
say whether a change is safe, predict which customers are affected, or assign
business meaning to arbitrary SQL. Use the existing comparison and explanation
tools for those questions.

The comparison is an ordinary read-only operator: it returns a plain JSON
report and does not change deployed policy state.

## Upgrade

Back up the database, install `0.40.0`, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.40.0';
```

The supported upgrade is `0.39.0 -> 0.40.0`. There is no in-place downgrade;
restore a verified `0.39.0` backup if you need to go back. See
[`m43-migration.md`](m43-migration.md).

## What to do next

Use M43 on real financial-exception and access-drift reviews. Check whether the
field-level answer is enough to approve a change, and record questions that
still need outcome or causal evidence. That work selected M44, explanation
qualification, as the current planning milestone for extension `0.41.0`.

# M19 selective immediate maintenance contract

M19 is extension `0.16.0`. Scheduled `DIFFERENTIAL` maintenance remains the
default. Immediate maintenance is an explicit per-version opt-in and never a
silent fallback.

## Frozen capability

The supported tuple is PostgreSQL `18.3`, `pg_trickle` `0.81.0`,
`pg_trickle.user_triggers=auto`, and `READ COMMITTED`. The public capability
observer is `pgreact_api.immediate_capabilities()`.

An immediate constraint rule is a `CONSTRAINT` rule whose condition is a view
with one direct `bigint` semantic key, one ordinary base-table dependency, and
a positive finite query. `INSERT`, `UPDATE`, and `DELETE` source statements
are supported. Joins, aggregates, windows, subqueries, recursion, negation,
deadlines, RLS sources, other rule kinds, other isolation levels, and another
PostgreSQL/pg_trickle tuple return a public error before durable opt-in state.

An immediate derivation program is finite, acyclic, positive, database-local,
and has every member explicitly opted in. The root uses native pg_trickle
immediate maintenance. Downstream members use ordered in-transaction
differential refresh because pg_trickle `0.81.0` cannot nest immediate stream
refreshes; this is exposed as the M19 closure boundary and is not a scheduled
semantic downgrade. A scheduled downstream consumer is outside the closure and
is explicitly asynchronous.

## Visibility and atomicity

After each supported source statement, the issuing transaction can read the
maintained relation and public `matches`, `status`, `explain`, and `doctor`
outputs before commit. Match rows, activations, derived facts, supports,
evidence, lifecycle history, and agenda rows share the source transaction and
roll back with it. Workers and arbitrary consequences see only committed work;
M19 never runs user code synchronously.

Immediate finalization coalesces repeated changes to a semantic key in the
current transaction and works through savepoints and statement failures.

## Locks and conflicts

Enrollment and replacement take the program lock first, then the rule-version
advisory transaction lock. Immediate finalization takes the rule-version lock
before consuming its statement delta. Concurrent work therefore either observes
the equivalent serialized state or fails before partial durable state; normal
PostgreSQL lock errors are surfaced unchanged. DDL remains protected by the
inherited binding lock.

## Public operations

- `validate_immediate_rule`, `author_immediate_rule`, and
  `replace_immediate_rule` cover constraint rules.
- `validate_immediate_program`, `preview_immediate_program`, and
  `deploy_immediate_program` cover finite derivation closures.
- `status`, `matches`, `explain`, and `doctor` report mode, contract version,
  visibility, consequence boundary, and remediation through the existing public
  API surface.

Commands, outbox/manual effects, external effects, recursive or aggregate
immediate maintenance, and automatic mode selection remain out of scope.

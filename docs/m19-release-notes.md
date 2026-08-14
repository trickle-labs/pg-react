# pg-react 0.16.0 — selective immediate maintenance

M19 adds an explicit bounded read-your-writes path for eligible constraint
rules and finite positive derivation closures. Scheduled differential
maintenance remains the default.

The supported contract is PostgreSQL 18.3, pg_trickle 0.81.0,
`READ COMMITTED`, and `pg_trickle.user_triggers=auto`. Unsupported query shapes,
sources, effects, isolation levels, and mixed closures are rejected before
durable opt-in state. Immediate maintenance updates matches, lifecycle truth,
derived facts, supports, evidence, and agenda atomically with the source
transaction; workers still see only committed work.

Upgrade directly from `0.15.0` with `ALTER EXTENSION pg_react UPDATE TO
'0.16.0'`. Existing scheduled declarations remain scheduled.

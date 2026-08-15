# M20 entry and reference fixture

The pinned tuple remains PostgreSQL `18.3`, pg_trickle `0.81.0`,
`READ COMMITTED`, and `pg_trickle.user_triggers=auto`.

Fast entry evidence:

```text
tests/m20.sh fast pg-react:v0.17.0
```

The reference fixture covers a named condition, exact typed relation output,
two rule consumers, one source transition, status/cost/explanation output,
compatible and incompatible replacement, removal blocking, source drift,
reader visibility, and the direct populated upgrade.

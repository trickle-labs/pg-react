# M19 compatibility inventory

| Area | M19 contract |
| --- | --- |
| Extension | `0.16.0`; direct upgrade from `0.15.0` |
| PostgreSQL | `18.3` only |
| pg_trickle | `0.81.0` only; `user_triggers=auto` |
| Isolation | `READ COMMITTED` only |
| Default | `SCHEDULED` / `DIFFERENTIAL` |
| Immediate rule | one direct bigint key, one base table, positive constraint view |
| Immediate program | finite, acyclic, positive, database-local; all members opt in |
| Visibility | after each supported source statement in the issuing transaction |
| Consequences | committed agenda only; worker and external effects remain asynchronous |
| Unsupported | joins, aggregates, windows, subqueries, recursion, negation, deadlines, RLS, commands, outbox/manual/external effects |

Existing scheduled declarations retain their M0–M18 behavior. Immediate mode
is never inferred from an existing declaration.

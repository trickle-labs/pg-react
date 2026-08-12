# pg-react 0.9.0 — database-time deadlines

Version `0.9.0` adds database-time deadlines to ordinary constraint and command
rules. Authors name one direct non-null `timestamptz` column; a candidate is due
when the durable monotone PostgreSQL clock reaches it. Equality is due.

Deadline candidates use the existing explicit `DIFFERENTIAL` path and an index
on deadline plus semantic key. One coordinator transaction commits the clock,
lifecycle, agenda, and evidence behind the inherited claim barrier. Backward
clock changes pause progress, forward jumps and downtime catch up once, and
postponement uses normal deactivation/reactivation generations.

Status, history, health, and explanation report the declared deadline and
observed clock. Validation rejects unsupported time expressions, temporal
derivation, recurrence, windows, unauthorized objects, nulls, and non-finite
values without mutation.

The supported in-place migration is `0.8.0 -> 0.9.0`. It preserves all M11
state and pending work and initializes the clock without retroactive events.
The PostgreSQL 18.3, pg_trickle 0.81.0, pgrx 0.18.0, Linux `amd64`,
`READ COMMITTED`, bigint-v1, no-RLS, physical-recovery, worker-protocol-1/2,
resource, and at-least-once external-effect boundaries are unchanged.

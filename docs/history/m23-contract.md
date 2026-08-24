# M23 contract — practical temporal conditions

M23 is extension `0.20.0`, with a direct upgrade from `0.19.0`. It adds four
small temporal primitives to the existing PostgreSQL-native rule stream. All
boundaries use the committed monotone database-time frontier; event time,
source commit time, and consequence latency are not substituted for it.

## Public API

```sql
pgreact_api.validate_temporal_rule(
  condition regclass, semantic_key name, primitive text,
  duration interval DEFAULT NULL, deadline_column name DEFAULT NULL,
  cooldown interval DEFAULT NULL, recovery_condition regclass DEFAULT NULL,
  recovery_key_column name DEFAULT NULL
) RETURNS TABLE (...)

pgreact_api.author_temporal_rule(
  rule_name text, condition regclass, semantic_key name, primitive text,
  duration interval DEFAULT NULL, deadline_column name DEFAULT NULL,
  cooldown interval DEFAULT NULL, recovery_condition regclass DEFAULT NULL,
  recovery_key_column name DEFAULT NULL, on_activate regprocedure DEFAULT NULL,
  ...retry and agenda options...
) RETURNS uuid

pgreact_api.temporal_preview(name text DEFAULT NULL) RETURNS jsonb
pgreact_api.temporal_status(name text DEFAULT NULL) RETURNS jsonb
pgreact_api.temporal_history(name text) RETURNS jsonb
pgreact_api.temporal_explain(name text, semantic_key bigint) RETURNS jsonb
pgreact_api.temporal_doctor() RETURNS jsonb
pgreact_api.reconcile_temporal_rule(name text) RETURNS bigint
pgreact_api.pause_temporal_rule(name text) RETURNS void
pgreact_api.resume_temporal_rule(name text) RETURNS void
pgreact_api.remove_temporal_rule(name text) RETURNS void
```

`author_temporal_rule` first creates the inherited maintained match stream and
then attaches one indexed temporal declaration. The optional activation action
is queued through the existing lifecycle, agenda, claim, lease, retry, and
managed-worker paths.

## Semantics

- `DURATION` starts `continuous_since` at the first finite committed frontier
  where the keyed input is true. It activates at `continuous_since + duration`;
  any retraction before that boundary cancels the pending state.
- `ABSENCE` uses one direct finite non-null `timestamptz` column. A missing
  satisfaction is due at the retained deadline, and equality is due. A
  satisfaction before or at the boundary cancels absence.
- `COOLDOWN` suppresses re-entry until the durable cooldown boundary after a
  prior active interval. A true input remains one active episode while it is
  continuously true.
- `HYSTERESIS` has an enter view and a recovery view. Recovery deactivates and
  re-arms the key; an intermediate band preserves the active state without
  chatter. Enter truth wins when enter and recovery are simultaneously true.

Durations are positive integral microseconds. State is bounded per semantic key
and indexed by pending deadline and cooldown boundary. Clock equality is due.
Backward clock movement pauses temporal progress without retracting due state.
Consequences remain asynchronous and at-least-once.

## Boundary

M23 does not add a CEP language, arbitrary sequences, rolling or calendar
windows, temporal joins, event-time duration or absence, timer callbacks,
sleeping workers, a second scheduler, exact wall-clock delivery, effective
dates, parameterized policy families, decision tables, or client DSLs.

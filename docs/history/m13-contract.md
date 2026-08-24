# M13 contract — core PostgreSQL ergonomics

M13 is extension `0.10.0`. It changes the ordinary author, coordinator, action,
inspection, and grant surface without changing M12 truth, lifecycle, worker,
retry, recovery, resource, or external-effect semantics.

## Authoring and action resolution

The existing three-argument `author_rule` call remains the common constraint
form. The new activation-only and lifecycle overloads name `action_schema` and
action routines separately. The lifecycle form accepts activate, deactivate,
and change action names; deactivate or change must be present. Deadline command
rules have the same activation-only convenience form.

Resolution examines only the named persistent application schema, never
`search_path`. An action must be one ordinary, non-set-returning,
`RETURNS void` function with no defaults, `VARIADIC`, OUT, or polymorphic
arguments. It must be owned and executable by the condition owner. Supported
signatures are:

| Event | Without context | With context |
| --- | --- | --- |
| activate/deactivate | `(condition_row)` | `(pgreact.activation_context, condition_row)` |
| change | `(old_condition_row, new_condition_row)` | `(pgreact.activation_context, old_condition_row, new_condition_row)` |

Missing, structurally incompatible, unauthorized, and multiply authorized
candidates fail before catalog mutation. Deployment records the selected OID,
fully qualified `regprocedure` identity, function digest, generated dispatcher
identity, and dispatcher digest. Later overloads or `search_path` changes cannot
retarget work; function or dispatcher drift blocks execution.

## Canonical run

`pgreact_api.run(sampled_time => clock_timestamp())` is the only ordinary
coordinator path. It takes the inherited global transaction and session locks,
rejects standby or pre-existing recovery barriers, and then, in one
transaction:

1. refreshes active rules whose conditions do not depend on derived facts;
2. advances standalone derived relations;
3. advances active derivation programs in cross-program dependency order;
4. refreshes rules that observe derived facts;
5. advances the monotone deadline frontier from one sample; and
6. removes its barriers before returning.

The transaction lock remains held until commit, so concurrent calls serialize
even when `run` is invoked inside an explicit transaction. Any refresh,
program, clock, resource, or injected failure rolls back the complete run and
releases every session lock. The result is contract version 3 and contains the
sample, refreshed rules, relations, programs, clock transition, and number of
new durable jobs. Consequences remain asynchronous. Compatibility
`run_rule(name)` verifies the name and delegates to the complete run; it is no
longer a partial refresh shortcut.

## Vocabulary and inspection

Ordinary inspection uses `status`, `explain`, `matches`, `jobs`, and
`attempts`. Their common fields use rule, match, action, job, and attempt
language. `rule_status`, `explain_rule`, `deadline_history`, and the exact
activation, generation, episode, support, component, stratum, and frontier
evidence remain the lossless advanced compatibility boundary.

## Roles and worker

The extension creates no roles. An extension owner calls
`configure_roles(author_role, operator_role, worker_role, reader_role)` with
four existing distinct roles. Reconfiguration first revokes every
`pgreact_api` function from the old and supplied role set, then grants exact
overload identities:

- authors validate and author only;
- operators run, administer, and inspect;
- workers check protocol compatibility, claim, and execute single or batch jobs;
- readers inspect only.

`PUBLIC` has no facade access and no application role receives private-schema
access. Dropped configured roles are ignored safely during repair. The bundled
worker keeps its released positional compatibility argument, runs the database
through `pgreact_api.run` on `COORDINATOR_DATABASE_URL`, and claims or executes
only through worker facade routines on `DATABASE_URL`.

## Boundary

M13 retains PostgreSQL 18.3, `pg_trickle` 0.81.0, pgrx 0.18.0, Linux `amd64`,
coordinator-owned `DIFFERENTIAL`, `READ COMMITTED`, bigint-v1 keys, no RLS,
physical recovery, worker protocols 1 and 2, bounded resources, and
at-least-once external effects. It adds no reasoning semantics, key codec,
isolation mode, managed background worker, client DSL, or search-path dispatch.

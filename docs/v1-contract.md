# pg-react v1 contract

This document freezes the supported public contract for extension and crate
version `0.1.1`. The worker protocol is `1`; the outbox envelope is `1`.
[`sql/pg_react--0.1.1.sql`](../sql/pg_react--0.1.1.sql) is the authority if this
inventory and the packaged SQL ever disagree.

`pgreact` is the public API namespace, but installation grants nothing in it to
`PUBLIC`. Deployments must grant the least privileges needed by their author,
worker, operator, and reader roles. `pgreact_internal`, `pgreact_runtime`, their
relations, and generated dispatcher functions are not public contracts and
must not be queried or changed by applications.

## Supported compatibility boundary

| Component | v1 supported value |
| --- | --- |
| PostgreSQL | `18.3`, primary or promoted primary |
| `pg_trickle` | `0.81.0` at `ba41c9c2e2bbf2195917fcdcc89efa8ab3089dcb`; image `ghcr.io/trickle-labs/pg_trickle@sha256:998ab948555e990dcffc9464f316b3abe6b05f9ebc8bd50f16d3bc5bf88ca65d` |
| `pgrx` | `0.18.0` |
| OS / architecture | Linux container, `linux/amd64`; macOS only as a Docker host |
| Maintenance | Coordinator-owned explicit `DIFFERENTIAL`; `pg_trickle.enabled=off`, `user_triggers=auto`, `differential_max_change_ratio=1.0` |
| Isolation | `READ COMMITTED` |
| Semantic key | Exactly one non-null, unique `bigint`, codec `1` |
| Source | Owned normal PostgreSQL view, no RLS-protected dependency, no non-`pg_catalog` executable dependency |
| Extension | `0.1.1`; direct upgrade from `0.1.0` only |
| Worker | Protocol `1` only |

`AUTO`, `FULL`, `IMMEDIATE`, automatic scheduler refresh, early deferred-trigger
firing, uncoordinated refresh, other PostgreSQL/OS/architecture combinations,
other isolation levels, additional key codecs, and RLS-protected sources are
unsupported. An unsupported combination must not be treated as best-effort
compatible.

## Public SQL inventory

Parameter names and defaults are part of the callable v1 surface. The following
are the final effective declarations after the install script's drops and
replacements.

### Type and views

```sql
pgreact.activation_context (
    activation_id uuid,
    episode_id bigint,
    rule_id uuid,
    rule_version_id uuid,
    generation bigint,
    revision bigint,
    event_kind text,
    attempt_no integer,
    event_at timestamptz,
    worker_id text,
    idempotency_key text
)

pgreact.rules (
    rule_id uuid, rule_name text, rule_version_id uuid, owner name,
    source_view_name text, key_column name, consequence_identity text,
    bootstrap_policy text, state text, created_at timestamptz
)

pgreact.activations (
    rule_version_id uuid, activation_id uuid, semantic_key bigint,
    current_bindings jsonb, active boolean, generation bigint,
    first_seen_at timestamptz, last_seen_at timestamptz,
    deactivated_at timestamptz, revision bigint
)

pgreact.episodes (
    episode_id bigint, rule_id uuid, rule_version_id uuid, activation_id uuid,
    activation_generation bigint, state text, worker_id text,
    claimed_at timestamptz, lease_expires_at timestamptz,
    completed_at timestamptz, idempotency_key text,
    activation_revision bigint, event_kind text, agenda_group text,
    salience integer, conflict_key text, attempt_count integer,
    max_attempts integer
)

pgreact.attempts (
    execution_id bigint, episode_id bigint, attempt_no integer, worker_id text,
    started_at timestamptz, finished_at timestamptz, status text,
    error_message text, error_code text, event_kind text
)

pgreact.operational_status (
    rule_name text, rule_version_id uuid, state text, agenda_group text,
    outstanding_episodes bigint, oldest_eligible_at timestamptz,
    failed_episodes bigint, claims_blocked boolean
)
```

### Authoring and lifecycle management

```sql
pgreact.validate_rule(
    definition regclass,
    key_columns name[],
    on_activate regprocedure DEFAULT NULL
) -> table(
    contract_version integer, code text, severity text, object_identity text,
    message text, hint text, details jsonb
)

pgreact.create_rule(
    name text,
    definition regclass,
    key_columns name[],
    kind text DEFAULT NULL,
    on_activate regprocedure DEFAULT NULL,
    on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    change_columns name[] DEFAULT NULL,
    salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default',
    conflict_key_columns name[] DEFAULT NULL,
    max_attempts integer DEFAULT 1,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
) -> uuid

pgreact.preview_rule(definition regclass, key_columns name[])
    -> table(snapshot_at timestamptz, semantic_key bigint, bindings jsonb)
pgreact.preview_rule(definition regclass, key_columns name[], bootstrap_policy text)
    -> table(snapshot_at timestamptz, semantic_key bigint, bindings jsonb)

pgreact.replace_rule(
    target_version_id uuid,
    definition regclass,
    key_columns name[],
    on_activate regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL,
    old_work_policy text DEFAULT 'DRAIN_OLD'
) -> uuid

pgreact.pause_rule(target_version_id uuid) -> void
pgreact.pause_rule(target_rule_name text) -> void
pgreact.resume_rule(target_version_id uuid) -> void
pgreact.resume_rule(target_rule_name text) -> void
pgreact.remove_rule(target_version_id uuid) -> void
```

The consequence signatures are exact and return `void`:

```sql
-- ACTIVATE and DEACTIVATE
(pgreact.activation_context, source_view_row) -> void

-- CHANGE
(pgreact.activation_context, old_source_view_row, new_source_view_row) -> void
```

Consequences and their source view are owned by the rule owner. All projected
non-key columns are watched when `change_columns` is `NULL`; an explicit empty
array disables change detection. `bootstrap_policy` accepts `SEED_CURRENT` or
`REQUIRE_EMPTY`. `old_work_policy` accepts `DRAIN_OLD` or `CANCEL_OLD`.

### Refresh and recovery

```sql
pgreact.begin_refresh(target_version_id uuid, refresh_id bigint) -> void
pgreact.refresh_rule(target_version_id uuid) -> void
pgreact.clear_refresh_barrier(target_version_id uuid) -> void
pgreact.release_refresh_lock() -> boolean

pgreact.begin_reconciliation(target_version_id uuid) -> void
pgreact.reconcile_rule(
    target_version_id uuid,
    emission_mode text DEFAULT 'STATE_ONLY'
) -> bigint

pgreact.prepare_recovery() -> bigint
pgreact.rebuild_transient_metadata()
    -> table(rebuilt_rules bigint, blocked_rules bigint)
```

`reconcile_rule` accepts `STATE_ONLY` or `EMIT_MISSING_EVENTS` and requires a
claim barrier committed by `begin_reconciliation` or `prepare_recovery`.

### Worker and agenda

```sql
pgreact.worker_protocol_compatible(worker_protocol integer DEFAULT 1) -> boolean

pgreact.claim(
    worker_id text,
    max_items integer DEFAULT 1,
    lease_for interval DEFAULT interval '60 seconds',
    agenda_groups text[] DEFAULT NULL
) -> table(
    episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb,
    event_kind text, rule_version_id uuid
)

pgreact.claim_episode(
    target_version_id uuid,
    worker_id text,
    lease_seconds integer DEFAULT 60
) -> table(
    episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb
)

pgreact.heartbeat_episode(
    target_episode_id bigint,
    expected_worker_id text,
    expected_lease_token uuid,
    extend_for interval DEFAULT interval '60 seconds'
) -> timestamptz

pgreact.execute_claimed_episode(
    target_episode_id bigint,
    expected_worker_id text,
    expected_lease_token uuid
) -> text

pgreact.sweep_expired_leases(target_version_id uuid) -> bigint
pgreact.requeue_episode(target_episode_id bigint) -> void
pgreact.cancel_episode(target_episode_id bigint) -> void
```

### Outbox

```sql
pgreact.register_outbox_sink(sink regprocedure) -> regprocedure

pgreact.bind_outbox_consequence(
    target_version_id uuid,
    kind text,
    sink regprocedure,
    max_attempts integer DEFAULT 3,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
) -> void
```

An outbox sink has the exact signature
`(pgreact.activation_context, jsonb) RETURNS void`.

### Inspection and operations

```sql
pgreact.current_matches(target_rule_name text)
    -> table(activation_id uuid, activation_key bigint, bindings jsonb, active_since timestamptz)
pgreact.rule_status() -> setof pgreact.rules
pgreact.agenda_status() -> setof pgreact.episodes
pgreact.execution_history() -> setof pgreact.attempts
pgreact.source_drift()
    -> table(rule_version_id uuid, source_view_name text, status text)

pgreact.explain_rule(target_version_id uuid) -> jsonb
pgreact.explain_activation(target_version_id uuid, target_activation_id uuid) -> jsonb
pgreact.explain_episode(target_episode_id bigint) -> jsonb
pgreact.health_check()
    -> table(code text, severity text, object_identity text, message text, hint text)
pgreact.metrics() -> jsonb

pgreact.configure_operations(
    max_claims integer DEFAULT 100,
    max_lease_seconds integer DEFAULT 3600,
    fairness_window interval DEFAULT interval '30 seconds',
    max_pending_per_rule integer DEFAULT 10000
) -> void
pgreact.configure_agenda_group(target_agenda_group text, max_leases integer) -> void
pgreact.prune_payloads(payload_before timestamptz)
    -> table(lifecycle_payloads_cleared bigint, agenda_payloads_cleared bigint)
```

## Worker protocol 1

Protocol 1 is a SQL transaction protocol, not a network wire format.

1. Before claiming, a worker requires
   `pgreact.worker_protocol_compatible(1) = true`. Version `0.1.1` advertises
   minimum and maximum protocol `1`; false means stop claims and upgrade the
   extension and worker together.
2. The coordinator calls `begin_refresh`, performs `refresh_rule` in an
   explicit `READ COMMITTED` transaction, commits, calls
   `clear_refresh_barrier`, then releases the session lock with
   `release_refresh_lock`. A failure after the barrier commits leaves that
   durable barrier in place.
3. A worker calls `claim` or `claim_episode`. A claim is identified by the
   returned `(episode_id, worker_id, lease_token)` and is valid only until its
   lease expires. Claims respect barriers, rule state, retry availability,
   conflict leases, fairness, agenda-group limits, and configured bounds.
4. Long work may extend a still-valid lease with `heartbeat_episode`. Expired
   leases are reclaimed by `sweep_expired_leases` or during a later claim.
5. Each episode is executed in its own transaction with
   `execute_claimed_episode`. The function rejects stale ownership, rechecks
   lifecycle eligibility and definition fingerprints immediately before
   dispatch, and returns `COMPLETED`, `SKIPPED`, `RETRY_WAIT`, or `FAILED`.
6. PostgreSQL is the sole durable worker state. Polling is authoritative; a
   notifier, if added by a deployment, is only a hint. Workers must not claim
   on a physical standby.

The bundled `bin/pg-reactd` performs one compatibility check, one coordinated
refresh, one bounded claim batch, one transaction per claimed episode, and
then exits. A service manager supplies repetition and process supervision.

## Catalog migration and compatibility policy

- `0.1.1` is the current catalog. `0.1.0` is retained only as the supported
  direct upgrade source. The install scripts and
  `pg_react--0.1.0--0.1.1.sql` are immutable release artifacts.
- Upgrade only with `ALTER EXTENSION pg_react UPDATE TO '0.1.1'`; never replay
  an install script or edit `pgreact_internal` directly. There is no supported
  downgrade or skipped-version path. Rollback means restoring the pre-upgrade
  backup.
- Stop workers and take a tested backup before upgrade. After upgrade, rebuild
  transient OID metadata, reconcile behind committed barriers, sweep expired
  leases, and require an error-free `health_check` before resuming claims.
- The supported recovery unit is a physical cluster backup or PITR image of
  the exact v1 tuple, followed by pg-react recovery and reconciliation. A
  logical `pg_dump`/`pg_restore` of live rule state is unsupported because
  pinned pg_trickle `0.81.0` cannot reconstruct restored source OIDs and
  differential change tracking through its public restore APIs.
- Public v1 function names, overloads, parameter names/defaults, return shapes,
  view column order, `activation_context`, worker protocol 1, and outbox
  envelope 1 are compatibility commitments. Private schemas and physical
  catalog layout may change only through an extension migration.
- A source-view or consequence definition change is not silently adopted.
  Compatible source text drift warns; incompatible row or exact-function drift
  blocks execution until the rule is replaced or metadata is repaired.

## External delivery guarantee

pg-react atomically calls the registered transactional sink and marks the
episode complete in one PostgreSQL transaction. Envelope version `1` contains
`version`, `rule_id`, `rule_version_id`, `event_kind`, `activation_id`,
`generation`, `revision`, `episode_id`, `idempotency_key`, `old`, and `new`.
The idempotency key is deterministic for one immutable lifecycle event.

That transaction guarantees durable enqueue or no completed episode; it does
not make the remote effect exactly once. `register_outbox_sink` validates only
the SQL signature, so the deployment must verify that the sink is transactional
and that its relay retries until acceptance. With such a conforming sink,
delivery is at least once. The sink owns its outbox, relay, transport retries,
replay, and delivery diagnostics. Duplicates may follow timeouts, failover,
manual replay, or restoration, and ordering is not guaranteed across retries or
independent keys. A receiver must atomically deduplicate by `idempotency_key`
while applying its effect and retain deduplication state for at least the
deployment's declared delivery-and-replay window. pg-react does not define that
duration. Payload pruning must not precede the same window.

Irreversible HTTP, email, file, model, or other external calls do not belong in
a database consequence. Version `0.1.1` supplies the sink contract but no relay
or bundled pg_tide adapter.

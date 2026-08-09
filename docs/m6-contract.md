# M6 audited batch contract

This is the implemented M6 contract. M6 is extension `0.3.0`; worker protocol
`2` adds explicit batching while protocol `1` remains supported and is still
the default.

## Declaration and API

Only an existing `DATABASE_TYPED` binding can be declared batch-safe:

```sql
pgreact.declare_batch_safe(target_version_id uuid, event_kind text) RETURNS void
```

The rule owner declares safety before the first lifecycle event for that
binding. The declaration is append-only: it cannot be disabled or changed on
an immutable rule version. Replacing the rule is the only way to change it.
The author asserts that the consequence is commutative, idempotent by the
episode key, and independent across different conflict keys. pg-react does not
infer those properties.

Workers use two separate endpoints:

```sql
pgreact.claim_batch(
    target_version_id uuid,
    event_kind text,
    worker_id text,
    max_items integer DEFAULT 32,
    lease_for interval DEFAULT interval '60 seconds'
) RETURNS TABLE(
    batch_id uuid,
    item_order integer,
    episode_id bigint,
    lease_token uuid
)

pgreact.execute_claimed_batch(
    target_batch_id uuid,
    expected_worker_id text
) RETURNS TABLE(
    episode_id bigint,
    status text,
    error_code text,
    error_message text
)
```

`max_items` is bounded from 2 through 32. Batch claim accepts only one exact
rule version, event kind, typed consequence OID and digest, dispatcher OID and
digest, owner execution role, fresh-recheck policy, and conflict-key
definition. Non-null conflict keys within one batch must be distinct. Outbox,
manual, no-op, immediate-maintenance, synchronous, undeclared, mixed, and
order-dependent work is rejected.

## Transaction and failure semantics

Claim commits leases and the batch record in one `READ COMMITTED` transaction.
Execution is one later `READ COMMITTED` transaction. It takes the existing
refresh, deployment, and binding locks; locks every item by `episode_id`; and
revalidates the complete batch before invoking any consequence. It rejects the
whole invocation with an exact public diagnostic if any item is stale,
ineligible, expired before the initial validation, paused, replaced,
barrier-blocked, drifted, or structurally incompatible. No consequence runs,
and the individual leases remain usable until their normal expiry.

After initial validation, the locked leases remain owned for that transaction.
Every item receives the same fresh lifecycle eligibility check immediately
before invocation. An earlier item may therefore make a later item `SKIPPED`,
exactly as on the default path.

Each consequence runs in a PostgreSQL exception block. An item error rolls
back only that item's effect and follows its existing retry policy; independent
items continue. Successful effects, per-episode attempts, agenda outcomes, and
batch diagnostics commit atomically in the outer transaction. An unexpected
transaction abort, server crash, or worker death rolls back the entire
invocation and leaves the committed leases recoverable. After an ambiguous
disconnect, the worker reads public batch history before retrying.

There is no consequence ordering promise. `item_order` exists only to make
selection and diagnostics reproducible. Idempotency remains per episode; a
batch identifier is not a business-effect identity.

## Worker opt-in and observability

`pg-reactd` keeps protocol `1`, `MAX_CLAIMS`, and one episode per transaction
unless `BATCH_MAX_ITEMS` is explicitly set from 2 through 32. Batch opt-in
requires `worker_protocol_compatible(2)`; incompatible workers stop before
claiming.

Existing public episode and attempt history remains compatible. M6 adds
`batch_history(batch_id uuid DEFAULT NULL)`. Its public signature JSON records
the maximum size, exact consequence and dispatcher identities and digests,
execution role, `FRESH` policy, and conflict-key columns. Each item records its
selection order, episode, attempt number, rejection/error fields, retry state,
and final outcome. `explain_episode` links an episode to that batch history. No
private-catalog access is required to declare, run, inspect, retry, or disable
batch execution; disabling means removing worker opt-in, not mutating a rule.

## Upgrade and public workflow

Install the `0.3.0` files and run the only supported M6 migration:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.3.0';
SELECT pgreact.worker_protocol_compatible(1),
       pgreact.worker_protocol_compatible(2);
```

Existing `0.2.0` rules, protocol-1 workers, episodes, and attempts continue
unchanged. A declaration must precede the first lifecycle event, so an existing
version with history stays on protocol 1; replace it with a reviewed version if
batching is required. For a new eligible version:

```sql
SELECT pgreact.declare_batch_safe(:'rule_version_id'::uuid, 'ACTIVATE');
SELECT * FROM pgreact.claim_batch(
  :'rule_version_id'::uuid, 'ACTIVATE', 'worker-a', 32
);
SELECT * FROM pgreact.execute_claimed_batch(:'batch_id'::uuid, 'worker-a');
SELECT * FROM pgreact.batch_history(:'batch_id'::uuid);
SELECT pgreact.explain_episode(:episode_id);
```

Set `BATCH_MAX_ITEMS=2..32` for the bundled worker to opt into protocol 2. It
tries `ACTIVATE`, `CHANGE`, then `DEACTIVATE` batches and falls back to the
unchanged single path when fewer than two eligible episodes exist. After a
pre-invocation rejection, the returned episode leases remain usable on the
single endpoint until expiry. Normal retry and `requeue_episode` policy remains
per episode. Remove `BATCH_MAX_ITEMS` to disable batching without catalog
mutation.

## Frozen benchmark budget

The entry workload is `tests/m6-entry.sh`, recorded in `m6-entry.md`. The M6
implementation gate is `tests/m6-benchmark.sh`; it uses the same reference
workload, batch size 32, end-to-end workload WAL, total durable pg-react bytes,
and the median of five warm samples:

- batch episode throughput is at least 1.5 times the `0.2.0` default;
- unchanged protocol-1 throughput regresses by no more than 5 percent;
- WAL bytes and durable pg-react bytes per completed episode are each no more
  than 1.25 times the default;
- both paths produce exactly identical normalized state, history, and effects;
- neither path exceeds one database connection per benchmark worker.

Failure, concurrency, upgrade, restart, and recovery cases are enumerated in
`m6-entry.md`. The exact `v0.2.0` publication gate still precedes M6 product
changes.

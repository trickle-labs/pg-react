# v1 troubleshooting

Start with public, read-only diagnostics:

```sql
SELECT * FROM pgreact.health_check();
SELECT pgreact.metrics();
SELECT * FROM pgreact.operational_status ORDER BY oldest_eligible_at NULLS LAST;
SELECT * FROM pgreact.source_drift();
```

Do not update `pgreact_internal`, delete barriers, or edit generated relations. The [operations runbook](m3-operations.md) is the recovery authority.

## Worker exits before claiming

Check protocol and connection roles:

```sql
SELECT pgreact.worker_protocol_compatible(1);
SELECT session_user, current_user;
```

`false` means the worker and database cannot roll together; stop claims and install the matching release. A permission error usually means `DATABASE_URL` lacks the narrow worker grants or `COORDINATOR_DATABASE_URL` is not the rule owner/`pgreact_admin`. See the [security guide](v1-security.md).

## A source change creates no work

```sql
SELECT * FROM pgreact.rule_status();
SELECT * FROM pgreact.current_matches('RULE_NAME');
SELECT * FROM pgreact.source_drift();
SELECT * FROM pgreact.agenda_status();
```

Confirm the rule is active, the condition row actually entered or changed a watched column, and a coordinator-owned refresh ran after the source commit. `SEED_CURRENT` intentionally creates no work for rows present at registration. Constraint rules and lifecycle events without a bound consequence also create no episodes.

Do not enable automatic pg_trickle scheduling. Re-run `bin/pg-reactd` for the affected rule version after correcting the source data or configuration.

## Claims are blocked

`health_check()` reports `BARRIER`, `SOURCE_DRIFT`, `CONSEQUENCE_DRIFT`, or `STANDBY` with a repair hint.

- After a failed refresh, correct the null/duplicate key or other root cause and rerun the coordinator sequence.
- After restore or promotion, follow the [backup/restore recovery sequence](v1-backup-restore.md#restore-into-an-isolated-target).
- For source or function drift, pause and explicitly replace the immutable version; do not alter the deployed binding in place.
- On a standby, stop the worker. Promote first, then run recovery.

Never call `clear_refresh_barrier()` as a generic repair; it belongs to a successful coordinated refresh.

## Work is stuck or failing

```sql
SELECT pgreact.explain_episode(EPISODE_ID);
SELECT * FROM pgreact.execution_history() WHERE episode_id = EPISODE_ID;
```

- `LEASED` past its expiry: run `pgreact.sweep_expired_leases(RULE_VERSION_UUID)`.
- `RETRY_WAIT`: wait for the configured bounded retry delay.
- `FAILED`: repair the cause, then use `pgreact.requeue_episode(EPISODE_ID)` only if replay is safe.
- `PENDING` backlog: drain work, cancel selected unleased episodes, or have `pgreact_admin` raise the measured limit with `configure_operations`.
- No claims in an agenda group: check its lease budget and currently leased episodes.

Every database consequence and outbox sink must be idempotent. A timeout or lost client response is not proof that its transaction failed.

## Rule DDL fails or reports drift

Registered functions and dispatchers are protected from concurrent mutation, and execution verifies their exact definitions. Deploy a new view/function definition, then use `pgreact.replace_rule` with `DRAIN_OLD` or `CANCEL_OLD`. Compatible source drift is a warning but is not adopted automatically; incompatible drift blocks claims.

## Collect a support bundle

Capture these results with secrets and payload values redacted:

```sql
SELECT version();
SELECT extname, extversion FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle') ORDER BY extname;
SHOW pg_trickle.enabled;
SHOW pg_trickle.user_triggers;
SHOW pg_trickle.differential_max_change_ratio;
SHOW default_transaction_isolation;
SELECT * FROM pgreact.health_check();
SELECT pgreact.metrics();
SELECT * FROM pgreact.rule_status();
SELECT * FROM pgreact.operational_status;
```

Also record the release artifact digest, worker protocol result, worker stderr, affected rule/version/episode IDs, and `pgreact.explain_rule` or `pgreact.explain_episode` output.

## Known unsupported cases

v1 does not cover PostgreSQL or pg_trickle versions outside the pinned tuple, non-`linux/amd64` deployments, workers on standbys, isolation other than `READ COMMITTED`, automatic/`AUTO`/`FULL`/`IMMEDIATE` maintenance, logical dump/restore or PostgreSQL-major upgrade of live rule state, RLS sources, multi-column or non-`bigint` keys, untrusted dynamic code, exactly-once external effects, global work ordering, synchronous source-write blocking, or M5 derivation and authoring features.

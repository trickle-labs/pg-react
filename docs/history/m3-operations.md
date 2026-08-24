# M3 operations runbook

## Roles and grants

Create only the roles your deployment needs. `pg_react` creates no cluster-wide roles and grants no public API access to `PUBLIC`.

```sql
CREATE ROLE pgreact_admin NOLOGIN;
CREATE ROLE pgreact_author NOLOGIN;
CREATE ROLE pgreact_operator NOLOGIN;
CREATE ROLE pgreact_worker NOLOGIN;
CREATE ROLE pgreact_reader NOLOGIN;

GRANT USAGE ON SCHEMA pgreact TO pgreact_author, pgreact_operator, pgreact_worker, pgreact_reader;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgreact TO pgreact_admin;
GRANT pgreact_admin TO pgreact_operator;
GRANT EXECUTE ON FUNCTION pgreact.claim(text, integer, interval, text[]),
    pgreact.claim_episode(uuid, text, integer),
    pgreact.heartbeat_episode(bigint, text, uuid, interval),
    pgreact.execute_claimed_episode(bigint, text, uuid),
    pgreact.sweep_expired_leases(uuid),
    pgreact.worker_protocol_compatible(integer) TO pgreact_worker;
GRANT SELECT ON pgreact.rules, pgreact.activations, pgreact.episodes,
    pgreact.attempts, pgreact.operational_status TO pgreact_reader, pgreact_operator;
```

Authors must own their view and consequence; grant them only the authoring and inspection functions their deployment uses. Operators are members of `pgreact_admin` and run the coordinator path. Claim-only workers get the narrow grants above and no access to protected schemas or generated relations.

Run `pg-reactd` with the claim-only connection in `DATABASE_URL` and an operator connection in `COORDINATOR_DATABASE_URL`. If the latter is omitted, the script uses `DATABASE_URL` for both paths and that role must be a rule owner or `pgreact_admin` member.

## Normal checks

Run these through a privileged operator connection:

```sql
SELECT * FROM pgreact.health_check();
SELECT pgreact.metrics();
SELECT * FROM pgreact.operational_status ORDER BY oldest_eligible_at NULLS LAST;
```

An error health row stops new worker claims for its affected rule. `pg-reactd` is a polling worker; `MAX_CLAIMS` is bounded by `configure_operations`, and a lease is always one episode transaction.

## Backlog, fairness, and deadlocks

The default claim limit is 100, maximum lease is one hour, and a pending episode that waits 30 seconds takes priority over newer high-salience work. Per-group concurrency is configured with `pgreact.configure_agenda_group`; refresh blocks atomically at `max_pending_per_rule` instead of accepting unbounded work. Tune only after observing `metrics()` and `operational_status`:

```sql
SELECT pgreact.configure_operations(50, 900, interval '30 seconds', 10000);
SELECT pgreact.configure_agenda_group('billing', 8);
```

Internal lock order is refresh/claim barrier, then binding DDL, then agenda row, then conflict lease. Claims reclaim expired leases before selecting work; an explicit sweep remains useful during recovery. The worker retries a deadlock victim at most three times with a short delay; after that it leaves the episode durable for another poll. Do not retry a failed source refresh outside the coordinator sequence.

## Drift, restore, migration, and promotion

For source or function drift: pause the version, inspect `explain_rule` and `health_check`, drain or cancel work, then use `replace_rule`. Never update private catalogs.

For physical restore, PITR, physical failover, or promotion: keep workers stopped; then run `prepare_recovery`, `rebuild_transient_metadata`, `reconcile_rule(version, 'STATE_ONLY')` for each version, `sweep_expired_leases(version)`, and `health_check`. Resume workers only with no error rows. Logical migration and logical `pg_dump`/`pg_restore` of live rules are unsupported in v1 because pinned pg_trickle cannot safely rebuild its restored OID/change-tracking state. For an ad hoc reconciliation, commit `begin_reconciliation(version)`, run `reconcile_rule` in a new transaction, then call `release_refresh_lock`; a failed reconciliation leaves its committed barrier in place. `rebuild_transient_metadata` reconstructs local pg-react OIDs only if durable view/function identities and fingerprints still match; otherwise its claim barrier remains in place.

Rolling worker upgrade is allowed only after `SELECT pgreact.worker_protocol_compatible(1)`. If false, stop claims, upgrade the extension and worker together, perform the recovery check, then resume.

## Retention and vacuum

`pgreact.prune_payloads(timestamp)` clears only old JSON payloads from terminal work and lifecycle rows. It retains identity, rule/version, activation, generation/revision, event kind, idempotency key, timestamps, and attempts; every run is recorded in `pgreact_internal.retention_audits`. It never removes pending or leased work. Run `VACUUM (ANALYZE)` after a large payload cleanup and retain payloads for at least the outbox consumer's deduplication/replay window.

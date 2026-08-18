# Historical M4 record: pg-react 0.1.1

> This file is immutable historical evidence for the first `0.1.1` release.
> It is not the `1.0.0` contract. See [`m3-compatibility.md`](m3-compatibility.md)
> for the historical support boundary and [`v1-contract.md`](v1-contract.md)
> for the current contract.

Version `0.1.1` froze the first public contract: SQL API v1, worker protocol
`1`, outbox envelope `1`, the direct `0.1.0 -> 0.1.1` catalog migration, and the
narrow compatibility matrix in [`m3-compatibility.md`](m3-compatibility.md).

## What changed since 0.1.0

- Operations are private by default: `PUBLIC` has no access to the `pgreact`,
  `pgreact_internal`, or `pgreact_runtime` schemas. Existing deployments must
  grant explicit author, worker, operator, and reader privileges after upgrade.
- Rule owners and `pgreact_admin` operators can use the guarded management and
  recovery APIs; application roles still receive no private-catalog access.
- Worker protocol 1 adds an explicit compatibility handshake while preserving
  bounded claims, lease-token ownership, heartbeats, stale-worker rejection,
  retry backoff, and one episode per transaction.
- Operational settings now bound claim count, lease duration, fairness, and
  per-rule backlog. Agenda-group lease budgets, atomic backpressure, expanded
  health checks, SQL metrics, and `operational_status` are available.
- Recovery can install claim barriers, rebuild transient OID references from
  durable identities and fingerprints, reconcile state, and audit the result.
- Payload pruning is limited to terminal work, preserves lifecycle identity and
  attempt history, and records an audit.
- The public SQL surface, compatibility boundary, migration policy, worker
  behavior, and external-delivery guarantee are now frozen in the v1 contract.

## Upgrade from 0.1.0

The only supported in-place path is `0.1.0 -> 0.1.1`. There is no downgrade;
rollback requires restoring the pre-upgrade backup.

1. Verify the supported platform tuple and stop every worker and coordinator.
2. Take and test a backup. Keep the `0.1.0` release artifact needed to restore
   it.
3. Install the `0.1.1` control, install, and upgrade SQL files on the server,
   verify their published SHA-256 checksums, then run:

   ```sql
   ALTER EXTENSION pg_react UPDATE TO '0.1.1';
   SELECT pgreact.worker_protocol_compatible(1);
   ```

4. Reapply explicit role grants because `0.1.1` revokes the former `PUBLIC`
   access. Do not grant access to `pgreact_internal` or `pgreact_runtime`.
5. With workers still stopped, commit `prepare_recovery()`, run
   `rebuild_transient_metadata()`, reconcile every non-removed version with
   `STATE_ONLY`, sweep its expired leases, and inspect `health_check()`.
   Resume workers only when metadata reports no blocked rule and health has no
   `ERROR` row.
6. Run the reference workflow and the release gates against the installed
   artifact, not a development checkout.

The migration preserves durable `0.1.0` rules, activations, lifecycle events,
agenda work, attempts, and reconciliation history while adding the `0.1.1`
operational catalogs and stable function identities. Direct edits to private
catalogs are unsupported.

## Artifact and checksum publication

A `0.1.1` release is complete only when all of the following are published in
the same release entry:

- immutable versioned source/package and `linux/amd64` OCI artifacts built from
  the tagged commit;
- the extension control file, `0.1.0`, `0.1.1`, and `0.1.0 -> 0.1.1` SQL files,
  and `bin/pg-reactd` at version `0.1.1` / protocol `1`;
- a SHA-256 checksum manifest for every downloadable file and an immutable OCI
  digest for every image tag;
- this release note, the v1 contract, upgrade instructions, known limitations,
  and evidence from the full gate and reference example run on those exact
  bytes.

The release checksum is computed after packaging and must be verified before
installation. The pinned upstream pg_trickle base-image digest is provenance,
not a substitute for the pg-react artifact checksum. Rebuilt bytes require a
new checksum and must not reuse the published artifact name or image digest.

## Known limitations

- Support is limited to PostgreSQL `18.3`, pinned pg_trickle `0.81.0`, pgrx
  `0.18.0`, and Linux `amd64`, using coordinator-owned explicit `DIFFERENTIAL`
  refresh under `READ COMMITTED`.
- Recovery of live rule state is supported through physical cluster backup,
  PITR, and physical failover. Logical `pg_dump`/`pg_restore` is not a supported
  recovery path: pg_trickle `0.81.0` does not publicly rebuild restored source
  OIDs and differential change tracking, which can otherwise cause a later
  lifecycle transition to be missed.
- Automatic pg_trickle scheduling, `AUTO`, `FULL`, `IMMEDIATE`, uncoordinated
  refresh, physical-standby workers, and early deferred-trigger firing are not
  supported.
- A rule uses one non-null unique `bigint` semantic key. Composite and other
  key codecs are not supported. Source definitions must be owned normal views;
  RLS-protected sources and non-`pg_catalog` executable dependencies are
  rejected.
- `pg-reactd` is a stateless one-cycle polling script, not a resident daemon,
  connection pool, notification service, or HTTP health/metrics server. It does
  not call the heartbeat API; deployments needing long work should use a worker
  that does.
- Episode execution is intentionally one transaction at a time. There is no
  audited batch-execution path or global ordering guarantee.
- `replace_rule` exposes fewer tuning arguments than `create_rule`; replacement
  uses the v1 defaults for watched columns, salience, agenda group, conflict
  keys, and retry policy.
- Core pg-react provides no relay, bundled pg_tide adapter, or remote exactly-once
  guarantee. Deployments supply a transactional sink, own delivery monitoring
  and replay, and make consumers deduplicate deterministic idempotency keys.
- Payload retention and consumer deduplication/replay durations are deployment
  policy; `0.1.1` defines no universal time window.
- Explain APIs expose rule, activation, episode, and attempt causality, not
  general base-tuple lineage. There are no derivation rules, fixed-point
  reasoning, schedules, raw-query authoring API, or no-code rule tooling.
- Validation is against the supported internal fixture and compatibility suite;
  it is not a claim of broad platform compatibility or external production
  adoption.

# pg-react 0.2.0 — safe rule-set deployment

Version `0.2.0` adds atomic, portable rule-pack deployment over the unchanged
v1 execution contract. Worker protocol `1`, outbox envelope `1`, one episode
per transaction, and the v1 support matrix remain unchanged.

## What changed since 0.1.1

- `validate_pack`, `preview_pack`, and `deploy_pack` validate an ordered JSON
  manifest, resolve environment-specific object mappings, and atomically add,
  replace, or remove immutable rule versions.
- Preview exposes generated-object changes, lifecycle risk, dependencies, and
  a digest. Deployment repeats validation under the lifecycle and DDL locks and
  rejects a stale digest before mutation.
- `DRAIN_OLD` preserves pending, retrying, and leased work on its immutable old
  binding. `CANCEL_OLD` cancels only unleased pending or retrying work.
- `pack_history` and `explain_pack` provide public deployment history and exact
  diagnostics without private identifiers.
- The same manifest can be promoted between environments using separate role,
  view, and function mappings; its definition digest remains portable.

## Upgrade from 0.1.1

The only supported in-place path is `0.1.1 -> 0.2.0`. There is no downgrade;
rollback requires restoring the tested pre-upgrade physical backup.

1. Stop workers and coordinators, verify the supported platform tuple, and take
   a tested physical backup.
2. Install the `0.2.0` control, install, and upgrade SQL files from this release
   and verify the attached archive checksum.
3. Run:

   ```sql
   ALTER EXTENSION pg_react UPDATE TO '0.2.0';
   SELECT pgreact.worker_protocol_compatible(1);
   ```

4. Reapply the explicit v1 role grants, run the documented recovery checks,
   then execute `bash tests/m5.sh ghcr.io/trickle-labs/pg-react:v0.2.0` against
   the installed artifact before resuming workers.

The migration preserves existing rules, activations, lifecycle events, agenda
work, attempts, operational settings, and recovery history. Existing rules can
continue outside a pack; adopting packs is explicit.

## Artifact and checksum publication

A complete release publishes the immutable tagged `linux/amd64` OCI image, the
`pg-react-v0.2.0-linux-amd64.tar.gz` archive, its SHA-256 manifest, the OCI
digest recorded in that manifest, these notes, and the full M5 gate result. The
tagged archive contains the extension control file, all install/upgrade SQL
through `0.2.0`, and `bin/pg-reactd` using worker protocol `1`.

## Known limitations

- Support remains PostgreSQL `18.3`, pg_trickle `0.81.0`, pgrx `0.18.0`, and
  Linux `amd64`, with coordinator-owned explicit `DIFFERENTIAL` refresh under
  `READ COMMITTED` and no RLS-protected source views.
- Recovery is physical backup, PITR, or physical failover. Logical
  `pg_dump`/`pg_restore` is not a supported live-state recovery path.
- Keys remain one non-null unique `bigint`; composite and other key codecs are
  unsupported.
- Pack dependencies define deployment order, not consequence ordering or a new
  rule language. Views and exact typed PostgreSQL functions remain canonical.
- `pg-reactd` remains a stateless one-cycle poller. Execution remains one
  episode per transaction; `0.2.0` has no audited batch path or global ordering
  guarantee.
- Outbox delivery remains at least once. Deployments own relay operation,
  consumer deduplication, monitoring, and replay.
- The release does not add immediate firing, synchronous execution, derivation,
  recursion, negation, temporal semantics, schedules, or no-code authoring.

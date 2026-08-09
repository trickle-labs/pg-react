# pg-react 0.3.0 — audited batch execution

Version `0.3.0` adds explicitly reviewed batch execution for eligible typed
database consequences. Worker protocol `1` and one episode per transaction
remain the default; protocol `2` is an explicit worker opt-in.

## What changed since 0.2.0

- `declare_batch_safe` records an immutable author assertion that one typed
  consequence binding is idempotent, commutative, and independent across
  conflict keys.
- `claim_batch` leases 2 through 32 episodes with one exact rule version,
  event, binding, execution role, recheck policy, and conflict-key definition.
- `execute_claimed_batch` rejects an invalid batch before invocation, isolates
  expected item failures, and commits successful effects, attempts, episode
  outcomes, and diagnostics atomically.
- `batch_history` and `explain_episode` expose the exact batch signature,
  selection order, attempts, failures, and outcomes without private-catalog
  access.
- `BATCH_MAX_ITEMS=2..32` opts the bundled worker into protocol `2`; removing
  it restores the unchanged protocol-1 path.

## Upgrade from 0.2.0

The only supported in-place path is `0.2.0 -> 0.3.0`. There is no downgrade;
rollback requires restoring the tested pre-upgrade physical backup.

1. Stop workers and coordinators, verify the supported platform tuple, and
   take a tested physical backup.
2. Install the `0.3.0` control, install, and upgrade SQL files from this release
   and verify the attached archive checksum.
3. Run:

   ```sql
   ALTER EXTENSION pg_react UPDATE TO '0.3.0';
   SELECT pgreact.worker_protocol_compatible(1),
          pgreact.worker_protocol_compatible(2);
   ```

4. Reapply explicit role grants, run the documented recovery checks, then run
   `bash tests/m6.sh ghcr.io/trickle-labs/pg-react:v0.3.0` against the installed
   artifact before resuming workers.

The migration preserves existing rules, packs, activations, lifecycle events,
agenda work, attempts, recovery state, and protocol-1 behavior. Existing rule
versions remain on protocol `1`; batching requires a new reviewed version and
an explicit declaration before its first lifecycle event.

## Artifact and checksum publication

A complete release publishes the immutable tagged `linux/amd64` OCI image,
the `pg-react-v0.3.0-linux-amd64.tar.gz` archive, its SHA-256 manifest, the OCI
digest recorded in that manifest, these notes, and the full M6 gate result.
The tagged archive contains extension install and upgrade SQL through `0.3.0`
and `pg-reactd` with protocols `1` and `2`.

## Known limitations

- Support remains PostgreSQL `18.3`, pg_trickle `0.81.0`, pgrx `0.18.0`, and
  Linux `amd64`, with coordinator-owned explicit `DIFFERENTIAL` refresh under
  `READ COMMITTED` and no RLS-protected source views.
- Recovery is physical backup, PITR, or physical failover. Logical
  `pg_dump`/`pg_restore` is not a supported live-state recovery path.
- Keys remain one non-null unique `bigint`; composite and other key codecs are
  unsupported.
- Batching is limited to explicitly declared `DATABASE_TYPED` bindings. It
  provides no consequence ordering, cross-episode business identity, or
  exactly-once external delivery guarantee.
- Outbox, manual, no-op, undeclared, mixed, order-dependent, and synchronous
  work cannot use the batch endpoints.
- The release does not add immediate firing, derivation, recursion, negation,
  temporal semantics, schedules, or a custom rule language.

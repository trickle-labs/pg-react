# M4 internal production pilot

The M4 pilot is an isolated production-style exercise against the exact
`pg-react:v0.1.1` `linux/amd64` image. It is executable in
[`tests/m4-pilot.sh`](../tests/m4-pilot.sh); the SQL assertions are in
[`m4-pilot.sql`](../tests/m4-pilot.sql) and
[`m4-pilot-restore.sql`](../tests/m4-pilot-restore.sql).

## Exercise

1. Install pg_trickle and pg-react in a new database, author a typed command
   rule, and execute a normal activation to completion.
2. Make the consequence fail, assert a durable terminal failure, correct the
   cause, requeue the same episode, and complete it.
3. Leave a third committed activation pending. Take a streaming physical
   backup with `pg_basebackup`, verify it with `pg_verifybackup`, archive it,
   and verify SHA-256 before and after copying it out of the primary container.
4. Restore the whole cluster into a fresh volume and a second isolated
   container running the exact same image ID and supported server settings.
   Assert preservation of rule and activation identities, lifecycle and agenda
   rows, execution history, pending work, and non-default operational settings.
5. Commit `prepare_recovery`, prove claims remain blocked, rebuild transient
   metadata, reconcile with `STATE_ONLY`, inspect health, and only then
   complete the pre-backup pending episode.
6. Insert a new fact after recovery, require a real `DIFFERENTIAL` pg_trickle
   refresh, and prove the resulting episode executes. This detects a restore
   that preserved catalog rows but lost change tracking.
7. Run the immutable-package `0.1.0 -> 0.1.1` upgrade suite and assert the
   upgraded extension and rule are present.

Cleanup removes the isolated restore container, helper, volume, archive, and
the primary Compose project even after a failed assertion.

## Result and boundary

The pilot covers the M4 installation, normal-operation, failure, physical
restore, continued-operation, and upgrade requirements. It does not claim
logical live-rule restore support. An attempted logical qualification found
that pg_trickle `0.81.0` retains stale source OIDs and lacks rebuilt
differential change tracking after `pg_restore`; the v1 contract therefore
rejects that path rather than risk silent missed work.

The final 2026-08-09 run passed `pg_verifybackup`, both archive checksum
checks, restored-state and claim-barrier assertions, metadata rebuild,
`STATE_ONLY` reconciliation, pending-work completion, the post-restore
`DIFFERENTIAL: +1 -0` transition, and the direct extension upgrade. Cleanup
left no named restore container, volume, archive, or checksum.

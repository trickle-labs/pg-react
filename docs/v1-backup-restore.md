# v1 backup and restore

The recovery promise is explicit: local database consequences are
transactional; external effects are at-least-once and may already have been
delivered when a recovery target is chosen.

## Observe

Keep the exact extension image, checksums, pg_trickle image, PostgreSQL
configuration, and WAL needed for the recovery target. Stop workers before
restoring or promoting a standby.

## Physical restore or restart

1. Restore the physical cluster backup or complete the restart.
2. Confirm PostgreSQL and extension versions.
3. Run `SELECT pgreact.doctor();` and inspect `pgreact.health`.
4. If a recovery barrier is reported, run the documented public reconciliation
   operation for each affected target.
5. Verify rules, matches, decisions, policy sets, work, attempts, leases,
   frontiers, and barriers before resuming workers.

The system must either resume authoritatively or remain claim-blocked behind
an explicit reconciliation barrier. A stale lease or worker identity must not
own work after standby promotion.

## Logical restore

Logical dump/restore is supported only when the documented rebuild and
reconciliation procedure succeeds. Object identities that cannot survive a
logical restore are rebuilt from durable names and fingerprints. Do not
pretend a restored database is ready merely because it accepts connections.

## PITR and external effects

Document the database recovery point, completed local consequences, outbox
rows, and external deliveries separately. Consumers deduplicate the stable
outbox identity. pg-react makes no exactly-once external-effect claim.

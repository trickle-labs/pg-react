# v1 backup and restore

The supported v1 recovery unit is a physical PostgreSQL cluster backup or
PITR image. It preserves application data, pg-react catalogs, pg_trickle
catalogs and change-tracking relations, local object identities, and sequence
state together.

Logical `pg_dump`/`pg_restore` of a database containing live pg-react rules is
not a supported recovery path in `0.1.1`. The pinned pg_trickle `0.81.0` does
not reconstruct restored source OIDs and differential change tracking through
its public restore APIs. A logical restore can therefore appear healthy while
later missing a lifecycle transition. Do not use a logical dump as the only
backup for a pg-react deployment.

## Create and verify a physical backup

Configure PostgreSQL archiving and retention according to your normal PITR
policy. The following `pg_basebackup` example creates a full cluster backup;
run it as a role permitted to stream a base backup:

```sh
pg_basebackup --dbname="$REPLICATION_URL" \
  --pgdata=./pgdata-backup \
  --format=plain \
  --wal-method=stream \
  --checkpoint=fast \
  --progress
pg_verifybackup ./pgdata-backup
tar -C ./pgdata-backup -czf pg-react-physical.tar.gz .
sha256sum pg-react-physical.tar.gz > pg-react-physical.tar.gz.sha256
sha256sum --check pg-react-physical.tar.gz.sha256
```

Store the backup, its WAL needed for the recovery target, checksum, exact
pg-react release artifact, and supported pg_trickle image digest together.
Exercise restoration from those stored bytes rather than relying only on
backup-job success.

## Restore into an isolated target

1. Stop every pg-react worker and coordinator that can reach the target.
2. Verify the backup checksum and `pg_verifybackup` metadata.
3. Provision the exact supported PostgreSQL 18.3/pg_trickle 0.81.0 image and
   pg-react `0.1.1` files. Restore the whole data directory while PostgreSQL is
   stopped, apply the required WAL, and start it with the settings from the
   [installation guide](v1-installation.md).
4. Keep the restored server isolated from application traffic. Confirm that
   pg_trickle's stream tables and change tracking are present before touching
   rule state.
5. As a superuser or `pgreact_admin`, block claims and verify the durable
   definitions. Run these statements in autocommit mode so the recovery
   barriers commit before reconciliation:

```sql
SELECT pgreact.prepare_recovery();
SELECT * FROM pgreact.rebuild_transient_metadata();
SELECT rule_name, rule_version_id FROM pgreact.rules ORDER BY rule_name;
```

6. For every returned version, repair state without inventing historical work:

```sql
SELECT pgreact.reconcile_rule('RULE_VERSION_UUID'::uuid, 'STATE_ONLY');
SELECT pgreact.sweep_expired_leases('RULE_VERSION_UUID'::uuid);
```

7. Resume workers only after these checks return no error rows and expected
   counts:

```sql
SELECT * FROM pgreact.health_check();
SELECT pgreact.metrics();
SELECT * FROM pgreact.operational_status ORDER BY rule_name;
```

`rebuild_transient_metadata()` resolves stored view and function identities
and verifies their fingerprints. A missing or changed object leaves that rule
claim-blocked; restore the exact object or deploy an explicit replacement.
Never patch stored OIDs or delete a recovery barrier directly.

## PITR, physical restore, failover, and promotion

Use the same claim barrier, metadata rebuild, `STATE_ONLY` reconciliation,
lease sweep, and health gate after PITR, snapshot restore, failover, or
promotion. Workers must never claim on a standby. A physical replica promoted
from the supported tuple retains the pg_trickle state needed for later
`DIFFERENTIAL` refreshes, but it still needs the pg-react recovery gate before
workers resume.

Practice this procedure with a disposable target and record row counts from
the public rule, activation, episode, and attempt views. The [operations
runbook](m3-operations.md#drift-restore-migration-and-promotion) is the
authority for incident execution.

# Upgrade

The current release is pg-react `0.44.0`. The adjacent upgrade is from
`0.43.3`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.44.0';
SELECT extname, extversion FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle') ORDER BY extname;
SELECT pgreact.doctor();
```

Back up first and quiesce application writes and managed workers while taking
the stopped-cluster physical backup. After the update, verify the extension
version, complete state snapshot, and `pgreact.doctor()` before resuming.
The migration records accurate work activity timestamps for new transitions;
pre-upgrade agenda history remains NULL when its transition time is unknown.
Existing JSON-preconditions calls and specialized APIs remain available.
See [Backup and Restore](backup-restore.md) for rollback.

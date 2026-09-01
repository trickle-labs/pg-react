# Upgrade

The current release is pg-react `0.43.1`. The adjacent upgrade is from
`0.43.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.43.1';
SELECT extname, extversion FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle') ORDER BY extname;
SELECT pgreact.doctor();
```

Back up first, drain or explicitly cancel old command work before replacing
rules, and run the M54 qualification corpus in a staging database. The
migration is additive: existing JSON-preconditions calls and specialized APIs
remain available. See [Backup and Restore](backup-restore.md) for rollback.

# Upgrade to pg-react 0.12.0

1. Stop `pg-reactd` and managed claims, then take and verify a physical backup.
2. Install the `0.12.0` library, control file, and upgrade SQL.
3. Run `ALTER EXTENSION pg_react UPDATE TO '0.12.0';` alone.
4. Configure the five facade roles, preload `pg_trickle,pg_react`, set
   `pg_react.databases`, and restart PostgreSQL.
5. Require `pgreact_api.doctor()` to report `ready`, then retire external workers.

Pending protocol-compatible work is drained through the inherited claim and
lease contract. Do not run old and new extension libraries in one cluster.
Rollback is restoring the verified pre-upgrade backup; SQL downgrade is not
supported.

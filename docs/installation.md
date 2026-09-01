# Installation

The current release is pg-react `0.43.1`. It runs inside PostgreSQL 18.3 with
pg_trickle 0.81.0 and the PostgreSQL-managed runtime.

For the container image, use `ghcr.io/trickle-labs/pg-react:v0.43.1` or set
`PG_REACT_IMAGE=pg-react:0.43.1` in the repository’s Compose setup. In a
PostgreSQL installation with the extension files available, run:

```sql
CREATE EXTENSION pg_react VERSION '0.43.1';
```

Set these PostgreSQL settings before starting the managed runtime:

```conf
shared_preload_libraries = 'pg_trickle,pg_react'
pg_trickle.user_triggers = 'auto'
pg_trickle.enabled = off
pg_trickle.differential_max_change_ratio = 1.0
default_transaction_isolation = 'read committed'
pg_react.databases = 'appdb'
pg_react.worker_role = 'pgreact_worker_login'
pg_react.poll_interval_ms = 1000
pg_react.batch_size = 32
pg_react.max_pending_jobs = 10000
```

Create the worker role, grant it `CONNECT` and the configured worker group,
then configure application roles with `pgreact_api.configure_roles`. Restart
PostgreSQL after changing `shared_preload_libraries`, `pg_react.databases`, or
`pg_react.worker_role`. The polling, batch, and pending-work settings are
reloadable.

Install pg_trickle before pg-react in each configured database:

```sql
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
```

Verify both extensions and the managed worker with
`SELECT extname, extversion FROM pg_extension`, `SELECT pgreact.doctor()`, and
`SELECT pgreact_api.managed_status()`.

The [current release manifest](current-release.json) is the source for the
versions used by the qualification workflow. Historical installation records
remain available from [History](history.md).

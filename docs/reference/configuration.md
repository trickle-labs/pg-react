# Configuration reference

[Reference](index.md) · [Installation](../installation.md)

These settings describe the PostgreSQL-managed runtime used by the qualified pg-react 0.46.0 core profile. PostgreSQL starts a worker per configured database; the worker coordinates changes and executes eligible durable work. The declarations themselves remain in the database, so changing a worker setting is an operational change rather than a policy deployment.

## Managed worker settings

| Setting | Default | Allowed value | Apply with |
| --- | --- | --- | --- |
| `pg_react.databases` | Unset | Comma-separated database names; empty disables configured workers. Duplicate and empty entries are ignored. | PostgreSQL restart |
| `pg_react.worker_role` | `postgres` | A role able to connect and perform managed work in every configured database. | PostgreSQL restart |
| `pg_react.poll_interval_ms` | `1000` | `10`–`60000` milliseconds | Configuration reload |
| `pg_react.batch_size` | `32` | `1`–`1000`; must also fit the operational `max_claims` setting. | Configuration reload |
| `pg_react.max_pending_jobs` | `10000` | `1`–`2147483647` | Configuration reload |

At the pending-job threshold, the managed worker continues draining existing work while pausing further coordination. Increasing the threshold does not increase consequence throughput by itself; inspect backlog and attempts before tuning it. A smaller polling interval changes how often the worker checks for work, not the transaction semantics or delivery guarantee.

`shared_preload_libraries` must include both `pg_trickle` and `pg_react` and requires a restart. The built-in worker-role default is convenient for the disposable tutorial; configure a dedicated worker role for an application deployment.

## Qualified upstream and transaction settings

| Setting | R0 value | Purpose |
| --- | --- | --- |
| `pg_trickle.cdc_mode` | `trigger` | Qualified source change-capture mode. |
| `pg_trickle.user_triggers` | `auto` | Supported trigger behavior. |
| `pg_trickle.enabled` | `off` | Keeps independent pg_trickle scheduling disabled. |
| `pg_trickle.differential_max_change_ratio` | `1.0` | Qualified differential-refresh configuration. |
| `default_transaction_isolation` | `read committed` | Qualified isolation level. |

Stable upstream Graph and Delta capabilities do not imply that pg-react uses them in this release. The R0 profile retains explicit pg-react coordination. Independent refresh scheduling and WAL CDC are outside this profile.

## Compose environment variables

These variables configure the repository's Compose service, not the SQL declaration API.

| Variable | Repository default | Meaning |
| --- | --- | --- |
| `PG_REACT_IMAGE` | `pg-react:0.46.0` | Image name used for the PostgreSQL service. Use the published GHCR name to pull a release. |
| `PG_REACT_INIT_VERSION` | `0.46.0` | Extension version created by the fresh-data-directory initializer. It does not update an existing database. |
| `PG_REACT_PLATFORM` | `linux/amd64` | Container platform. |
| `PG_REACT_PORT_BINDING` | `127.0.0.1::5432` | Bind PostgreSQL to a random host loopback port. |
| `PG_REACT_POLL_INTERVAL_MS` | `1000` | Compose value for the polling GUC. |
| `PG_REACT_BATCH_SIZE` | `32` | Compose value for the batch-size GUC. |
| `PG_REACT_MAX_PENDING_JOBS` | `10000` | Compose value for the pending-job GUC. |
| `COMPOSE_PROJECT_NAME` | Chosen by Compose | Isolates container and volume names for a learning or test project. |

Use `docker compose port postgres 5432` to discover the assigned host port, or use `docker compose exec postgres psql -X -U postgres -d postgres` inside the service. The Compose database is named `postgres` and has a persistent `postgres-data` volume; restarting a container does not reset its database.

## Inspect effective values

```sql
SHOW shared_preload_libraries;
SHOW pg_react.databases;
SHOW pg_react.worker_role;
SHOW pg_react.poll_interval_ms;
SHOW pg_react.batch_size;
SHOW pg_react.max_pending_jobs;
SELECT pgreact_api.managed_status();
SELECT pgreact.doctor();
```

Use the [operations guide](../operations.md) to interpret unhealthy workers and backlog. For implementation evidence, the runtime settings are registered in [src/managed.rs](../../src/managed.rs), and the learning defaults live in [docker-compose.yml](../../docker-compose.yml).

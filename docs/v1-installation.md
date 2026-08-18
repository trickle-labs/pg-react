# v1 installation

The published `0.31.0` package contains the v1 feature set. The qualified
support tuple is PostgreSQL 18.3, pg_trickle 0.81.0, and Linux amd64. Other
versions, operating systems, and architectures are not qualified.

## Install the package

Use `ghcr.io/trickle-labs/pg-react:v0.31.0` by the digest recorded in the
release `pg-react-v0.31.0.SHA256SUMS` file. Verify the release checksum and
attestation before loading the image. For a local build of this checkout:

```sh
docker compose build postgres
docker compose up -d postgres
docker compose exec -T postgres pg_isready -U postgres
```

The image contains PostgreSQL 18.3, pg_trickle 0.81.0, and pg-react 0.31.0.
pg-react was built with pgrx 0.18.0 and Rust 1.89.0; those are build facts, not
additional user-facing compatibility promises.

## Create the roles

Create four application group roles and the separate advanced reader. A
managed worker login may inherit the worker group:

```sql
CREATE ROLE pgreact_author NOLOGIN;
CREATE ROLE pgreact_operator NOLOGIN;
CREATE ROLE pgreact_worker NOLOGIN;
CREATE ROLE pgreact_reader NOLOGIN;
CREATE ROLE pgreact_advanced_reader NOLOGIN;

CREATE ROLE pgreact_worker_login LOGIN;
GRANT pgreact_worker TO pgreact_worker_login;
GRANT CONNECT ON DATABASE appdb TO pgreact_worker_login;
```

Create application login roles separately and grant only the group membership
they require. There is no installed deployer role.

## Configure PostgreSQL

Set the following values before starting the managed runtime:

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

`pg_react.databases` is a comma-separated list. PostgreSQL starts one managed
worker for each unique, non-empty configured database. Changing
`shared_preload_libraries`, `pg_react.databases`, or `pg_react.worker_role`
requires a PostgreSQL restart. The polling, batch, and pending-work settings
are reloadable.

The installed bounds are:

- `pg_react.poll_interval_ms`: default `1000`, range `10..60000`;
- `pg_react.batch_size`: default `32`, range `1..1000`;
- `pg_react.max_pending_jobs`: default `10000`, minimum `1`.

Restart PostgreSQL after changing the preload, database list, or worker role.
Merely reloading the configuration does not start or replace managed workers.

## Enable each database

Connect as a superuser and install pg_trickle before pg-react:

```sql
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;

SELECT pgreact_api.configure_roles(
  'pgreact_author',
  'pgreact_operator',
  'pgreact_worker',
  'pgreact_reader',
  'pgreact_advanced_reader'
);
```

`pg_react` is not trusted and requires superuser installation.

Fresh 0.31.0 installation has a grant-order defect: the M34 comparison
functions grant configured roles only while the extension script is running.
After `configure_roles`, apply the intended grants explicitly:

```sql
GRANT EXECUTE ON FUNCTION
  pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb),
  pgreact.compare_results(pgreact_api.declaration, pgreact_api.target, jsonb)
TO pgreact_author, pgreact_operator, pgreact_reader;
```

The RC package must fold these grants into `configure_roles`.

## Verify the environment

Run these checks in every configured database:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;

SHOW server_version;
SHOW shared_preload_libraries;
SHOW pg_trickle.user_triggers;
SHOW pg_trickle.enabled;
SHOW pg_trickle.differential_max_change_ratio;
SHOW default_transaction_isolation;
SHOW pg_react.databases;
SHOW pg_react.worker_role;
SHOW pg_react.poll_interval_ms;
SHOW pg_react.batch_size;
SHOW pg_react.max_pending_jobs;

SELECT pgreact_api.worker_protocol_compatible(2);
SELECT pgreact.doctor();
SELECT pgreact_api.managed_status();
```

Expect PostgreSQL `18.3`, pg_trickle `0.81.0`, pg-react `0.31.0`, worker
protocol `2`, `doctor` state `ready`, and a managed status with
`configured = true`. After the first poll, the process should report protocol
`2` and state `ready`.

## Supported refresh and worker behavior

The supported runtime is PostgreSQL-managed polling. Each cycle coordinates
an explicit pg-react run, then claims and executes durable work. Keep
pg_trickle's scheduler off (`pg_trickle.enabled = off`), leave user triggers
at `auto`, and keep the differential change ratio at `1.0`. Independent
pg_trickle scheduling or other uncoordinated refreshes are unsupported.

`pg-reactd` is a one-shot compatibility bridge, not the primary runtime. Each
invocation calls `pgreact_api.run()` and can therefore create work before it
claims and executes work; it is not drain-only. Use it only for migration or
compatibility procedures that explicitly require it.

## RC packaging blocker

`src/managed.rs` runs managed cycles only when the installed extension version
is the literal `0.31.0`. An RC or GA extension with another version string
would load the worker but never run `managed_cycle()`. This must be fixed and
qualified before publishing `1.0.0-rc.1`.

Use the [current operations runbook](v1-operations.md) for backlog, recovery,
retention, and worker procedures.

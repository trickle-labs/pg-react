# Install and configure pg-react

[How-to guides](how-to/index.md) · [Configuration reference](reference/configuration.md)

This guide installs the qualified **pg-react 0.46.0 core profile**: PostgreSQL **18.3**, pg_trickle **0.108.0**, Linux **amd64**, and PostgreSQL-managed workers. Start with [Your first rule](getting-started.md) if you want a disposable local environment. Use the procedure below when you are configuring a server that will host your application, and check the [support matrix](support-matrix.md) before substituting versions or runtime settings.

## Choose the package deliberately

The published core container is `ghcr.io/trickle-labs/pg-react:v0.46.0`. Use the [0.46.0 core release](https://github.com/trickle-labs/pg-react/releases/tag/v0.46.0) to find the packaged files, checksums, and image evidence; pin the recorded artifact digest when deploying it and retain it with your recovery materials. The repository's Compose setup is a convenient learning environment, but its default password, superuser worker, and persistent local volume should be adapted to your deployment's normal PostgreSQL practices.

A checkout can contain more than one extension SQL version. In this tree, `pg_react.control` defaults to `0.46.2`, while the qualified core manifest and Compose initializer select `0.46.0`. Always name the version you intend to install. [Versions and release identity](reference/release-identity.md) explains why a plain `CREATE EXTENSION pg_react` can give a different result from the learning environment.

For a local source build using this checkout's Dockerfile, choose a distinct image name and retain the explicit initialization version:

```bash
export PG_REACT_IMAGE=pg-react:local-source
export PG_REACT_INIT_VERSION=0.46.0
docker compose build postgres
docker compose up -d --wait --no-build postgres
```

That builds the checked-out source; it does not turn a local build into the published release artifact. Compose initialization runs only for a fresh data directory. To update an existing database, follow [Upgrade](upgrade.md).

## 1. Prepare the server without starting managed work

Install the matching PostgreSQL, pg_trickle, and pg-react packages or image. Set the following PostgreSQL configuration, leaving the managed database list empty while you create roles and install the extension. The existing server's other preload libraries must remain in the list as well.

```conf
shared_preload_libraries = 'pg_trickle,pg_react'
pg_trickle.cdc_mode = 'trigger'
pg_trickle.user_triggers = 'auto'
pg_trickle.enabled = off
pg_trickle.differential_max_change_ratio = 1.0
default_transaction_isolation = 'read committed'
pg_react.databases = ''
```

Restart PostgreSQL after setting the preload libraries. The R0 profile uses trigger change capture and explicit pg-react refresh coordination, so keep pg_trickle's independent scheduler off. Loading an extension into a running database does not by itself start a managed worker for that database.

## 2. Create the database and roles

In the examples, the application database is `appdb`. Create it if it does not exist, then create the following role groups as a PostgreSQL administrator. Choose names that fit your deployment and keep the corresponding configuration call consistent.

```sql
CREATE DATABASE appdb;

CREATE ROLE pgreact_author NOLOGIN;
CREATE ROLE pgreact_operator NOLOGIN;
CREATE ROLE pgreact_worker NOLOGIN;
CREATE ROLE pgreact_reader NOLOGIN;
CREATE ROLE pgreact_advanced_reader NOLOGIN;

CREATE ROLE pgreact_worker_login LOGIN;
GRANT pgreact_worker TO pgreact_worker_login;
GRANT CONNECT ON DATABASE appdb TO pgreact_worker_login;
```

Create application logins separately, configure authentication using your normal PostgreSQL process, and grant only the group memberships each login needs. Authors, operators, workers, and readers have different responsibilities; giving a reader worker authority is not necessary to inspect status. The [security guide](security.md) explains ownership and source-access requirements in more detail.

## 3. Enable the extensions and configure privileges

Connect to `appdb` as a superuser. pg-react is an untrusted extension and requires superuser installation. Install pg_trickle first, then explicitly select the core version used by this guide:

```sql
CREATE EXTENSION pg_trickle VERSION '0.108.0';
CREATE EXTENSION pg_react VERSION '0.46.0';

SELECT pgreact_api.configure_roles(
    'pgreact_author',
    'pgreact_operator',
    'pgreact_worker',
    'pgreact_reader',
    'pgreact_advanced_reader'
);
```

Repeat extension installation and role configuration in each application database that will run pg-react. The role names are cluster-wide, while the extension's objects and configured role mapping belong to a database. Do not create a second copy of a role that already exists.

## 4. Enable the managed worker

After the database and role mapping are ready, set the managed runtime configuration. The worker role must be able to connect to every listed database and have the configured worker privileges in each one.

```conf
pg_react.databases = 'appdb'
pg_react.worker_role = 'pgreact_worker_login'
pg_react.poll_interval_ms = 1000
pg_react.batch_size = 32
pg_react.max_pending_jobs = 10000
```

Restart PostgreSQL to apply the database list and worker role. PostgreSQL starts one managed worker for each unique nonempty database entry. Changes to the polling interval, batch size, and pending-job threshold need a configuration reload rather than a restart; their exact defaults and bounds are in the [configuration reference](reference/configuration.md).

## 5. Verify the installation

Run these checks in each configured application database after the first worker poll:

```sql
SELECT current_setting('server_version') AS postgres_version;
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;

SHOW shared_preload_libraries;
SHOW pg_trickle.cdc_mode;
SHOW pg_trickle.enabled;
SHOW default_transaction_isolation;
SHOW pg_react.databases;
SHOW pg_react.worker_role;

SELECT pgreact_api.worker_protocol_compatible(2);
SELECT pgreact.doctor();
SELECT pgreact_api.managed_status();
```

Expect PostgreSQL `18.3`, pg_trickle `0.108.0`, pg-react `0.46.0`, compatible worker protocol `2`, a doctor state of `ready`, and a configured managed process in `ready` state. If a check fails, inspect the reported finding and use [Troubleshooting](troubleshooting.md); a successful `CREATE EXTENSION` alone does not establish that the runtime is healthy.

You can now create application-owned condition views and consequence functions, then validate and deploy declarations as the authorized author. Continue with [Authoring rules and policies](authoring.md). The external `pg-reactd` program remains a compatibility path; its invocation can coordinate new work as well as drain work, so it should not be started alongside the normal managed coordinator as a second scheduler.

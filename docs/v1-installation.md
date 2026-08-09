# v1 installation

pg-react v1 is extension version `0.1.1` and worker protocol `1`. Its supported runtime is the exact `linux/amd64` tuple in the [v1 contract](v1-contract.md) and [compatibility matrix](m3-compatibility.md): PostgreSQL 18.3 with pg_trickle 0.81.0, scheduler disabled, explicit `DIFFERENTIAL` refreshes, and `READ COMMITTED` transactions.

## Install the supported image

Use the versioned release image by digest and verify the supplied SHA-256 checksum before starting it. For local validation of this checkout's pinned Dockerfile:

```sh
docker compose build postgres
docker compose up -d postgres
docker compose exec -T postgres pg_isready -U postgres
```

The Compose settings are part of the support contract:

```conf
shared_preload_libraries = 'pg_trickle'
pg_trickle.user_triggers = 'auto'
pg_trickle.enabled = off
pg_trickle.differential_max_change_ratio = 1.0
default_transaction_isolation = 'read committed'
```

Do not substitute another PostgreSQL, pg_trickle, OS, or architecture version without its own compatibility evidence. macOS is supported only as a Docker host.

## Enable a database

The Compose initialization enables both extensions in its initial `postgres` database. For each additional database, connect as a superuser and install pg_trickle first:

```sql
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
```

`pg_react` is not a trusted extension and requires superuser installation. Application roles should not remain superusers; configure them using the [security guide](v1-security.md).

## Verify the install

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;

SHOW server_version;
SHOW pg_trickle.enabled;
SHOW pg_trickle.user_triggers;
SHOW pg_trickle.differential_max_change_ratio;
SHOW default_transaction_isolation;

SELECT pgreact.worker_protocol_compatible(1);
SELECT * FROM pgreact.health_check();
```

Expected results are pg-react `0.1.1`, pg_trickle `0.81.0`, PostgreSQL `18.3`, settings `off`, `auto`, `1`, and `read committed`, protocol compatibility `true`, and no error health rows.

## Run work

Create a rule using the [authoring guide](v1-authoring.md), then invoke the supplied worker with separate least-privilege connections:

```sh
DATABASE_URL='postgresql://pgreact_worker:secret@db/app' \
COORDINATOR_DATABASE_URL='postgresql://pgreact_operator:secret@db/app' \
MAX_CLAIMS=10 \
./bin/pg-reactd 'RULE_VERSION_UUID' 'worker-1'
```

One invocation performs one coordinated refresh, claims up to `MAX_CLAIMS`, executes each claimed episode in its own transaction, then exits. Run it repeatedly under your existing service scheduler. Do not enable pg_trickle's automatic scheduler for command rules or call an uncoordinated refresh.

Use the [operations runbook](m3-operations.md) for health, backlog, recovery, retention, and worker procedures.

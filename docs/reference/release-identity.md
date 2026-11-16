# Versions and release identity

[Reference](index.md) · [Support matrix](../support-matrix.md)

pg-react's repository contains a core extension, its Rust runtime package, and optional integration work. They have different version numbers because they are different artifacts. When deciding what to install or which instructions to follow, begin with the installed extension version and the release profile, then identify the matching runtime artifact and dependencies.

## The version numbers in this checkout

| Identity | Value recorded here | What it describes |
| --- | --- | --- |
| Qualified core learning profile | `0.46.0` / R0 | The profile in [current-release.json](../current-release.json), used by the main user guides. |
| PostgreSQL and pg_trickle for R0 | `18.3` and `0.108.0` | The qualified core dependency tuple. |
| Core extension default in the source tree | `0.46.2` | `default_version` in [pg_react.control](../../pg_react.control); plain extension creation uses this package default. |
| Rust package | `0.48.0` | The build package version in [Cargo.toml](../../Cargo.toml), not the installed SQL extension version. |
| Compose initialization version | `0.46.0` | The fresh-database choice in [docker-compose.yml](../../docker-compose.yml) and the Dockerfile. |
| Optional MDM adapter | `0.50.0` synthetic demo release | Separately versioned integration artifacts; this is not a production-supported real-workload release. |

A maintenance SQL file or a successful focused integration test does not automatically qualify a new core deployment profile. Conversely, a separately numbered MDM adapter release does not mean the core extension has that same number. The R0 learning path keeps the optional MDM adapter disabled, as recorded in its release manifest. The separately published [0.50.0 adapter release](https://github.com/trickle-labs/pg-react/releases/tag/v0.50.0) is a synthetic demonstration with `release_qualified: false`; it does not support real workloads or live operator effects. Use its [synthetic local exercise](../v0.50.0-operations.md#synthetic-local-exercise) only within that stated boundary.

## Check what is actually installed

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_react', 'pg_trickle')
ORDER BY name;
```

`pg_extension.extversion` describes the database you are using. The available default describes what a new `CREATE EXTENSION` would select from the files installed on that server. Neither a container tag nor Cargo's package version replaces those checks.

## Select the core learning profile explicitly

For a new database with the appropriate files installed, the guide uses:

```sql
CREATE EXTENSION pg_trickle VERSION '0.108.0';
CREATE EXTENSION pg_react VERSION '0.46.0';
```

For Compose, set `PG_REACT_INIT_VERSION=0.46.0` before the first initialization. The initializer does not alter an existing extension when a persistent data directory is reused. Use [Upgrade](../upgrade.md) for an existing installation, and retain exact package checksums and configuration with your [backup](../backup-restore.md).

## Read historical material in context

The prepared 1.0 work is not the current release; the [current manifest](../current-release.json) records it as postponed. Older milestone pages remain available because they explain implementation decisions and retain qualification evidence. Read them through [History](../history.md), and check their inputs and version against your installed system before using a specialized API or recovery procedure.

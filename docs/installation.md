# Installation

The current release is pg-react `0.43.0`. It runs inside PostgreSQL 18.3 with
pg_trickle 0.81.0 and the PostgreSQL-managed runtime.

For the container image, use `ghcr.io/trickle-labs/pg-react:v0.43.0` or set
`PG_REACT_IMAGE=pg-react:0.43.0` in the repository’s Compose setup. In a
PostgreSQL installation with the extension files available, run:

```sql
CREATE EXTENSION pg_react VERSION '0.43.0';
```

Configure the database in `pg_react.databases`, configure application roles
with `pgreact_api.configure_roles`, and restart PostgreSQL. Verify both
extensions with `SELECT extname, extversion FROM pg_extension` and check
`SELECT pgreact.doctor();`.

The [current release manifest](current-release.json) is the source for the
versions used by the qualification workflow. Historical installation records
remain available from [History](history.md).

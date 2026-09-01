# Upgrade to pg-react 0.41.0

M44 upgrades the extension from `0.40.0` to `0.41.0`.

1. Back up the database.
2. Install the `0.41.0` library, control file, SQL files, and worker image.
3. Run the upgrade by itself:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.41.0';
```

The upgrade script is a no-op. Existing declarations, explanations, decisions,
work, snapshots, retention rows, and digests remain unchanged. M44 changes the
documented qualification of existing answers, not the answers themselves.

There is no in-place downgrade. To roll back, stop clients, restore a verified
`0.40.0` backup, install the `0.40.0` files, and check the extension version:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_react';
```

The expected restored value is `0.40.0`.

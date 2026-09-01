# Backup and Restore

The current release is pg-react `0.43.0`. Back up the PostgreSQL database and
the extension/container artifact together. Restore the database before
starting managed workers, verify `pg_extension.extversion`, then run
`pgreact.doctor()` and inspect the affected names.

For a rollback from `0.43.0`, restore a verified `0.42.0` backup and install
the matching `0.42.0` artifact. Do not mix extension SQL, container versions,
or pg_trickle versions across a restore. External consumers should resume from
their durable idempotency position.

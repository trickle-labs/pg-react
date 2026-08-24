# Upgrade to pg-react 0.11.0

1. Stop coordinators and workers and verify the physical backup.
2. Install the `0.11.0` library, control file, worker, and upgrade SQL.
3. Run `ALTER EXTENSION pg_react UPDATE TO '0.11.0';` alone.
4. Call five-argument `pgreact_api.configure_roles`.
5. Confirm `pgreact_api.doctor()` is ready, then resume.

The upgrade adds façade functions and the advanced-reader grant map. It preserves all durable M0–M13 rows; rollback is restoring the verified `0.10.0` physical backup.


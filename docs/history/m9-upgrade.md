# Upgrade to pg-react 0.6.0

The only supported in-place path is `0.5.0 -> 0.6.0`. There is no downgrade;
rollback requires the tested pre-upgrade physical backup.

1. Stop workers and coordinators, resolve health errors, and take a verified
   physical backup.
2. Install the `0.6.0` shared library, control, install, and upgrade SQL files
   on every server.
3. Run `ALTER EXTENSION pg_react UPDATE TO '0.6.0';` by itself with
   `ON_ERROR_STOP` enabled.
4. Reapply explicit grants from `docs/v1-security.md`, run
   `pgreact.prepare_recovery()`, rebuild transient metadata, and reconcile each
   active rule and derivation program.
5. Require no error rows from `pgreact.health_check()`, then run
   `tests/m9.sh ghcr.io/trickle-labs/pg-react:v0.6.0` before resuming work.

The migration preserves M0-M8 catalogs and state. Existing positive programs
receive positive graph edges in stratum zero; negative inputs and evidence start
empty. `tests/m9-upgrade.sql` freezes the exact direct-upgrade result.

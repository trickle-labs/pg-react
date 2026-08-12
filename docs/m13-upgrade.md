# Upgrade to pg-react 0.10.0

The supported M13 upgrade is `0.9.0 -> 0.10.0`; there is no downgrade.

1. Stop every coordinator and worker.
2. Take and verify the documented physical backup.
3. Install the `0.10.0` library, control file, worker, and
   `pg_react--0.9.0--0.10.0.sql`.
4. Run `ALTER EXTENSION pg_react UPDATE TO '0.10.0';` alone.
5. Call `configure_roles` with four existing distinct deployment roles; this
   removes stale facade-wide grants from that role set and applies the exact
   object matrix.
6. Verify `health()`, the populated rules and pending jobs, one dry repeated
   `run`, and worker protocol compatibility before resuming.

The migration adds only facade functions and the private configured-role map.
It preserves rules, bindings, activations, lifecycle events, jobs, leases,
attempts, packs, programs, frontiers, facts, supports, provenance, deadline and
clock state, and pending work byte-for-byte. Existing exact context-aware
bindings remain unchanged. New context-free bindings use the same immutable
digest and dispatcher checks.

Rollback means restoring the verified `0.9.0` physical backup. Do not install
old binaries over a migrated database.

# Upgrade to pg-react 0.7.0

The supported in-place M10 upgrade is `0.6.0 -> 0.7.0`; there is no downgrade.

1. Stop workers and finish or recover the current `0.6.0` refresh.
2. Install the `0.7.0` library, control file, install script, and upgrade script.
3. Run `ALTER EXTENSION pg_react UPDATE TO '0.7.0';` by itself.
4. Resume with `pgreact.refresh_derivation_program` or
   `pgreact.reconcile_derivation_program` for an aggregate program.

The upgrade adds only empty aggregate-input and aggregate-evidence catalogs.
It preserves programs, components, frontiers, facts, supports, negative
evidence, provenance, and lifecycle state. `tests/m10-upgrade.sql` first runs
the exact M9 upgrade fixture, snapshots its complete visible M9 state, upgrades
to `0.7.0`, and requires byte-exact preservation before any aggregate program
is deployed.

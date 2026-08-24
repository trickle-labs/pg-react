# Upgrade to pg-react 0.8.0

The supported in-place M11 upgrade is `0.7.0 -> 0.8.0`. There is no downgrade.

1. Stop workers and finish or recover the current `0.7.0` refreshes and leases.
2. Take the tested physical backup used for rollback.
3. Install the `0.8.0` library, control file, install script, and upgrade script.
4. Run `ALTER EXTENSION pg_react UPDATE TO '0.8.0';` by itself.
5. Resume workers using the documented M11 workflow and migrate application SQL
   to `pgreact_api` according to the replacement matrix.

The upgrade preserves durable state and pending work. `pgreact_api` is the
public compatibility contract starting in `0.8.0`; `0.7.0` names remain only
where the replacement matrix explicitly bridges them. Do not treat any
remaining `pgreact` object as a new integration point.

The supported PostgreSQL, pg_trickle, pgrx, OS, architecture, isolation, RLS,
key-codec, physical-recovery, worker-protocol, resource-limit, and
external-effect boundaries are unchanged from `0.7.0`.

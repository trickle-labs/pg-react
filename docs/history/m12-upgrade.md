# Upgrade to pg-react 0.9.0

The supported M12 upgrade is `0.8.0 -> 0.9.0`; there is no downgrade.

1. Stop every coordinator and worker.
2. Take and verify the documented physical backup.
3. Install the `0.9.0` library, control file, worker, and
   `pg_react--0.8.0--0.9.0.sql`.
4. Run `ALTER EXTENSION pg_react UPDATE TO '0.9.0';` alone.
5. Verify `pgreact_api.health()` and the existing M11 rules and pending work.
6. Deploy deadline rules, then resume the `0.9.0` worker.

The upgrade preserves every M11 rule, binding, activation, lifecycle event,
agenda item, lease, attempt, pack, derivation, fact, support, provenance,
stratum, evidence row, and history row byte-for-byte. It initializes the M12
clock at negative infinity and creates no temporal event during upgrade.
Already-overdue candidates become due on the first successful coordinator
pass after their deadline rule is deployed.

Rollback means restoring the verified `0.8.0` physical backup. Do not install
old binaries over a migrated database.

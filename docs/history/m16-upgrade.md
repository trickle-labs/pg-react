# Upgrade to pg-react 0.13.0

1. Stop managed and external claims, then take and verify a physical backup.
2. Install the `0.13.0` library, control file, and upgrade SQL.
3. Run `ALTER EXTENSION pg_react UPDATE TO '0.13.0';` alone.
4. Require `pgreact_api.doctor()` to report `ready`, then resume workers.
5. Validate or deploy typed aggregate declarations and compare the captured
   public facts, supports, evidence, and explanations.

The supported in-place upgrade is `0.12.0 -> 0.13.0`. Existing `COUNT(*)`
declarations and durable state are preserved; typed aggregate metadata is
additive until a typed declaration is deployed. Do not run old and new
extension libraries in one cluster. Rollback is restoring the verified backup;
SQL downgrade is unsupported.

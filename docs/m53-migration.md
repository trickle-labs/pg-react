# Upgrade to 0.42.0

The supported adjacent upgrade is `0.41.0` to `0.42.0`.

1. Back up the database and record the current extension version.
2. Install the `0.42.0` image or package.
3. Run:

   ```sql
   ALTER EXTENSION pg_react UPDATE TO '0.42.0';
   ```

4. Run the release qualification script and inspect the package catalog.
5. Deploy new policy packages with preview plus a plan-digest precondition.

The migration adds package metadata and two read-only catalog views. Existing
rules, decisions, policy sets, work, evidence, and public compatibility
functions remain in place.

Rollback is restore-based: restore the verified `0.41.0` backup and reinstall
the `0.41.0` image. Do not delete package rows by hand.

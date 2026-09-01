# Upgrade from pg-react 0.43.0 to 0.43.1

The supported adjacent update is `0.43.0 -> 0.43.1`.

1. Take and verify a PostgreSQL backup that can be restored as `0.43.0`.
2. Install the `0.43.1` extension artifact and run:

   ```sql
   ALTER EXTENSION pg_react UPDATE TO '0.43.1';
   ```

3. Verify `pg_extension.extversion`, `pgreact.doctor()`, and the managed
   worker state before using the new ordinary facade.

The update installs additive wrappers and public dispatch fixes. It does not
replace deployments, cancel or retry work, reconcile state, change source or
parameter rows, alter application relations, or remove compatibility APIs.

Rollback is restore-based: stop managed activity as documented, restore the
verified `0.43.0` backup, reinstall the matching `0.43.0` artifact, and verify
before resuming service. Do not assume an extension downgrade is qualified.

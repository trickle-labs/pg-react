# Upgrade to pg-react 0.14.0

1. Stop managed and external claims.
2. Export each windowed program with
   `pgreact_api.export_window_state(program_name)` and take a verified physical
   backup.
3. Install the `0.14.0` library, control file, and upgrade SQL.
4. Run `ALTER EXTENSION pg_react UPDATE TO '0.14.0';` alone.
5. Require `pgreact_api.doctor()` to report `ready`, compare inherited public
   facts and evidence, then resume workers.

The supported in-place path is `0.13.0 -> 0.14.0`. Existing unwindowed M16
programs gain no window, watermark, correction, or finalization state. Window
declarations are additive after upgrade. Rollback is restore of the verified
pre-upgrade physical backup; SQL downgrade is unsupported.

# M27 upgrade

The planned supported direct upgrade is `0.23.0 -> 0.24.0`.

Install the `0.24.0` extension files, then run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.24.0';
```

The upgrade must preserve M26 decision programs, versions, candidates,
winners, ambiguities, lifecycle state, pending work, grants, provenance,
diagnostics, retention behavior, and coordinator operation. It must add the
storage and public structures needed for M27 analyses without inventing an
analysis, population, candidate catalog, finding, or deployment admission.

Existing rules and decision programs continue unchanged until an operator
explicitly declares and runs an analysis. A proposed deployment must use the
analysis result and its complete-frontier fingerprints; stale or blocking
results must prevent durable mutation.

Before upgrading, take the normal verified backup and confirm the M26 release
artifacts and direct-upgrade evidence. After upgrading, run the complete M27
gate and inspect analysis status, history, findings, evidence, distributions,
grants, retention, and recovery for the reference programs.

Downgrade is not a supported release path. Restore the pre-upgrade backup if a
rollback is required.

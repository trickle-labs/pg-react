# M26 upgrade

The supported direct upgrade is `0.22.0 -> 0.23.0`.

Install the `0.23.0` extension files, then run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.23.0';
```

The upgrade preserves existing M25 parameter families, policy versions,
frontiers, lifecycle state, pending work, grants, provenance, diagnostics,
retention behavior, and coordinator operation. It creates the M26 decision
program, candidate, winner, lifecycle, evidence, and public API storage needed
for new declarations; it does not invent a decision program, candidate, or
winner for an existing policy.

Existing rules and parameterized policies continue unchanged until an operator
explicitly declares and deploys a decision-program version through the public
API. Deploying or replacing a decision version is atomic, so readers never see
mixed-version winners.

Before upgrading, take the normal verified backup and confirm the M25 release
artifacts and direct-upgrade evidence. After upgrading, run the complete M26
gate and inspect status, history, preview, explanation, grants, retention, and
recovery for the reference decision programs.

Downgrade is not a supported release path. Restore the pre-upgrade backup if a
rollback is required.

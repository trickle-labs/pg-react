# M30 upgrade

The supported direct upgrade is `0.26.0 -> 0.27.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.27.0';
```

The migration preserves existing policy-set and declaration identities,
eligibility evidence, and M29 metadata. Existing delegated declarations are
classified as `GLOBAL`; metadata-only declarations are `LEGACY_METADATA`; and
existing M29 policy sets are `NEEDS_SCOPE_MIGRATION`.

The upgrade does **not** silently enable policy-set gating, create scope
supports, activate or withdraw matches, create work, or invent runtime
objects. To opt into the M30 contract, declare a new immutable policy-set
version with explicit `subject_keys` and `POLICY_SET_REQUIRED` members, then
preview and deploy it. M31 will add the coordinated runtime transitions.

Take the normal verified backup first. Downgrade is not supported; restore the
pre-upgrade backup if rollback is necessary.

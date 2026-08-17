# M30 compatibility statement

| Area | M30 contract |
| --- | --- |
| Extension | `0.27.0`; direct upgrade from `0.26.0` |
| Ordinary kind | `policy_set` in the M28 declaration envelope |
| Canonical identity | `match_keys` and `subject_keys`, codec v2 |
| Scope modes | `GLOBAL` and `POLICY_SET_REQUIRED` |
| Key types | `bigint`, `uuid`, or `text COLLATE "C"` |
| Envelope | contract version `18` for policy-set foundation results |
| Eligibility | indexed relational rows with bounded JSON evidence |
| Migration | existing M29 sets are `NEEDS_SCOPE_MIGRATION` |
| Runtime boundary | no lifecycle, work, claim, or consequence transition in M30 |
| Upgrade | `ALTER EXTENSION pg_react UPDATE TO '0.27.0'` |
| Next milestone | M31 — Authoritative runtime |

M30 preserves existing M0–M29 data and does not silently change its scope.
Downgrade is not supported; restore a verified backup if rollback is necessary.

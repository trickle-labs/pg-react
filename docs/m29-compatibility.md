# M29 compatibility inventory

| Area | M29 contract |
| --- | --- |
| Extension | `0.26.0`; direct upgrade from `0.25.0` |
| Ordinary kind | `policy_set` in the M28 declaration envelope |
| Applicability | one finite relation or one active M20 shared condition |
| Subject keys | `bigint`, `uuid`, or `text`; non-null and unique |
| Effective time | half-open `[valid_from, valid_to)` bounds |
| Envelope | contract version `17`; M28 envelopes remain unchanged for older kinds |
| Inspection | policy-set, version, member, and eligible-subject views |
| Security | source `SELECT` privilege and existing façade role grants are required |
| Upgrade | `ALTER EXTENSION pg_react UPDATE TO '0.26.0'` |
| Next milestone | M30 — Hypothetical fact simulation |

M29 is additive. Existing M0–M28 APIs, catalogs, policy behavior, and direct
upgrade state remain available. Downgrade is not supported; restore a verified
backup if rollback is necessary.

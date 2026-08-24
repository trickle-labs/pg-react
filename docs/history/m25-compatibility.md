# M25 compatibility inventory

| Area | M25 contract |
| --- | --- |
| Extension | `0.22.0`; direct upgrade from `0.21.0` |
| PostgreSQL | 18.3; `READ COMMITTED` |
| pg_trickle | 0.81.0; inherited differential stream path |
| Clock | Inherited committed database-time frontier |
| Family key | `bigint NOT NULL` with a non-partial unique constraint |
| Value types | Required scalar PostgreSQL columns listed in the M25 contract |
| Maintenance | Ordinary joined relational refresh; no generated rule copies |
| Authorization | Separate family owner and optional value editors; inherited role grants |
| Recovery | Inherited lifecycle, agenda, retention, restore, and managed-worker paths |
| Upgrade | Populated direct `0.21.0 -> 0.22.0` path |
| Next milestone | M26 — Decision tables (proposed, not committed) |

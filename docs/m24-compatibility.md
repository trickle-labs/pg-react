# M24 compatibility inventory

| Area | M24 contract |
| --- | --- |
| Extension | `0.21.0`; direct upgrade from `0.20.0` |
| PostgreSQL | 18.3; `READ COMMITTED` |
| pg_trickle | 0.81.0; inherited differential stream path |
| Clock | One monotone committed database-time frontier; equality is due |
| Authority | Unique deployed interval per policy; explicit gaps are allowed |
| Targets | Ordinary rules and complete derivation programs |
| Work | Old pending work is superseded; leased work fails the existing fresh check |
| Recovery | Existing lifecycle, agenda, retention, restore, and managed-worker paths |
| Upgrade | Populated direct `0.20.0 -> 0.21.0` path |
| Next milestone | M25 — Parameterized policy families |

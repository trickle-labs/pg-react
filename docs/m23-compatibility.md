# M23 compatibility inventory

| Area | M23 contract |
| --- | --- |
| Extension | `0.20.0`; direct upgrade from `0.19.0` |
| PostgreSQL | 18.3; `READ COMMITTED` |
| pg_trickle | 0.81.0; inherited `DIFFERENTIAL` stream path |
| Clock | One monotone committed database-time frontier; equality is due |
| State | Indexed bounded per-key temporal state |
| Limits | 100,000 temporal keys per coordinator pass by default |
| Recovery | Existing lifecycle, agenda, retention, restore, and managed-worker paths |
| Effects | Asynchronous, at-least-once; no exact wall-clock promise |
| Upgrade | Populated direct `0.19.0 -> 0.20.0` path |
| Next milestone | M24 — Effective-dated policy versions (planning-only) |

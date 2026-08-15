# M20 compatibility inventory

| Area | M20 contract |
| --- | --- |
| Extension | `0.17.0`; direct upgrade from `0.16.0` |
| PostgreSQL | `18.3` only |
| pg_trickle | `0.81.0` only; `user_triggers=auto` |
| Isolation | `READ COMMITTED` only |
| Condition source | owned view or materialized view; no RLS dependency |
| Keys | one to four `bigint`, `uuid`, or deterministic-C-collated `text` columns |
| Maintenance | `SCHEDULED` by default; M19-eligible `IMMEDIATE` opt-in |
| Consumers | explicit rule/program public-relation dependencies |
| Replacement | compatible public schema/key boundary; live incompatible consumers rejected |
| Sharing | author-declared, same database, one active immutable version |
| Out of scope | automatic CSE, hidden lifecycle events, new workers, dynamic schemas, retention redesign |

# pg-react 0.20.0 — practical temporal conditions

Version `0.20.0` adds four bounded database-time primitives to ordinary
PostgreSQL condition views: continuous duration, absence by a direct deadline,
cooldown, and arm/recovery hysteresis. Temporal state is durable, indexed by
semantic key and boundary, and explained through public JSON APIs.

The existing monotone frontier, transaction barriers, lifecycle identities,
agenda claims, managed worker, retention, recovery, and at-least-once effect
contract remain authoritative. M23 does not promise exact wall-clock firing.

Upgrade directly from `0.19.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.20.0';
```

M24 — Effective-dated policy versions — is the next planning milestone.

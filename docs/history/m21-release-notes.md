# pg-react 0.18.0 — retention and catalog scale

M21 adds configurable, operator-controlled retention with bounded idempotent
batches, protected executable state, and exact loss-of-detail diagnostics.
Retention is disabled by default.

The public JSON API includes configuration, removal, preview, apply, status,
doctor, metrics, audit, and loss-of-detail detail functions under `pgreact_api`.
Configuration and retention actions are operator-only.

Upgrade directly from `0.17.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.18.0';
```

M22 is the next defined milestone.

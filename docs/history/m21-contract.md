# M21 retention and catalog scale contract

M21 is extension `0.18.0`, with a direct upgrade from `0.17.0`. Retention is
disabled by default and protects current and executable state, active supports,
open windows, and pending work.

## Public API

```sql
pgreact_api.retention_configure(
  full_detail_horizon interval,
  minimum_audit_horizon interval,
  replay_horizon interval,
  rollback_horizon interval,
  deduplication_horizon interval,
  explanation_horizon interval,
  reconciliation_horizon interval,
  recovery_horizon interval,
  enabled boolean DEFAULT false
) RETURNS jsonb

pgreact_api.retention_remove() RETURNS jsonb
pgreact_api.retention_preview(
  requested_cutoff timestamptz,
  batch_size integer DEFAULT 1000
) RETURNS jsonb
pgreact_api.retention_apply(
  requested_cutoff timestamptz,
  batch_size integer DEFAULT 1000
) RETURNS jsonb
pgreact_api.retention_status() RETURNS jsonb
pgreact_api.retention_doctor() RETURNS jsonb
pgreact_api.retention_metrics() RETURNS jsonb
pgreact_api.retention_audit(limit integer DEFAULT 100) RETURNS jsonb
pgreact_api.retention_detail(family text, historical_identity text) RETURNS jsonb
```

Configuration, removal, preview, apply, and audit are operator-only. Status,
metrics, doctor, and detail diagnostics are readable through the configured
reader role. Batches are bounded and idempotent. Preview and apply report exact
loss-of-detail diagnostics; protected state is never silently removed.

M22 is the next defined milestone.

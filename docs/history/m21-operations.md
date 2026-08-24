# M21 operations

Retention is disabled by default. Configure it through
`pgreact_api.retention_configure`; mutation, preview, apply, and audit are
operator-only operations.

Check `retention_status()`, `retention_doctor()`, and `retention_metrics()` for
policy, protected-state, diagnostic, and workload state. Preview before apply.
Use a bounded `batch_size`; repeated preview/apply calls are idempotent.

The service protects current and executable state, active supports, open
windows, and pending work. Every preview and apply returns exact
loss-of-detail diagnostics. Review `retention_audit(limit)` after operator
actions.

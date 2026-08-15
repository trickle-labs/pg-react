# M21 compact tasks

Operator:

1. Inspect `retention_status()`, `retention_doctor()`, and
   `retention_metrics()` before changing policy.
2. Configure horizons with `retention_configure`; leave `enabled` false until
   the policy is reviewed.
3. Run `retention_preview(requested_cutoff, batch_size)` and review its exact
   loss-of-detail diagnostics.
4. Apply approved work with bounded, repeatable
   `retention_apply(requested_cutoff, batch_size)` batches.
5. Use `retention_audit(limit)` for operator history. Use `retention_remove()`
   only when removing the configured policy is intended.

Do not edit private catalogs or delete protected current/executable state,
active supports/open windows, or pending work.

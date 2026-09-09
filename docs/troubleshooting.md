# Troubleshooting

The current release is pg-react `0.43.3`. Start with the exact finding code,
then inspect the named target:

```sql
SELECT pgreact.doctor();
SELECT pgreact.status('review-orders');
SELECT pgreact.explain('review-orders');
```

`M54_REVIEW_TOKEN_INVALID` means the value was not a successful preview token.
`M54_REVIEW_TOKEN_MISMATCH` means it belongs to another declaration.
`M54_REVIEW_TOKEN_STALE` means source, declaration, work, or deployment state
changed after review. `M54_OLD_WORK_REQUIRED` means choose `DRAIN_OLD` or
`CANCEL_OLD`; pg-react does not guess for executable work.

For a barrier or failed work item, follow the existing operator procedure and
use the names-first recovery functions in [Operations](operations.md). Do not
edit private catalogs or copy private UUIDs into application code.

An expired lease on a replaced rule can be recovered by name. The sweep covers
all remaining draining versions and returns the total number of recovered
items. An unauthorized or ambiguous name fails closed.

If a consequence or dispatcher changed after the work was queued, the item is
recorded as failed or retrying without aborting healthy items in the same
managed cycle or batch. Repair the definition through the authorized
replacement workflow, then inspect the full attempt history before requeueing.

When `managed_status()` reports `state = error`, read `detail` as the
coordination cause. A structured `BLOCKED` result is preserved there even
when independent work proceeds. Resolve the barrier, reconcile, and verify
that a later cycle clears the error.

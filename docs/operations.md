# Operations

The current release is pg-react `0.43.0`. PostgreSQL-managed workers normally
poll each configured database. A deliberate cycle is useful in a tutorial or
operator check:

```sql
SELECT pgreact.run();
SELECT pgreact.status('review-orders');
SELECT pgreact.explain('review-orders');
```

Use stable names for normal recovery. Existing recovery semantics still apply;
the names-first overloads resolve the authorized rule and delegate to the
authoritative implementation:

```sql
SELECT pgreact.sweep_expired_leases('review-orders');
SELECT pgreact.reconcile_rule('review-orders', 'STATE_ONLY');
SELECT pgreact.requeue_episode('review-orders', '42');
```

Requeue only terminal work after inspecting it. External effects are at least
once, so consumers must deduplicate by a stable idempotency key. A missing,
ambiguous, changed, or unauthorized name fails closed without exposing a
private identifier.

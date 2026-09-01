# M54 API reference

This milestone reference records the additions to the current
[API Reference](api-reference.md).

## Reviewed deployment

```sql
WITH proposal AS (
    SELECT pgreact.rule(...) AS value
), review AS (
    SELECT value, pgreact.preview(value) AS result FROM proposal
)
SELECT pgreact.deploy(value, pgreact.review_token(result)) FROM review;
```

`review_token` accepts only a successful recognized preview envelope and is
limited to 4096 bytes. It is opaque reviewed-plan evidence, not a password or
authorization credential. Deployment still validates the declaration and
checks current identity, source, permissions, barriers, and work state.

## Replacement

Preview reports `ADD`, `KEEP`, or `REPLACE` for standalone rules and decisions.
Replacement keeps the stable public name. A command rule with eligible old
work must specify `DRAIN_OLD` or `CANCEL_OLD`; deployment never guesses.

## Recovery

`reconcile_rule(text, text)`, `sweep_expired_leases(text)`, and
`requeue_episode(text, text)` resolve an authorized stable name and delegate to
the existing authoritative implementation. They do not expose private IDs or
create new recovery semantics.

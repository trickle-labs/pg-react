# M31 — Authoritative runtime

## What changed

M31 makes a policy set control whether a rule or decision is allowed to act.
In everyday terms:

- an included customer can make a matching rule active;
- an excluded customer cannot create or keep active work;
- adding, removing, expiring, or restoring a customer is recorded once and can
  be explained afterwards;
- unsafe sources stop the runtime and keep the last known-good result instead
  of silently treating an error as “no customers”.

The same behavior is used by `validate`, `preview`, `deploy`, `run`, `remove`,
`status`, `explain`, and `doctor`. Claims are checked again before work runs,
so work that became out of scope is skipped without running its effect.

## What was tested

The complete M31 evidence lane passes on the `0.28.0` candidate while
preserving the released `0.27.0` foundation. It covers rules, decision
programs, policy sets, overlapping sets, entry/exit
and expiry, invalid and protected sources, role isolation, stale claims,
two-session races, performance, retention, populated upgrade, crash/restart,
logical restore, standby promotion, and physical restore.

This is an implementation candidate, not a published M31 release yet. The
existing `v0.27.0` tag belongs to M30 and must not be moved or reused.

## How to try it

Use ordinary names:

```sql
SELECT pgreact_api.run(clock_timestamp());
SELECT pgreact_api.status(
    pgreact_api.target('policy_set', 'customer-rollout', '1'));
SELECT pgreact_api.explain(
    pgreact_api.target('policy_set', 'customer-rollout', '1'),
    jsonb_build_object('customer_id', 42));
```

See the [API reference](m31-api-reference.md) for the complete example and
the [readiness record](m31-readiness.md) for release status.

## Version and next step

When the remaining M31 release gates are evidenced, tag and push `v0.28.0`.
Do not tag it while the readiness record is not green.

The logical next milestone is M32, the PostgreSQL-native interface, planned
for `0.29.0`. It should start only after M31 is qualified.

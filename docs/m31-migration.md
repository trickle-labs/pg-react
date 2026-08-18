# M31 migration

Status: the working-tree M31 runtime SQL is included in the `0.28.0` install
and direct `0.27.0 -> 0.28.0` upgrade artifacts. The local `complete` profile
exercises the populated upgrade, no-silent-gating, recovery, and post-restore
checks.

## Starting point

M30 is extension `0.27.0` and preserves the M29 foundation. M31 consumes that
state directly. The populated upgrade source is `0.27.0`; the expected M31
path is therefore:

```text
0.27.0 -> 0.28.0 (M30 foundation plus the M31 authoritative runtime)
```

The existing `v0.27.0` tag already names the M30 release. It is a tag
collision, not an M31 release marker, and must not be moved or reused.

## Required upgrade properties

- `ALTER EXTENSION ... UPDATE` must not execute business work or external
  actions.
- Existing identities, history, grants, frontiers, lifecycle, work, and M29
  evidence must be preserved where the plan requires them.
- Existing declarations must not silently become policy-set-gated.
- Legacy metadata and M29 policy sets must receive an explicit migration
  classification and remediation path.
- If reconciliation is required, the upgrade must establish a visible barrier
  and require the documented reconciliation operation.
- Malformed, unauthorized, RLS-protected, drifted, or over-limit sources must
  fail closed without unsafe partial mutation.
- Rollback is by restore or the explicitly documented recovery boundary; an
  extension downgrade must not be implied.

## Required evidence before release

The populated direct upgrade must prove preservation, no silent activation,
safe restart/recovery, and exact post-upgrade agreement between status,
explanation, doctor, views, lifecycle, and work. The local complete profile
proves the populated preservation/no-silent-gating path and exercises
restart/recovery; broader release-artifact qualification remains a release
gate.

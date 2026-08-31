# M42 compatibility

| Surface | M42 behavior |
| --- | --- |
| Existing declarations | Normalized form and digest stay unchanged when the policy is omitted |
| M41 `pgreact.explain` | Byte-for-byte unchanged |
| Capture | One complete `decision_result` path only |
| Read | Names-first, historical, no source reread |
| Delete | Owner or operator after eligibility, idempotent |
| Unauthorized read | One fail-closed result with no evidence metadata |
| M21 retention | Explicit `evidence_snapshots` family in preview, apply, audit, detail, and tombstones |
| Upgrade | `0.38.0 -> 0.39.0` |
| Rollback | Restore a verified `0.38.0` backup |

The release review kept one complete M41 answer and one snapshot family. It
removed automatic capture, source-history collection, arbitrary root kinds,
snapshot search, and a second evidence serializer.

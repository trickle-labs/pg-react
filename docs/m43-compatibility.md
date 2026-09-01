# M43 compatibility

| Surface | M43 behavior |
|---|---|
| Existing declarations | Normalization and stored declaration digests remain unchanged |
| Existing M34-M42 calls | Same function identities and output when M43 is not requested |
| Supported targets | `rule`, `decision_program`, `policy_set` with matching names and kinds |
| Target versions | `1` for ordinary declarations; exact immutable version for policy sets |
| Opaque SQL | Public identity and stored/current digests only; no business interpretation |
| Authorization | Target, relation, shared-condition, and function access fail closed |
| Limits | Deterministic byte, field, collection, difference, opaque, depth, and payload bounds |
| Upgrade | `0.39.0 -> 0.40.0` |
| Rollback | Restore a verified `0.39.0` backup |

The call is statement-snapshot read-only. It does not change source rows,
declarations, lifecycle, decisions, work, attempts, evidence, retention, or
frontiers.

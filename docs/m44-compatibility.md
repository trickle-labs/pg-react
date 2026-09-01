# M44 compatibility and retention

| Area | M44 behavior |
|---|---|
| Existing `pgreact.explain` | Same function, options, result fields, and operation-specific contract |
| M40 `why_not` | Same request and result version `26` |
| M41 `causal_path` | Same request and result version `27` |
| M38 current `pgreact.compare` | Same comparison result with existing why-changed evidence version `25` |
| M42 snapshot read | Same outer result version `28` and exact nested M41 answer |
| Default calls | No new option and no new response field |
| Authorization | Existing live and owner-or-operator retained-evidence checks stay in force |
| Upgrade | `0.40.0 -> 0.41.0`, with a no-op SQL script |
| Rollback | Restore a verified `0.40.0` backup |

## Retention matrix

| Evidence | Before expiry | After expiry or deletion | Current or historical |
|---|---|---|---|
| Live current explanation | Return the origin's current answer | Return the origin's existing partial or unavailable result | Current |
| Live why-not or causal path | Return the origin's current answer | Return the origin's existing incomplete or unavailable result | Current |
| Current why-changed comparison | Return the current comparison answer | Return the origin's existing incomplete or unavailable result | Current |
| M42 complete snapshot | Return `available` and the exact nested M41 answer | Return `deletion_eligible`, then the existing tombstone after delete | Historical |
| Missing or unauthorized snapshot | Return the existing fail-closed result | Return the same fail-closed result | Neither |

M44 does not extend retention, capture new evidence, or combine live and
historical answers.

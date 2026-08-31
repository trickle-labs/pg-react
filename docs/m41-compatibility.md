# M41 compatibility

M41 is extension `0.38.0` and upgrades directly from `0.37.0`.

| Surface | M41 behavior |
| --- | --- |
| Existing `pgreact.explain` | Byte-for-byte unchanged when `causal_path` is absent or `false` |
| Existing M40 `why_not` | Unchanged when M41 is not requested |
| Invalid M41 request | `unsupported` with a stable M41 finding and no mutation |
| Unknown or hidden root | `unavailable` with an empty graph and no root identity |
| RLS or missing source | Explicit inaccessible or missing boundary; no hidden metadata |
| Concurrent changes | One statement snapshot; changed tokens return `unavailable` |
| Public API | One existing function with one opt-in option; no new top-level verb |
| Rollback | Restore a verified `0.37.0` backup; there is no in-place downgrade |

The release review kept the four states, one public identity per modeled node,
and separate semantic and elapsed cost. It removed shortest-path ranking,
arbitrary SQL lineage, retained evidence, and graph-query controls from M41.

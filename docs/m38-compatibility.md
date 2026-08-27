# M38 compatibility

| Input or use | Result |
|---|---|
| Missing `why_changed` | Earlier result contract and output |
| `why_changed: false` | Earlier result contract and output |
| `why_changed: true` | Contract version `25` with bounded evidence |
| Non-boolean `why_changed` | `M38_OPTIONS_INVALID` |
| Unknown option on M34 compare | M34 keeps its ignore-unknown behavior |
| Unknown option on M35, M36, or M37 | The originating operation keeps its rejection |
| Unchanged row | No `why_changed` key |
| Missing or pruned evidence | `unavailable` or `partial`, never a complete claim |
| RLS source or missing source permission | The inherited operation rejection |
| More than one evaluated candidate or history | Not supported |

The adjacent upgrade is `0.34.0 -> 0.35.0`. There is no downgrade script.

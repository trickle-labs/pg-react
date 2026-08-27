# M39 compatibility matrix

M39 keeps every public overload. The table describes the common qualification
rules; the operation's existing contract supplies the exact row columns and
milestone-prefixed finding codes.

| Function | Accepted inputs | Default and options | Result sets or sides | Qualification rule |
|---|---|---|---|---|
| `compare(proposed, target, options)` | One declaration and target | `{}`; current comparison and optional `why_changed` | `current`, `proposed`, `delta`, `lifecycle`, `work` | Current snapshot only |
| `compare(proposed, target, change_set, options)` | Declaration, target, ordered typed changes | `{}`; same options | Same as current comparison | One hypothetical change set |
| `replay(proposed, target, snapshot, steps, options)` | Declaration, target, snapshot, finite ordered history | `{}`; replay limits and optional `why_changed` | `initial`, `step`, `delta`, `final`, `lifecycle`, `work` | Supplied history only |
| `backtest(proposed, target, snapshot, steps, options)` | Candidate, target, snapshot, finite history | `{}`; replay limits and optional `why_changed` | `baseline`, `candidate`, `difference` | At most two sides over shared history |
| `compare_results(proposed, target, options)` | Same as JSON current comparison | Same defaults | Relational current result rows | Same public identities as JSON |
| `compare_results(proposed, target, change_set, options)` | Same as JSON hypothetical comparison | Same defaults | Relational current result rows | Same change-set digest as JSON |
| `replay_results(proposed, target, snapshot, steps, options)` | Same as JSON replay | Same defaults | Relational replay rows | Same replay and result digests as JSON |
| `backtest_results(proposed, target, snapshot, steps, options)` | Same as JSON backtest | Same defaults | Relational side and difference rows | Same side and difference identities as JSON |

| Input condition | Required behavior |
|---|---|
| Missing options | Earlier result and return type |
| `why_changed: false` | Byte-for-byte semantic match with missing option |
| `why_changed: true` | Contract version `25`; bounded explanation on supported changed rows |
| Null, malformed, or unknown option | Originating operation's existing rejection or ignored-field rule |
| Empty hypothetical change set | Equal to current comparison for identical frozen inputs |
| Same policy on both backtest sides | Equal side digests and no difference rows except `UNCHANGED` |
| Missing or pruned evidence | `partial` or `unavailable`, never a complete claim |
| Unauthorized or RLS-protected source | Fail closed with no value leakage |
| More than two sides, reconstructed history, or durable job | Not supported by M39 |

The adjacent migration is `0.35.0 -> 0.36.0`. There is no in-place downgrade;
rollback uses a verified `0.35.0` restore.

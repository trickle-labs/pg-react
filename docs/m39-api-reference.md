# M39 API reference

M39 does not add a new call. It qualifies the existing public functions as one
read-only simulation surface.

| Function | Use |
|---|---|
| `pgreact.compare` | Compare a proposed declaration with the deployed target using current facts, or an ordered typed change set. |
| `pgreact.compare_results` | Read the same comparison as relational rows. |
| `pgreact.replay` | Evaluate a supplied snapshot and finite ordered history. |
| `pgreact.replay_results` | Read replay initial, step, delta, and final rows. |
| `pgreact.backtest` | Evaluate up to two policy sides over one shared history. |
| `pgreact.backtest_results` | Read baseline, candidate, and difference rows. |

All documented overloads keep their existing arguments, defaults, and return
types. Pass `why_changed: true` only when bounded causes are needed; omit it to
keep the earlier output. Compare public target names, typed business keys,
result values, replay ordinals, side labels, and digests. Ignore elapsed time,
private UUIDs, query plans, and physical row order.

`ready` or `complete` means the returned bound is complete. `partial` reports
the exact bound reached. `unavailable` and `unsupported` do not mean that an
unreturned row or cause was absent. Every call remains a dry run: it does not
write source data, deploy a policy, create work, advance a frontier, or send an
external effect.

# M38 contract: why-changed comparison

M38 adds an optional explanation to an existing `compare`, `replay`, or
`backtest` result. The explanation answers which returned facts differ between
the two sides. It does not try to explain arbitrary SQL.

## Option

Add `why_changed: true` to the existing `options` object:

```sql
jsonb_build_object('evidence_limit', 100, 'why_changed', true)
```

The option is accepted by `pgreact.compare`, `pgreact.replay`, and
`pgreact.backtest`, including their relational result functions. The default is
`false`. A missing option and `why_changed: false` keep the earlier JSON output
and the earlier relational return types.

The enabled JSON envelope uses contract version `25`. The relational return
types do not change. Their existing `evidence` values can contain a
`why_changed` object for a changed row.

## Explanation shape

Each `ADDED`, `REMOVED`, or `CHANGED` row can contain `why_changed`:

```json
{
  "version": 1,
  "state": "complete",
  "originating_operation": "backtest",
  "side_pair": {"baseline": "baseline", "candidate": "candidate"},
  "result": {
    "result_set": "difference",
    "ordinal": "1",
    "subject_key": "10",
    "result_key": "100",
    "change": "CHANGED"
  },
  "comparison_point": {"result_set": "difference", "ordinal": "1"},
  "causes": [
    {
      "kind": "source_fact",
      "direction": "changed",
      "path": "value.priority",
      "before": 1,
      "after": 0,
      "public_evidence": {"baseline": {}, "candidate": {}}
    }
  ],
  "evidence": {"path_is_public": true, "causes_exact": true},
  "originating_result_digest": "...",
  "explanation_digest": "...",
  "cost": {
    "cause_discovery": 1,
    "evidence_expansion": 1,
    "path_depth": 1,
    "returned_nodes": 1,
    "elapsed_ms": 0
  }
}
```

The digest excludes measured elapsed time. Physical row order and private UUIDs
do not identify a cause.

## Cause kinds

M38 uses these stable names: `source_fact`, `positive_support`,
`negative_support`, `derived_fact`, `applicability`, `parameter`, `threshold`,
`deadline`, `decision_candidate`, `decision_winner`, `lifecycle_revision`,
and `would_be_work`.

`complete` means the returned evidence accounts for every supported cause
within the active limits. `partial` means a limit or incomplete originating
result bounded the explanation. `unavailable` means that the originating result
does not expose the evidence needed for a cause. M38 does not turn an opaque or
unsupported path into a complete causal claim.

Replay explains only a step delta between `previous` and `current`. Backtesting
explains the `baseline` and `candidate` sides at one replay point. Initial and
final replay rows do not receive an explanation.

M38 does not write tables, retain evidence, deploy policies, execute work, or
send external effects. The originating operation keeps its existing validation,
authorization, RLS, history, and resource limits.

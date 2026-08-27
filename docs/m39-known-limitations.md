# M39 known limitations

- M39 qualifies existing current comparison, hypothetical comparison, replay,
  backtesting, and why-changed evidence. It does not add another evaluator.
- Equivalence is valid only for identical frozen inputs, logical time, frontier,
  caller, options, and limits. Current facts do not replace missing history.
- Evidence is transient. M39 does not retain a simulation job or snapshot after
  the call returns.
- Partial, unavailable, unsupported, ambiguous, and cyclic evidence remain
  explicit and are never promoted to a complete claim.
- The supported source shapes, target kinds, typed history, RLS boundary, and
  operation limits remain those of M34–M38.
- Cancellation, timeout, crash, and recovery are qualification cases, not a
  promise of durable simulation state.
- M40 owns bounded why-not answers. M41 owns end-to-end causal paths. M42 owns
  retained evidence snapshots. M43 owns semantic policy field differences.

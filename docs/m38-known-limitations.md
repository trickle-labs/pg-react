# M38 known limitations

- M38 explains only differences produced inside one supported compare, replay,
  or backtest call.
- It compares public returned values and modeled work. It does not reconstruct
  source history or trace arbitrary SQL predicates.
- Evidence is transient. M38 does not keep it after the call returns.
- A partial or unavailable explanation is not a proof that no other cause
  existed.
- The originating M34-M37 boundaries remain, including the supported source
  shapes, typed history, RLS rejection, and operation limits.
- M40 owns bounded why-not answers. M41 owns end-to-end causal paths. M42 owns
  retained evidence snapshots. M43 owns semantic policy field differences.

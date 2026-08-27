# M37 known limitations

- One backtest compares one deployed target with one candidate declaration over
  one complete caller-supplied history.
- The M36 boundary remains: one direct table, one non-null `bigint` identity,
  typed row images, and no RLS source.
- M37 does not discover missing history, reconstruct a past database, execute
  source DML, deploy either policy, run consequences, or deliver external work.
- A partial result bounds evidence but does not claim exact difference counts.
- Difference evidence says which public result rows differ. It is not a causal
  explanation of why they differ; M38 owns that work.
- Elapsed time is measured and may vary. Semantic cost counters are the stable
  values to compare between runs.

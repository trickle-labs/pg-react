# M44 known limitations

- M44 documents installed explanation operations. It does not add a shared
  JSON envelope or a new explanation query.
- Each origin keeps its own result fields, finding codes, limits, and canonical
  order. Cross-origin comparison is supported only when public identity and
  evidence-point inputs match.
- Current explanations use the evidence available in one statement snapshot.
  Missing or pruned evidence can make the answer partial or unavailable.
- M42 retains one complete `decision_result` causal path. It does not retain
  current truth or reread source tables.
- Replay and backtesting why-changed answers remain outside M44.
- M44 does not explain arbitrary SQL, query plans, application code, or
  cross-database lineage.
- The external workload required by the entry gate is not included in this
  repository. It must be supplied and recorded before publication.

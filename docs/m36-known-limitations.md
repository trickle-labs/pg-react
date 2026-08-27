# M36 known limitations

- The caller must provide the complete starting snapshot and every later
  change. M36 does not collect, retain, infer, or rebuild history.
- One replay covers one direct table and one non-null `bigint` identity. Views,
  composite identities, and other key types are rejected.
- Historical DDL, defaults, generated expressions, triggers, cascades,
  sequences, volatile functions, source DML, consequences, and external calls
  are not replayed. Supply final typed row images instead.
- Evidence is bounded. A partial result is explicit and does not report exact
  counts for the omitted portion.
- M37 owns two-policy-version comparative backtesting; M38 owns why-changed
  comparison. Neither is included in M36.

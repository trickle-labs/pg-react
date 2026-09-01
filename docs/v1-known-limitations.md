# v1 known limitations

> Historical record for the prepared v1 candidate. Use current
> [Known Limitations](known-limitations.md) for pg-react `0.43.0`.

- The only qualified environment is PostgreSQL 18.3 with pg_trickle 0.81.0 on
  Linux amd64. See the [support matrix](v1-support-matrix.md).
- `0.42.0` is the current qualified release. Its documented adjacent update is
  `0.41.0 -> 0.42.0`.
- The managed runtime supports `0.31.0` through `0.42.0`, `1.0.0-rc.N`, and
  `1.0.0`.
- `configure_roles` authoritatively grants comparison execution to `author`,
  `operator`, and `reader` roles.
- For historical `0.31.0` installations, an explicit post-`configure_roles` grant of comparison is required until upgraded to `1.0.0-rc.1`.
- Evaluated RLS sources are rejected. Unauthorized target/source comparison
  fails closed; there is no proven row-redacted comparison substitute.
- Simulation supports current and typed hypothetical comparison,
  caller-supplied replay, and at most two backtest sides. It does not capture or
  reconstruct missing history, retain a simulation job, or answer arbitrary
  why-not questions. M40 answers bounded absence questions, and M41 answers
  bounded causal paths, only for modeled current results and work.
- Comparison supports `rule`, `decision_program`, and `policy_set` targets
  with matching names and kinds. Non-policy target versions are `NULL` or
  `'1'`; comparable rules require one non-null unique `bigint` key.
- Simulation evidence is bounded by each operation's published limits. Partial
  results expose no continuation token; relational functions expand the same
  bounded result.
- Comparison cost fields for dependency fan-out, reevaluation, cascade depth,
  memory, and temporary storage are placeholders or unavailable where the
  operation reports them,
  not measured capacity evidence.
- Semantic differences report modeled declaration fields only. Arbitrary SQL
  and business impact remain opaque. See [Explain an Outcome](explaining-outcomes.md).
- The advanced/compatibility runtime has qualified codec-v2 bigint, UUID,
  text, and composite keys, but this does not broaden the comparable-rule key
  restriction or settle every entry point's long-term v1 classification.
- External delivery is at least once. Consumers must use idempotency keys or
  deduplicate deliveries.
- Logical restore is qualified for application schema/data and declaration
  replay followed by rebuild/reconciliation. Portable restoration of live
  pg-react private catalogs is not claimed.
- pg-react is a rule and policy engine, not an arbitrary workflow/BPM or human
  task platform.

Exact operational bounds are in [Limits](v1-limits.md). Historical milestone
limitations are retained under [History](history.md), but are not current
product guidance.

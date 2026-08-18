# v1 known limitations

- The only qualified environment is PostgreSQL 18.3 with pg_trickle 0.81.0 on
  Linux amd64. See the [support matrix](v1-support-matrix.md).
- `0.31.0` contains the v1 feature set, but no `1.0.0-rc.1` or `1.0.0`
  artifact or qualified upgrade path exists yet.
- The managed runtime currently cycles only when the installed extension
  version string is exactly `0.31.0`. RC/GA version handling is an RC blocker.
- Fresh 0.31.0 installation requires an explicit post-`configure_roles` grant
  of comparison to the author, operator, and reader roles.
- Evaluated RLS sources are rejected. Unauthorized target/source comparison
  fails closed; there is no proven row-redacted comparison substitute.
- Comparison varies the declaration over current authoritative facts only. It
  does not apply hypothetical inserts, updates, or deletes, and it does not
  provide historical replay or backtesting.
- Comparison supports `rule`, `decision_program`, and `policy_set` targets
  with matching names and kinds. Non-policy target versions are `NULL` or
  `'1'`; comparable rules require one non-null unique `bigint` key.
- Comparison evidence is bounded to `1..1000` rows per requested limit.
  Partial results expose no continuation token; `compare_results` expands the
  same bounded comparison.
- Comparison cost fields for dependency fan-out, reevaluation, cascade depth,
  memory, and temporary storage are placeholders or unavailable in 0.31.0,
  not measured capacity evidence.
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

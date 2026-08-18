# v1 limits

Limits are safety boundaries, not tuning suggestions. Crossing one must fail
before unsafe partial mutation where possible and identify the exact limit.

| Area | v1 policy |
| --- | --- |
| Semantic keys | one non-null unique `bigint` key for an ordinary rule |
| Policy members | bounded by `evidence_limit`; oversized sets fail validation |
| Candidate rows | bounded by `max_candidates` |
| Evidence | bounded by declaration evidence limits; continuation is explicit |
| Derivation / recursion | bounded by the installed program limits |
| Retry | bounded by `max_attempts` and configured backoff |
| Worker claims | bounded claim batches and lease budgets |
| Pending work | bounded by `pg_react.max_pending_jobs` |
| Retention | terminal payloads may be pruned only by the documented operation |
| Diagnostics | finding detail and evidence are bounded and may be truncated |

Tune a supported bound only through the public configuration or declaration
operation. Do not edit private tables to bypass a limit.

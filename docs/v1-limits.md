# v1 limits

Limits fail closed or mark evidence incomplete. Do not bypass them by editing
private tables.

## Comparison limits

| Limit | Installed 0.31.0 behavior |
| --- | --- |
| Comparable kinds | `rule`, `decision_program`, and `policy_set` only |
| Target identity | Proposal kind and name must exactly match the deployed target |
| Non-policy target version | `NULL` or the literal `'1'` only |
| Policy-set target version | Optional; when supplied it must identify the active deployed policy-set version |
| Comparable rule key | One non-null, unique `bigint` column |
| Decision identities | Subject, candidate, and priority columns are `bigint`; `max_candidates` is enforced per subject |
| `evidence_limit` | Default `100`; minimum `1`; maximum `1000` |
| `sampled_time` | Must equal the current authoritative frontier |
| Evidence continuation | None |

`pgreact.compare` returns at most the requested evidence for each bounded
result array. If any side or delta exceeds the bound, the result is `partial`,
`truncated` is true, `counts_exact` is false, exact delta counts are omitted,
and `M34_COMPARISON_INCOMPLETE` is reported.

`pgreact.compare_results` expands the same bounded arrays by calling
`pgreact.compare`; it is not an unbounded stream and exposes no continuation
token. Rerun with a larger `evidence_limit`, up to `1000`, if more evidence is
required.

The comparison cost envelope measures row counts, affected subjects,
would-be work, and elapsed time. In 0.31.0, dependency fan-out,
reevaluation, cascade depth, and temporary storage are constant `0`, while
`memory_bytes` is `NULL`; do not treat those fields as measured capacity
evidence.

## General key support is a separate scope

The installed advanced/compatibility key codec is version 2: one to four
non-null components, using `bigint`, `uuid`, or `text`, with declared component
order and deterministic `C` collation for text. This qualified runtime behavior
does not broaden ordinary rule comparison: `pgreact.compare` still requires
the proposed rule key column to be `bigint`.

The exact long-term v1 classification of every typed-key entry point remains
separate from the comparison contract.

## Managed runtime and work limits

| Setting or operation | Default | Installed range or behavior |
| --- | --- | --- |
| `pg_react.databases` | unset | Comma-separated names; one worker per unique non-empty database; restart required |
| `pg_react.worker_role` | `postgres` | One role name; restart required |
| `pg_react.poll_interval_ms` | `1000` | `10..60000`; reloadable |
| `pg_react.batch_size` | `32` | `1..1000`; reloadable |
| `pg_react.max_pending_jobs` | `10000` | Minimum `1`; coordination pauses at the threshold while existing work drains |
| Public claim size | `1` | `1..100` work items |
| Claim lease | `60 seconds` | `1 second..1 hour` |
| `max_attempts` | `1` for ordinary rule declarations | `1..100` |
| Initial backoff | `1 second` | `1..3600` seconds |
| Maximum backoff | `60 seconds` | `1..86400` seconds |
| Backoff multiplier | `2` | Minimum `1` |

Although the `pg_react.batch_size` GUC accepts values through `1000`, the
public work-claim operation rejects values above `100`. Keep managed command
work at `100` or below until this installed mismatch is resolved.

Decision declarations default `max_candidates` to `1000` and require a
positive value. Policy-set applicability evidence is bounded `1..1000`, and a
relation-backed applicability source is limited to `100000` rows.

Retention and recovery limits must be exercised through their documented
public operations. Private-catalog changes are unsupported.

# Changing Policies Safely

This guide describes the current pg-react `0.43.1` replacement workflow.

Use comparison before replacing a deployed rule, decision, or policy set.
Comparison varies the declaration while holding authoritative facts at the
current source frontier.

```text
deployed target + current facts
versus
proposal        + current facts
```

It does not deploy the proposal or execute effects.

This guide covers current-fact comparison. For hypothetical facts, supplied
history, backtesting, and why-changed evidence, use the simulation references
listed in the [API Reference](api-reference.md). For a bounded explanation of one missing current
result, use [Explain an Outcome](explaining-outcomes.md).

## 1. Start with a deployed target

This guide continues the `manual-review-required` rule from
[Getting Started](getting-started.md).

```sql
SELECT pgreact.status('manual-review-required');

SELECT name, semantic_key, active, generation, revision, bindings
FROM pgreact.matches
WHERE name = 'manual-review-required'
ORDER BY semantic_key;
```

Resolve health or source drift before comparison:

```sql
SELECT pgreact.doctor();
```

## 2. Construct the proposal

Suppose the deployed rule matches high-risk orders above `10000`. The proposal
lowers the threshold:

```sql
CREATE VIEW rule_def.high_value_risky_order_v2 AS
SELECT order_id, customer_id, amount
FROM app.orders
WHERE risk_level = 'HIGH'
  AND amount > 7500;

CREATE FUNCTION rule_action.open_review_v2(
    context pgreact.activation_context,
    match rule_def.high_value_risky_order_v2
)
RETURNS void
LANGUAGE SQL
BEGIN ATOMIC
    INSERT INTO app.manual_review_tasks (
        order_id, customer_id, amount, activation_id, idempotency_key
    )
    VALUES (
        (match).order_id,
        (match).customer_id,
        (match).amount,
        (context).activation_id,
        (context).idempotency_key
    )
    ON CONFLICT (order_id) DO UPDATE
    SET customer_id = EXCLUDED.customer_id,
        amount = EXCLUDED.amount,
        activation_id = EXCLUDED.activation_id,
        idempotency_key = EXCLUDED.idempotency_key;
END;
```

The proposal must have the same kind and name as the deployed target:

```sql
SELECT pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order_v2'::regclass,
    semantic_key => 'order_id'::name,
    kind         => 'COMMAND',
    on_activate  =>
      'rule_action.open_review_v2(pgreact.activation_context,rule_def.high_value_risky_order_v2)'::regprocedure
);
```

The proposed consequence uses the exact proposed condition row type.

Add a fact that only the lower proposed threshold matches, then let the
deployed policy observe the new source frontier:

```sql
INSERT INTO app.orders
    (order_id, customer_id, amount, risk_level)
VALUES
    (43, 8, 8000.00, 'HIGH');

SELECT pgreact.run();
```

The deployed rule still excludes order 43; the proposal includes it.

Validate and preview the proposal first:

```sql
WITH proposal AS (
    SELECT pgreact.rule(
        name         => 'manual-review-required',
        condition    => 'rule_def.high_value_risky_order_v2'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  =>
          'rule_action.open_review_v2(pgreact.activation_context,rule_def.high_value_risky_order_v2)'::regprocedure
    ) AS value
)
SELECT pgreact.validate(value), pgreact.preview(value)
FROM proposal;
```

## 3. Run `pgreact.compare()`

```sql
WITH proposal AS (
    SELECT pgreact.rule(
        name         => 'manual-review-required',
        condition    => 'rule_def.high_value_risky_order_v2'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  =>
          'rule_action.open_review_v2(pgreact.activation_context,rule_def.high_value_risky_order_v2)'::regprocedure
    ) AS value
)
SELECT jsonb_pretty(pgreact.compare(
    value,
    pgreact_api.target('rule', 'manual-review-required'),
    jsonb_build_object('evidence_limit', 100)
))
FROM proposal;
```

`pgreact.compare()` returns one `jsonb` envelope.

## 4. Read current, proposed, and delta

- `current` is bounded evidence for the deployed target's current result.
- `proposed` is bounded evidence from the proposed declaration over the same
  current authoritative frontier.
- `delta` compares rows by subject identity.

Delta states are:

| State | Meaning |
| --- | --- |
| `ADDED` | Present only in proposed output. |
| `REMOVED` | Present only in current output. |
| `CHANGED` | Present in both, but state or value differs. |
| `UNCHANGED` | Present in both with the same compared state and value. |

When evidence is complete, `summary.delta_counts` and
`summary.affected_subject_count` are exact. When evidence is partial, exact
delta counts are `null`; do not derive full-policy conclusions from the
returned subset.

## 5. Read lifecycle and work

`lifecycle` contains delta rows other than `UNCHANGED`. It is the comparison's
view of subjects whose lifecycle interpretation would differ.

`work` contains proposed rows labeled `would_be_work`. These are forecast rows,
not entries in `pgreact.work`, and they do not prove that a consequence was or
will be executed. Actual durable work is created only after deployment and a
managed production cycle.

Comparison does not create an attempt, lease, retry, delivery, or external
effect.

## 6. Use `pgreact.compare_results()` relationally

`compare_results()` exposes the same bounded `current`, `proposed`, `delta`,
`lifecycle`, and `work` rows for filtering, joins, aggregation, and reports:

```sql
WITH proposal AS (
    SELECT pgreact.rule(
        name         => 'manual-review-required',
        condition    => 'rule_def.high_value_risky_order_v2'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  =>
          'rule_action.open_review_v2(pgreact.activation_context,rule_def.high_value_risky_order_v2)'::regprocedure
    ) AS value
),
comparison AS (
    SELECT result.*
    FROM proposal
    CROSS JOIN LATERAL pgreact.compare_results(
        proposal.value,
        pgreact_api.target('rule', 'manual-review-required'),
        jsonb_build_object('evidence_limit', 100)
    ) AS result
)
SELECT
    comparison.delta,
    comparison.subject_key,
    orders.customer_id,
    orders.amount,
    comparison.current_value,
    comparison.proposed_value,
    comparison.complete
FROM comparison
LEFT JOIN app.orders AS orders
  ON orders.order_id::text = comparison.subject_key
WHERE comparison.result_set = 'delta'
  AND comparison.delta <> 'UNCHANGED'
ORDER BY comparison.subject_key;
```

Each call to `compare_results()` performs a comparison. It does not read a
hidden full result behind a prior `compare()` envelope.

## 7. Understand `evidence_limit`

`evidence_limit`:

- defaults to `100`;
- must be between `1` and `1000`;
- bounds returned current, proposed, delta, lifecycle, and work evidence.

A result with `state = 'partial'`, `truncated = true`,
`evidence.complete = false`, or finding `M34_COMPARISON_INCOMPLETE` is
incomplete. Partial output has no continuation token.

`compare_results()` is the relational projection of that same bounded
comparison. It does not expose omitted rows or a continuation cursor.

If more evidence is needed, rerun the comparison with a higher limit:

```sql
-- Same proposal and target, larger bounded review.
SELECT pgreact.compare(
    pgreact.rule(
        name         => 'manual-review-required',
        condition    => 'rule_def.high_value_risky_order_v2'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  =>
          'rule_action.open_review_v2(pgreact.activation_context,rule_def.high_value_risky_order_v2)'::regprocedure
    ),
    pgreact_api.target('rule', 'manual-review-required'),
    jsonb_build_object('evidence_limit', 1000)
);
```

If the full evidence still exceeds 1000 rows, the current release provides no continuation
mechanism.

## 8. Source frontier and sampled time

If `sampled_time` is omitted, comparison uses the current authoritative source
frontier. If supplied, it must be an RFC3339 timestamp string exactly equal to
that current frontier. A stale, future, or otherwise different value fails
with `M34_SAMPLED_TIME`.

The successful result returns both `evidence.sampled_time` and
`evidence.source_frontier`; they are equal for the installed comparison.
Comparison is not historical replay.

If selected pg-react authoritative state changes during comparison, the call
fails with `M34_AUTHORITATIVE_CHANGED` instead of returning an answer against
two different frontiers.

## 9. Target, kind, key, and version restrictions

Supported target kinds are exactly:

- `rule`
- `decision_program`
- `policy_set`

The proposal kind must equal the target kind, and the proposal name must equal
the target name.

For rules and decisions, the target version must be `NULL` or `'1'`:

```sql
SELECT pgreact_api.target('rule', 'manual-review-required');
SELECT pgreact_api.target('rule', 'manual-review-required', '1');
```

Any other non-policy version fails with `M34_TARGET_VERSION`.

For a policy set, target the deployed policy-set version being reviewed:

```sql
SELECT pgreact_api.target('policy_set', 'order-review-policy', '1');
```

The proposed policy set may use its new immutable version, but its target kind
and name still must match.

Rule comparison supports exactly one non-null, unique `bigint` key. Do not
generalize broader installed typed-key authoring support to comparison.

## 10. Authorization and RLS

Comparison is granted to configured authors, operators, and readers, subject
to target and source authorization:

- the caller must be allowed to inspect the target;
- the caller must have `SELECT` on evaluated source relations;
- RLS-enabled evaluated sources are unsupported.

Unauthorized target/source access and RLS sources fail with
`M34_UNAUTHORIZED_TARGET`, `M34_UNAUTHORIZED_SOURCE`, or
`M34_RLS_UNSUPPORTED`. Rows are not returned with protected values redacted;
the comparison fails instead.

## 11. No-effect boundary

Comparison SQL is read-only. It performs:

- no deployment;
- no lifecycle or match mutation;
- no durable work or attempt creation;
- no consequence execution;
- no external delivery;
- no authoritative frontier advancement;
- no hypothetical fact insert, update, or delete;
- no historical replay.

The result includes `authoritative_checksum_before` and
`authoritative_checksum_after`. The installed checksum covers the current
frontier, declarations, rule versions, activation state, decision subject
state, the public work projection, and policy-set versions.

It does **not** hash source tables, lifecycle history, attempts, outbox or
delivery state, or external systems. Equal checksum fields therefore do not
prove those excluded states are byte-for-byte equal. The no-effect boundary is
also supported by the read-only comparison implementation and its no-DML
qualification audit.

## 12. Cost and equivalence limits

`cost.rows_considered`, `would_be_work`, and elapsed time are populated by the
comparison; affected-subject counts are available only for complete evidence.
The installed fan-out, reevaluation, cascade-depth, and temporary-storage
fields are placeholder zeroes, and `memory_bytes` is unavailable (`null`).
Do not present them as measurements.

`elapsed_ms` varies between runs, so full result envelopes are not promised to
be byte-for-byte identical. Comparison uses dedicated read-only evaluation
helpers with tested semantic outcomes; this is not a contractual guarantee
that it shares the production evaluator's implementation path.

## 13. Revise, deploy, or stop

After review, choose one:

1. **Revise** the proposal and compare again.
2. **Deploy** the reviewed declaration intentionally.
3. **Stop** and leave the deployed target unchanged.

For a changed policy set, deploy a new immutable policy-set version after a
fresh preview.

Use the same ordinary workflow for an active replacement: preview the
proposal, pass `pgreact.review_token(preview)`, and provide
`jsonb_build_object('old_work', 'DRAIN_OLD')` or `CANCEL_OLD` when executable
old work exists. The UUID-oriented `pgreact.replace_rule(...)` remains a
compatibility path documented in [Operations](operations.md).

After any qualified deployment, allow the managed runtime to process current
facts and verify `pgreact.status`, `pgreact.matches` or
`pgreact.decisions`, `pgreact.work`, and `pgreact.attempts`.

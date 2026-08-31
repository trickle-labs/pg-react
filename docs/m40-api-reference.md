# M40 API reference

## Ask why a rule match is absent

```sql
SELECT pgreact.explain(
    'manual-review-required',
    jsonb_build_object('key', 42),
    jsonb_build_object(
        'why_not', jsonb_build_object(
            'result_kind', 'rule_match',
            'result_key', '42'))
);
```

Read `state`, then `causes`. A missing row in the installed rule source is a
complete `missing_input` cause. A source row without an active match is
`unavailable` until the rule refreshes. A required policy set can add a public
`applicability` cause.

## Ask about a decision result

Use the candidate key as `result_key`:

```sql
SELECT pgreact.explain(
    'order-routing', '42'::jsonb,
    jsonb_build_object(
        'why_not', jsonb_build_object(
            'result_kind', 'decision_result',
            'result_key', '9001'))
);
```

`decision_candidate` means the requested candidate is absent. If it exists but
loses, `decision_selection` shows the public priorities and winner. A missing
or tied winner adds `decision_eligibility`.

Maintained derived relations use the same call with `result_kind =>
derived_fact`. An existing fact is `already_present`; no active support is a
bounded `derived_fact` cause. Active support without a fact is `unavailable`
until reconciliation.

## Ask about policy eligibility

```sql
SELECT pgreact.explain(
    'high-value-orders', jsonb_build_object('customer_id', 42),
    jsonb_build_object(
        'why_not', jsonb_build_object(
            'result_kind', 'policy_eligibility',
            'result_key', '{"customer_id": 42}'))
);
```

The policy set must use a relational applicability source. An ineligible
subject returns a complete `applicability` cause. A future or expired version
returns `inactive_policy_time`.

# M40 contract: bounded why-not

M40 lets an operator ask why one expected result is missing. The question is
opt-in and read-only. It answers only from evidence that pg-react already
models for one deployed target and one subject.

## Request

Pass one expected public result in the `why_not` option:

```sql
SELECT pgreact.explain(
    'manual-review-required',
    '42'::jsonb,
    jsonb_build_object(
        'why_not', jsonb_build_object(
            'result_kind', 'rule_match',
            'result_key', '42'))
);
```

`result_kind` and `result_key` are required. The accepted result kinds are
`rule_match`, `derived_fact`, `decision_result`, and `policy_eligibility`. A
rule, derived relation, and decision use a bigint subject key. A policy set
uses the subject JSON value as its public result key. `value` may be included
for display, but identity is the kind and key.

The missing option and `why_not: false` call the 0.36.0 implementation with
the same options as before. `why_not: true`, `null`, or a malformed object
returns `unsupported` with `M40_OPTIONS_INVALID` or
`M40_EXPECTED_RESULT_INVALID`. Unknown target names and duplicate names return
stable findings instead of a guessed cause.

## Result

The opt-in result uses contract version `26` and contains the target, subject,
expected result, sampled time, authoritative frontier, observed state, causes,
limits, public evidence, findings, and cost counters.

`already_present` means the requested result exists. It has no why-not cause.
`complete` means every cause supported by the adapter was checked. `partial`
means a published bound or stale frontier stopped the answer. `unavailable`
means schema, authorization, RLS, or runtime evidence prevented a safe answer.
`unsupported` means the target, result kind, SQL shape, or request is outside
the M40 contract.

Causes are ordered by public path. They use `missing_input`,
`positive_support`, `applicability`, `inactive_policy_time`,
`decision_eligibility`, `decision_candidate`, `decision_selection`, or
`lifecycle_revision`. Evidence contains public names, typed keys, modeled
values, and time boundaries. It does not expose private UUIDs or catalog IDs.

M40 samples one PostgreSQL statement snapshot and reads the current clock
frontier in that same statement. It does not write source data, pg-react state,
work, history, evidence, or effects.

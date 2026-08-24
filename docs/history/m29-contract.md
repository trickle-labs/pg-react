# M29 contract — policy-set gating

M29 is extension `0.26.0`. It lets one named policy set apply to a finite
population of subjects, such as the customers in one jurisdiction or the
accounts in a rollout cohort. The policies remain ordinary pg-react policies;
the set only decides which subjects are eligible.

## Declaration

Use the existing M28 declaration envelope:

```sql
SELECT pgreact_api.declaration('policy_set', 'eu-review', jsonb_build_object(
  'version', '1',
  'members', jsonb_build_array(jsonb_build_object(
    'kind', 'rule', 'name', 'review-high-value', 'version', '1')),
  'applicability', jsonb_build_object(
    'source_kind', 'relation',
    'relation', 'app.customer_gate',
    'subject_key', 'customer_id'),
  'valid_from', '2026-01-01T00:00:00Z',
  'evidence_limit', 100));
```

`members` is a bounded, duplicate-free list of already-deployed targets. Each
member has an explicit immutable version. `valid_from` and optional `valid_to`
form a half-open interval: `[valid_from, valid_to)`.

The applicability source is either:

- a schema-qualified table, partitioned table, view, materialized view, or
  foreign table; or
- an active M20 named shared condition, using its declared key.

The source must contain one non-null row per eligible subject. Subject keys are
currently `bigint`, `uuid`, or `text`. Missing subjects are default-deny.
Nulls, duplicates, row-level-security sources, missing privileges, drift, and
the 100,000-row limit fail closed.

## Ordinary workflow

```text
define → validate → preview → deploy → run → status / explain / doctor
```

Preview records a normalized declaration, complete frontier, source fingerprint,
eligible-subject count, and bounded evidence. Deployment requires the preview
digest when supplied and stores an immutable version atomically. A changed
source or declaration makes the old preview stale. Overlapping effective
intervals for one set are rejected.

The relational inspection views are `pgreact.policy_sets`,
`pgreact.policy_set_versions`, `pgreact.policy_set_members`, and
`pgreact.policy_set_eligible_subjects`.

M29 does not add nested sets, Boolean gate expressions, a policy DSL,
cross-database sources, hypothetical simulation, replay, backtesting, or a
second evaluator. Existing member APIs and lifecycle semantics remain the
authoritative policy behavior; M29 stores the applicability boundary and its
evidence.

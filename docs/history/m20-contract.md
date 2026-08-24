# M20 shared conditions contract

M20 is extension `0.17.0`, with a direct upgrade from `0.16.0`. It adds
explicit shared truth relations without adding a scheduler or lifecycle engine.

## Declaration

Authors define a condition with JSON:

```json
{
  "name": "policy.high_risk",
  "version": 1,
  "source": "policy.high_risk_source",
  "row_type": "policy.high_risk_row",
  "key": ["customer_id"],
  "maintenance_mode": "SCHEDULED"
}
```

The source is an owned PostgreSQL view, the row type is an owned composite
type, and keys are one to four `bigint`, `uuid`, or deterministic-C-collated
`text` attributes. The public relation named by `name` is maintained through
the existing keyed derived-relation and derivation-program machinery.

## Public API

- `validate_shared_condition`, `preview_shared_condition`, and
  `deploy_shared_condition` validate, fingerprint, and deploy an immutable
  version. A preview digest is required for deployment when supplied.
- `register_shared_condition_consumer` records a rule or program that actually
  consumes the public relation. `grant_shared_condition_reader` grants value
  visibility separately from metadata inspection.
- `shared_condition_status`, `shared_condition_cost`,
  `shared_condition_matches`, `shared_condition_explain`, `status`, `explain`,
  and `doctor` expose bounded public state and drift remediation.
- `reconcile_shared_condition` reuses the existing program reconciliation path.
  `remove_shared_condition` rejects removal while a live consumer exists.

Compatible replacements retain the public relation, key/schema contract, and
dependency identity while creating a new immutable condition version. Schema,
key, maintenance-mode, and source-row-shape changes with live consumers are
rejected before cutover. Conditions have no activation, consequence, or
external effect of their own; consumers retain their inherited lifecycle.

Immediate conditions use the frozen M19 capability contract. An immediate
consumer must independently be immediate; scheduled consumers remain an
explicit asynchronous boundary.

## Boundaries

Automatic common-subplan discovery, implicit rewrites, dynamic schemas,
cross-database sharing, RLS sources, arbitrary lineage, new workers, and
retention redesign remain out of scope.

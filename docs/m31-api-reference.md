# M31 API reference

Status: the working-tree `0.28.0` SQL artifact carries the M31 ordinary
façade. M31’s release target is `0.28.0`; the supported rule,
decision-program, and policy-set paths pass the complete local evidence lane.
The release is still gated on external evidence.

## Ordinary operations

| Operation | Intended meaning | State mutation |
| --- | --- | --- |
| `validate` | Check declaration shape, access, source health, limits, and kind support | No |
| `preview` | Show normalized identity, applicability, findings, and bounded evidence | No |
| `deploy` | Install or replace authoritative declaration state | Yes |
| `run` | Coordinate authoritative refresh and eligible work | Yes |
| `remove` | Retire an object and its runtime consequences safely | Yes |
| `status` | Report lifecycle, applicability, work, and barriers | No |
| `explain` | Explain effective truth, support, decisions, and provenance | No |
| `doctor` | Report actionable health, access, drift, recovery, and readiness findings | No |

These names are inherited from the M30 ordinary workflow. The local M31 slice
adds `M31_UNSUPPORTED_KIND` and `M31_ADAPTER_REQUIRED` validation findings,
records distinct `M31_SOURCE_UNAVAILABLE`, `M31_SOURCE_INVALID`,
`M31_SOURCE_UNAUTHORIZED`, `M31_SOURCE_RLS_PROTECTED`,
`M31_SOURCE_INCOMPLETE`, `M31_SOURCE_DUPLICATE`,
`M31_SOURCE_OVER_LIMIT`, `M31_SOURCE_MALFORMED`, and `M31_SOURCE_DRIFT`
barriers, and emits `M31_RUNTIME_READY` as a policy-set diagnostic.

## Names-first example

After a rule and policy set are deployed, an operator can refresh and inspect
by name. Assume `app.orders_match` exposes `order_id` and `customer_id`, and
`app.customer_gate` contains included customers.

```sql
SELECT pgreact_api.run(clock_timestamp());

SELECT pgreact_api.status(
    pgreact_api.target('policy_set', 'customer-rollout', '1'));

SELECT pgreact_api.explain(
    pgreact_api.target('policy_set', 'customer-rollout', '1'),
    jsonb_build_object('customer_id', 42));

SELECT pgreact_api.doctor(
    pgreact_api.target('policy_set', 'customer-rollout', '1'));
```

For the local slice, removing a customer from the gate and running again
withdraws its support. An inaccessible source is reported as `BLOCKED`, not as
an empty customer list. The workflow uses names, not internal UUIDs or private
catalogs.

## Authoritative adapter registry

| Kind | M31 disposition | Required behavior |
| --- | --- | --- |
| `rule` | Required | Match, scope, lifecycle, effective truth, work, and explanation agree |
| `decision_program` | Required | Decision winner and downstream work are scope-aware and durable |
| `policy_set` | Required | Eligibility and member support transitions are authoritative |
| `derived_program` | Plan-defined limits | Must not be claimed complete without an explicit adapter result |
| `temporal_policy` | Plan-defined limits | Must not be claimed complete without an explicit adapter result |
| `effective_policy` | Plan-defined limits | Must not be claimed complete without an explicit adapter result |
| `parameter_family` | Plan-defined limits | Must not be claimed complete without an explicit adapter result |
| unknown and rejected kinds | Unsupported | Reject before mutation |

## Stable inspection concepts

The eventual public surface must make these concepts inspectable without
requiring private-catalog interpretation:

- match and subject identities;
- eligibility and scope supports;
- effective truth and lifecycle state;
- decisions, derivations, work, and attempts;
- frontiers, barriers, source fingerprints, and provenance;
- findings with code, severity, blocker, object_identity, field_path, message,
  hint, details, evidence, and truncated.

The exact view names, columns, SQLSTATEs, and finding-code inventory remain
implementation evidence, not promises of this documentation-only change.

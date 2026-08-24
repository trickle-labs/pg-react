# M31 support matrix

Status: the supported M31 runtime paths pass the local complete evidence lane;
the independent review found no blocker, and release qualification still
requires the usability record and remaining artifact evidence.

| Capability or kind | M31 requirement | Evidence status |
| --- | --- | --- |
| `rule` | Authoritative adapter and scoped lifecycle/work truth | Complete-lane fixture passes |
| `decision_program` | Authoritative adapter and scope-aware decision/work truth | Complete-lane winner/support fixture passes |
| `policy_set` | Authoritative eligibility and member-support transitions | Complete-lane fixture passes |
| `derived_program` | Only documented, explicitly tested limits | Pending |
| `temporal_policy` | Only documented, explicitly tested limits | Pending |
| `effective_policy` | Only documented, explicitly tested limits | Pending |
| `parameter_family` | Only documented, explicitly tested limits | Pending |
| Unknown kind | Reject before mutation | Validation, preview, deploy, status, and explanation rejection fixture passes |
| `GLOBAL` scope | Preserve M30 semantics; never silently gate | Global-run, sampled-frontier, and failed-refresh barrier fixtures pass |
| `POLICY_SET_REQUIRED` | Use relational eligibility and subject identity | Entry, exit, return, expiry, removal, and overlap fixtures pass |
| Match identity | One to four typed ordered components | M30 contract |
| Subject identity | One to four typed ordered components | M30 contract |
| RLS/protected source | Fail closed with an actionable finding | Dropped-source, RLS-protected, incomplete, duplicate, malformed, and over-limit barriers pass |
| Removal | Atomic retirement of runtime and work consequences | Policy-set, rule, decision, and stale-claim removal fixtures pass |
| Recovery/failover | Preserve agreement or publish exact barrier | Crash/restart, logical restore, standby promotion, physical restore, reconciliation, and retention fixtures pass |
| Read-only façade | No authoritative checksum change | Rule, decision, policy-set, and barrier façade checks pass |

Simulation, replay, backtesting, why-changed comparison, nested policy sets,
and a new policy language are outside M31.

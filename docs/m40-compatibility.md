# M40 compatibility

| Call | `why_not` absent or false | `why_not` object |
|---|---|---|
| `pgreact.explain(name, subject, options)` | 0.36.0 implementation and output | Contract `26` bounded answer |
| Rule target | Existing explanation | `rule_match` only |
| Decision target | Existing explanation | `decision_result` only |
| Policy-set target | Existing explanation | Relational `policy_eligibility` only |
| Derived-relation target | Existing explanation | `derived_fact` only |
| Unknown target | Existing target finding | `M40_TARGET_NOT_FOUND` |
| RLS or missing source | Existing behavior | `unavailable` with stable finding |
| Present expected result | Existing explanation | `already_present`, no cause |
| Repeated request | Existing behavior | Same semantic JSON, elapsed time may differ |

M40 does not add a top-level SQL verb, a new evaluator, a stored question, a
background job, or a durable evidence table. The adjacent upgrade is
`0.36.0 -> 0.37.0`. Rollback uses restore from a verified `0.36.0` backup.

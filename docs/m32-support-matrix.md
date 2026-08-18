# M32 support matrix

M32 freezes the ordinary interface. It does not make every historical or
advanced feature part of the ordinary first-rule path.

| Capability | M32 classification | Ordinary expectation |
| --- | --- | --- |
| Typed rule authoring | Ordinary | Use `pgreact.rule` |
| Preview and safe deployment | Ordinary | Preview before `deploy` |
| Global coordination | Ordinary | Use `pgreact.run()` |
| Matches and lifecycle | Ordinary | Query `pgreact.matches` |
| Durable consequences | Ordinary | Query `pgreact.work` and `pgreact.attempts` |
| Explanation and health | Ordinary | Use `pgreact.explain` and `pgreact.health` |
| Policy scope | Ordinary, progressive disclosure | Use named policy-set objects |
| Decisions | Ordinary, progressive disclosure | Use relational candidates and decisions |
| JSON declarations | Compatibility/interchange | Do not teach for first use |
| UUID-first targets | Advanced evidence | Not required for routine work |
| `run_rule`, `run_program`, and similar functions | Compatibility | Not the ordinary coordinator |
| Private catalogs | Internal | Never required for supported ordinary use |
| Derivation, temporal, provenance, and recovery internals | Advanced/administrative | Document separately |
| Unknown or unsupported kinds | Unsupported | Reject before mutation |

The runtime support and performance status of each feature must come from the
executable M32 qualification lane. This document does not turn planned
interfaces into test results.

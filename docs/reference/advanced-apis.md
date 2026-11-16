# Advanced API guide

[Reference](index.md) · [Advanced use](../explanation/advanced-use.md)

This page connects practical advanced tasks to the repository's detailed function and contract records. The ordinary 0.46.0 user guides remain the starting point. The linked specialized records retain their original milestone and release context, so check their exact signatures against the installed catalog and read their bounds before adopting an interface. A record describes the family it names; it does not extend the qualification of every other feature.

## Packages, shared conditions, and parameters

| Task | Public surface | Detailed record |
| --- | --- | --- |
| Reuse a condition across declarations | `pgreact.shared_condition(name, source, key_columns, maintenance_mode)` | [Package reference](../m53-api-reference.md) |
| Supply typed policy parameters | `pgreact.parameter_family(name, parameter_relation, parameter_key, parameter_value_columns)` | [Package reference](../m53-api-reference.md) |
| Deploy related members and support | `pgreact.policy_set` package overload | [Ordinary signature](../api-reference.md#pgreactpolicy_set), [package contract](../m53-contract.md) |
| Inspect a deployed package | `pgreact.policy_set_contents`, `pgreact.policy_set_dependencies` | [Package reference](../m53-api-reference.md) |

Package members are rule and decision declarations; support declarations are shared conditions and parameter families. Dependencies identify typed `from` and `on` endpoints. Validation rejects unsupported endpoints, cycles, missing applicability, and bounds violations. If preview reports `ADOPT`, it requires the exact child identity in the deployment preconditions.

## Hypothetical comparison, replay, and backtesting

| Question | Interface | Required input | Detailed record |
| --- | --- | --- | --- |
| What changes if these rows are inserted, updated, or deleted? | `pgreact.compare` / `compare_results` change-set overload | Typed finite changes with relation, operation, ordinal, key, and the required before/after images. | [Hypothetical comparison API](../m35-api-reference.md), [input contract](../m35-contract.md) |
| What would this policy do over a supplied history? | `pgreact.replay` / `replay_results` | Initial snapshot, schema fingerprints, finite ordered steps, frontiers, and time evidence. | [Replay API](../m36-api-reference.md), [input contract](../m36-contract.md) |
| How do two policy versions differ over that history? | `pgreact.backtest` / `backtest_results` | The same finite replay inputs and a candidate declaration for the deployed target. | [Backtesting API](../m37-api-reference.md), [contract](../m37-contract.md) |
| Why did a supported compared result change? | `why_changed: true` on the supported operation | A supported changed result and complete enough modeled evidence. | [Why-changed API](../m38-api-reference.md), [contract](../m38-contract.md) |

These evaluators do not apply source DML, deploy declarations, create durable work, execute consequences, or discover missing history. `ready` and `partial` describe completeness within the operation's supported model. Relational result functions expose the same bounded evidence as JSON; they do not provide continuation through omitted evidence. For a complete working current-fact example, use [Changing policies safely](../changing-policies.md) before moving to supplied histories.

## Explanations and retained evidence

| Task | Public surface | Detailed record |
| --- | --- | --- |
| Explain an absent result | `pgreact.explain` with `why_not` | [Missing-result API](../m40-api-reference.md), [contract](../m40-contract.md) |
| Follow a decision or work root to public facts | `pgreact.explain` with `causal_path` | [Causal-path API](../m41-api-reference.md), [contract](../m41-contract.md) |
| Retain, read, or delete a supported causal answer | `pgreact_api.capture_evidence_snapshot`, `read_evidence_snapshot`, `delete_evidence_snapshot` | [Snapshot API](../m42-api-reference.md), [contract](../m42-contract.md) |
| Inspect modeled declaration changes | `pgreact_api.semantic_diff` | [Semantic-difference API](../m43-api-reference.md) |
| Use names-first explanation helpers and summaries | `pgreact.why_not`, `trace`, `explanation_summary`, `explanation_capabilities`, evidence helpers | [Helper contract](../m53-ergonomics-contract.md) |

Use [Explain an outcome](../explaining-outcomes.md) for concrete question-led examples. Supported causal roots are decision results, rule work, and decision work, with different required fields for each root. Traversal is bounded by nodes, edges, paths, depth, fanout, and payload; unsupported or inaccessible evidence appears as a boundary rather than a fabricated cause.

Snapshot reads report availability separately from the captured answer's completeness. Capture and deletion are state-changing operations; ordinary explanation and summary operations are read-only. A captured result remains historical and must not be presented as current source truth.

## Derived facts and programs

The [derived-fact contract](../history/m7-contract.md) describes maintained facts and logical supports. The [positive-recursion contract](../history/m8-contract.md) extends that model to bounded positive programs, while the [stratified-negation contract](../history/m9-contract.md) and [aggregation contract](../history/m16-contract.md) describe their respective dependency restrictions. These records use specialized public authoring and recovery interfaces; they are not ordinary rule-constructor options.

Start by identifying the fact identity, support identity, dependency ordering, and the resource bound that limits the result. Inspect the family's public state and explanation before treating the derived output as input to further policies. Removing a support, reconciling a program, and removing an ordinary rule are different operations.

## Time and effective policy

Use the [temporal contract](../history/m12-contract.md), [window contract](../history/m17-contract.md), and [effective-policy contract](../history/m24-contract.md) for the exact model that matches your problem. Their inputs distinguish sampled database time, event-time evidence, watermarks, windows, and effective intervals. Read the relevant boundary and recovery examples before choosing an application clock or late-data policy.

The [parameter-family contract](../history/m25-contract.md) provides additional versioned detail for parameterized policies. For retained evidence and runtime history, the [retention contract](../history/m21-contract.md) defines public configuration, preview, apply, and audit behavior. A throughput figure or qualification result from one family is not a capacity promise for a different workload; use the [limits](../limits.md) and [benchmarks](../benchmarks.md) within their recorded scope.

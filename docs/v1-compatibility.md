# v1 compatibility

> Historical record for the prepared v1 candidate. Use current
> [Compatibility](compatibility.md) for pg-react `0.43.0`.

The v1 feature baseline is M34 / installed extension `0.31.0`. The `1.x`
compatibility promise starts when a qualified `1.0.0` artifact exists; this
page does not claim that an RC or GA artifact already exists.

## Classified installed surfaces

| Classification | Installed evidence-backed surface | Compatibility treatment |
| --- | --- | --- |
| Ordinary | `pgreact.rule`, `decision`, `policy_set`, `validate`, `preview`, `deploy`, `remove`, `run`, `status`, `explain`, `doctor` | Preferred application path; valid calls remain usable through `1.x`. |
| Ordinary views | `pgreact.rules`, `matches`, `decisions`, `policy_sets`, `work`, `attempts`, `health` | Required current meanings remain available through `1.x`; compatible nullable columns may be added. |
| Comparison | `pgreact.compare`, `compare_results`, and `pgreact_api.target` | Supported v1 safe-change surface with the restrictions in the v1 contract. |
| Supported advanced | Installed derivation, temporal/window, shared-condition, provenance, effective-policy, parameter-family, decision-analysis, applicability, and policy-scope families | Supported for their documented advanced purpose; not implied to be ordinary defaults. |
| Compatibility | Installed `pgreact_api` facades and earlier public rule/program wrappers where they delegate to current runtime behavior | Retained for existing callers; not recommended for new ordinary code. |
| Administrative | Role configuration, managed-cycle/status, claim/execute, recovery, reconciliation, retention, repair, and worker-protocol routines | Supported only for the documented operator, worker, recovery, or maintenance task. |
| Historical | Milestone API guides and the historical `0.1.1` files whose names contain `v1` | Evidence/history only; not current API instructions. |
| Private/non-API | `pgreact_internal`, `pgreact_runtime`, private catalogs, and generated dispatch machinery | No application compatibility or manual-repair promise. |

Public callability alone does not make an object ordinary. In particular,
historical grants or an object placed in an implementation schema do not
promote it into the application contract.

## Compatibility rules

Patch releases may contain fixes, security corrections, documentation,
packaging, and semantics-preserving performance work.

Compatible `1.x` additions may include:

- nullable view columns;
- optional, non-conflicting overloads or arguments;
- additional envelope detail fields;
- new advanced capabilities that do not redefine ordinary semantics;
- new finding codes with distinct meanings.

A future major release is required to remove or incompatibly change an
ordinary call, required view meaning, stable finding meaning, lifecycle
guarantee, or comparison contract. Existing declarations either remain valid
or receive an explicit versioned migration.

## Classification still open

This page is deliberately not an exhaustive installed-function inventory. The
exact classification of every overload remains unresolved, including:

- `pgreact.export` and `pgreact.import`;
- legacy worker and recovery functions;
- older `pgreact` rule/program entry points;
- advanced objects exposed through unexpected schemas or historical grants.

The current machine inventory is an M33 snapshot and must not be used to
pretend this classification is complete. Exhaustive classification and
inventory regeneration wait for the exact release-candidate artifact.

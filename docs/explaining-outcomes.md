# Explain an outcome

[How-to guides](how-to/index.md) · [Advanced API guide](reference/advanced-apis.md#explanations-and-retained-evidence)

Start with a precise business question: why did this order go to that queue, why did an expected candidate lose, or why would a proposed policy change the result? pg-react's explanation interfaces answer bounded questions using public identities and evidence. Choosing the question first helps you read the answer correctly instead of treating every explanation as a complete account of arbitrary SQL behavior.

The examples below use the `order-review-route` decision from the [order-review tutorial](order-review-tutorial.md). Run that lesson through its scenario and keep the database before cleanup. Order `1001` has reviewer `201` as its winning candidate; reviewer `202` is a lower-ranked candidate. Use the target, subject, and result identities from your own public state when applying the guide elsewhere.

## Choose the question

| Question | Operation |
| --- | --- |
| What is currently recorded for this subject? | `pgreact.explain(name, subject)` |
| Why is one expected result absent? | `pgreact.explain` with `why_not` |
| Which supported facts led to this decision or work item? | `pgreact.explain` with `causal_path` |
| Why did a supported compared result change? | `pgreact.compare` with `why_changed` |
| Which modeled declaration fields changed? | `pgreact.semantic_diff(proposed)` or the explicit-target `pgreact_api.semantic_diff` |
| Which capabilities does this target expose? | `pgreact.explanation_capabilities(name)` |
| What causal answer was retained earlier? | The public evidence-snapshot read interface. |

Use one question per request. A request that enables both `why_not` and `causal_path` is rejected rather than combining two incompatible interpretations. Different operations retain their own result shapes, so always read the returned state and findings in the context of the operation you asked for.

## Start with current state

Inspect the target and ask about the business subject. A subject's JSON value is not a private catalog identifier; in this example it is the order's bigint key represented as JSON.

```sql
SELECT pgreact.status('order-review-route');
SELECT pgreact.explanation_capabilities('order-review-route');
SELECT pgreact.explain('order-review-route', '1001'::jsonb);
```

Read the public state before asking for a deeper cause. If the source facts have changed but coordination has not yet observed them, an explanation of recorded state is not a promise that the next frontier will be identical. The source frontier, sampled time, and lifecycle or decision revision help identify which observation you are looking at.

## Ask why a candidate did not win

Candidate `202` exists for order `1001`, but its priority is worse than candidate `201`. Ask a finite missing-result question by naming the expected result kind and candidate key:

```sql
SELECT pgreact.explain(
    'order-review-route',
    '1001'::jsonb,
    '{"why_not":{"result_kind":"decision_result","result_key":"202"}}'::jsonb
);
```

Inspect the reported causes and selection evidence. A missing candidate, a losing candidate, tied best candidates, and a subject excluded by applicability are different explanations. Do not convert them into a single generic “rule did not fire” message: their remedies belong to different parts of the application policy.

For an absent ordinary rule match, the corresponding result kind is `rule_match` and the result key is the rule's semantic key. The [missing-result reference](reference/advanced-apis.md#explanations-and-retained-evidence) gives exact shapes for rule matches, decision results, derived facts, and policy eligibility.

## Follow the winning result to its evidence

For a present decision result, request a causal path rooted at the winning candidate:

```sql
SELECT pgreact.explain(
    'order-review-route',
    '1001'::jsonb,
    '{"causal_path":{"root_kind":"decision_result","result_key":"201"}}'::jsonb
);
```

The result contains the supported public root, nodes, edges, paths, boundaries, and findings. A boundary is useful evidence: it can indicate a resource limit, inaccessible predecessor, missing source, unsupported expression, or another reason the operation stopped. Read it rather than filling the gap with an assumed cause.

For a compact application-facing interpretation, pass the detailed answer to the immutable summary helper:

```sql
WITH answer AS (
    SELECT pgreact.explain(
        'order-review-route',
        '1001'::jsonb,
        '{"causal_path":{"root_kind":"decision_result","result_key":"201"}}'::jsonb
    ) AS value
)
SELECT pgreact.explanation_summary(value)
FROM answer;
```

The summary preserves origin state and findings, gives a shared completeness vocabulary, and includes structured next actions without copying the full evidence graph. Keep the detailed answer available when an operator or reviewer needs to examine its boundaries.

## Read the answer

| Part of the answer | How to interpret it |
| --- | --- |
| Public identity | Confirms the target, subject, result, or root being explained. |
| Evidence point | Identifies the declaration, source definition, time, frontier, or revision used. |
| `complete` | The operation checked the causes it supports within its model and limits. It does not claim to explain arbitrary SQL. |
| `partial` | A named bound or missing evidence prevented a complete answer. |
| `unavailable` | The operation could not safely return the requested answer. |
| `unsupported` | The question or input is outside the operation's model. |
| Findings and boundaries | Explain why evidence is incomplete or a request was rejected. |
| Semantic digest | Covers stable modeled meaning; elapsed time is a separate measurement. |

A limit is not proof that no omitted cause exists. Narrow the question or address the reported boundary, then ask again. Authorization also belongs to the observation: a caller with different source access can receive a different safe boundary without either answer being incorrect.

## Separate policy change from outcome cause

A semantic diff describes modeled declaration fields, while comparison with `{"why_changed": true}` can explain supported changes in evaluated outcomes. Use the proposal from [Changing policies safely](changing-policies.md) and add that option when you need the latter question. A field changing between declarations is useful review evidence, but it does not by itself establish why a particular subject's outcome changed.

Current-fact comparison, hypothetical changes, replay, and backtesting each have their own supported input model. When using why-changed evidence, keep the operation's scope and completeness with the answer; a result from a supplied historical scenario is not a statement about unobserved live history.

## Compare two answers safely

Before calling two answers equivalent or contradictory, match their exposed identity inputs: target kind and stable name, immutable version, typed subject or result, root or comparison point, declaration and source-definition digests, sampled time, frontier, revision, comparison sides, and authorization context. If an input is missing or different, treat them as different observations rather than combining the convenient pieces of each.

This is especially relevant when a policy is replaced between observations. The stable name helps you find the policy, but the immutable version and evidence point tell you which policy state the answer actually describes.

## Retain an answer for later review

A supported evidence snapshot captures an earlier causal answer under an explicit identity and capture key. Reading it later reports snapshot availability separately from the nested answer's original completeness. The snapshot remains historical even if the current source now produces a different result, and retention or deletion can affect whether it remains available.

Use the [snapshot API and contract](reference/advanced-apis.md#explanations-and-retained-evidence) for the exact capture, read, delete, and retention inputs. Capture and deletion are intentional writes; explanation and summary calls above are read-only. Store the snapshot identity and review context with the business decision so a later reader knows what was retained and what it did not claim.

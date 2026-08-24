# Practical rule-engine features in pg-react

Related documents: [Product thesis](pg-react_product_thesis.md), [PostgreSQL as an operational data platform](operational-data-platform.md), and [The trifecta](the-trifecta.md).

> Current state: M34 and extension `0.31.0` are the qualified baseline. The repository retains the prepared `1.0.0-rc.1` candidate, but `1.0.0` and its complete feature freeze are postponed indefinitely while development continues one milestone at a time. This document explains the product shape. The [v1 API reference](../docs/v1-api-reference.md), [support matrix](../docs/v1-support-matrix.md), and [known limitations](../docs/v1-known-limitations.md) define the supported contract.

pg-react uses PostgreSQL relations to express policy conditions and candidates. It adds the parts that a query does not retain by itself: semantic identity, lifecycle, deterministic decisions, durable work, versioning, bounded evidence, and safe policy change.

The feature set has moved well beyond the old M18 plan. Decisions, policy sets, shared conditions, effective-dated policies, parameter families, practical temporal rules, and provenance are installed today. M34 also adds read-only comparison of deployed and proposed declarations over current facts. Hypothetical fact changes, historical replay, and backtesting remain outside v1.

## Current feature map

| Capability | v1 state | Current boundary |
|---|---|---|
| Deterministic decisions | Shipped, ordinary API | Lowest numeric priority wins; a tied best priority is `AMBIGUOUS`; no candidates is `NO_CANDIDATE`. |
| Policy sets and applicability | Shipped, ordinary API | A versioned set groups rules and decisions and uses a relation to define eligible subjects. |
| Effective-dated policy | Shipped, advanced API | Versions use explicit half-open validity intervals and database-time transitions. |
| Parameter families | Shipped, advanced API | Parameters remain typed PostgreSQL rows, not text templates or generated rule copies. |
| Declaration comparison | Shipped, ordinary API | Compares a deployed and proposed declaration over current authoritative facts only. |
| Hypothetical facts and backtesting | Not supported in v1 | No fact overrides, historical replay, or backtest API. |
| Shared conditions | Shipped, advanced API | Authors declare named, versioned condition relations and explicit consumers. |
| Practical temporal policy | Shipped, advanced API | Includes deadlines, duration, absence, cooldown, hysteresis, and fixed UTC tumbling windows at their installed contracts. |
| Bounded provenance | Shipped, advanced API | Explains supported derivations and decisions with finite, role-checked evidence. |

## Deterministic decisions

Many business rules select one result from several eligible candidates. A routing policy, for example, may produce several queues for one order. The business needs one winner or a visible ambiguity, not a winner chosen by row order.

SQL produces the candidates:

```sql
CREATE VIEW policy.review_candidates AS
SELECT applicant_id, 10::bigint AS policy_id, 10::bigint AS priority,
	'REJECT'::text AS result
FROM app.applicants
WHERE sanctioned_jurisdiction

UNION ALL

SELECT applicant_id, 20::bigint, 20::bigint, 'SENIOR_REVIEW'::text
FROM app.applicants
WHERE high_risk_industry
	AND annual_revenue > 10000000;
```

The declaration assigns the decision semantics:

```sql
SELECT pgreact.decision(
	name               => 'review-route',
	candidate_relation => 'policy.review_candidates'::regclass,
	subject_key        => 'applicant_id'::name,
	candidate_key      => 'policy_id'::name,
	priority           => 'priority'::name,
	results            => ARRAY['result']::name[],
	max_candidates     => 1000
);
```

The lowest numeric priority wins. Equal best priorities produce `AMBIGUOUS`; pg-react does not invent a tie-breaker. Losing all candidates produces `NO_CANDIDATE`. Winner state has its own generation, revision, competitors, claimability, and explanation evidence.

The advanced decision-analysis family checks policy coverage and conflicts, including tied winners, forbidden overlaps, missing required defaults, and winner-distribution limits.

## Policy sets and applicability

A policy set groups typed rule and decision declarations under one immutable version. A separate applicability relation identifies which subjects are eligible for the set. Eligibility does not mean that a member condition currently matches.

This distinction matters for tenant, region, contract, or product-specific policy. Teams can change membership or applicability without hiding scope predicates inside every rule. `pgreact.policy_set()` exposes this model through the ordinary declaration workflow: `validate`, `preview`, and `deploy`.

## Effective-dated policy

Deployment time and business-effective time are different facts. pg-react supports explicit `[valid_from, valid_to)` intervals so a policy can be installed before it becomes active.

The installed effective-policy family validates intervals, rejects invalid overlap, and records version transitions at a database-time boundary. Work keeps the immutable version identity under which pg-react requested it. Event-time selection is a separate contract and must not be inferred from database-time effective dates.

Ordinary decision and policy-set constructors also expose `valid_from` and `valid_to`. Use the specialized effective-policy APIs when the advanced version schedule and its evidence are required.

## Parameter families

Repeated policy usually differs by data, not logic. A fraud threshold may vary by country; an SLA may vary by plan. PostgreSQL can already express the right model with a join:

```sql
CREATE VIEW rule_def.suspicious_transfer AS
SELECT t.id, t.customer_id, t.amount, p.threshold
FROM app.transfers AS t
JOIN policy.risk_thresholds AS p
	ON p.segment = t.risk_segment
WHERE t.amount > p.threshold;
```

The advanced parameter-family APIs add typed keys, schema validation, ownership, version identity, bounded inspection, and audited changes around the parameter relation. They do not add string substitution, arbitrary JSON parameters, or one generated rule per row.

A parameter change remains a fact change. If a threshold changes, affected subjects pass through the same lifecycle rules as any other change to authoritative data.

## Compare a proposed declaration

`pgreact.compare()` and `pgreact.compare_results()` compare a deployed rule, decision, or policy set with a proposed declaration over the facts that are authoritative now:

```text
current facts + deployed declaration
versus
current facts + proposed declaration
```

The result contains bounded `current`, `proposed`, `delta`, `lifecycle`, and would-be `work` evidence. Comparison does not deploy the proposal, mutate lifecycle state, create durable work, call consequences, or advance a frontier.

This is deployment-impact comparison, not hypothetical fact simulation. `sampled_time` must identify the current authoritative frontier. Rule comparison also requires one non-null, unique `bigint` key, even though separate advanced authoring paths support broader typed keys.

Evidence is bounded from 1 through 1000 rows per requested limit. A larger result is `partial`, has inexact counts, and has no continuation token. Treat the cost envelope as diagnostic evidence, not as a complete capacity model.

## Historical replay and backtesting

Historical replay and backtesting are not supported in v1. pg-react does not retain an authoritative history of every source fact, and M34 comparison does not accept hypothetical inserts, updates, deletes, or past frontiers.

A future backtest would need an explicit historical source, deterministic time progression, isolated lifecycle state, and no consequence execution. It would also need semantic equivalence tests against the production rules. Until that contract exists, use application-owned history and purpose-built SQL analysis without presenting the result as pg-react lifecycle replay.

## Shared conditions

Large policy sets often reuse a business concept such as `high_risk_customer`. PostgreSQL views already allow reuse. The advanced shared-condition family adds a named, versioned policy boundary with typed identity, ownership, source fingerprints, explicit consumers, and bounded explanation.

Sharing is explicit. pg-react does not discover common SQL subplans or rewrite rules around an inferred shared expression. Consumers depend on the declared condition relation, and removal is blocked while those consumers still require it.

## Practical temporal policy

The current temporal features cover common operational questions:

- Has a condition stayed true for a required duration?
- Did a required fact remain absent until a deadline?
- Is a subject still in a cooldown period?
- Has a condition recovered enough to cross a hysteresis boundary?
- Which events belong to a fixed UTC-epoch tumbling window, and is that window final?

These contracts distinguish database time, event time, and worker latency. Durable deadlines, watermarks, ordered corrections, and bounded history let recovery converge without treating a process clock as authoritative.

Rolling or sliding frequency windows and general "A then B" sequence patterns are not part of the v1 promise. Those features would need separate state, ordering, and resource contracts.

## Bounded provenance

pg-react records provenance for supported derived facts, negation, aggregates, windows, and decisions. Public explanations use stable keys and finite evidence rather than physical tuple locations or an unlimited proof tree.

The advanced provenance APIs expose canonical support ordering, counts, grounded or cyclic markers, truncation, and unavailable evidence where the installed contract permits them. Access requires the configured provenance reader or advanced-reader role, the relation owner, or an operator.

The current contract provides evidence for supported derived facts and decisions that exist or changed. pg-react does not promise general SQL lineage or an exhaustive answer to every "why not" question.

## Keep the PostgreSQL boundary

SQL should produce facts, candidates, and relationships. pg-react should own the durable semantics that SQL alone does not define: identity, lifecycle, version selection, ambiguity, work, and bounded explanation.

That boundary rules out a second expression language, parameter templates, hidden source mutation, and arbitrary policy bytecode. It also explains the remaining v1 limits. pg-react is not a synchronous write hook, a global-ordering service, a distributed transaction coordinator, or a general workflow engine. External delivery is at least once, so consumers must deduplicate.

For executable examples, start with [Authoring rules and policies](../docs/v1-authoring.md) and the [order review showcase](../showcase/order-review/README.md).

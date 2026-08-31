# Practical rule-engine features in pg-react

Related documents: [Product thesis](pg-react_product_thesis.md), [PostgreSQL as an operational data platform](operational-data-platform.md), and [The trifecta](the-trifecta.md).

> Current state: M40 and extension `0.37.0` are the qualified baseline. M41 end-to-end causal paths is the next logical candidate. The repository retains the prepared `1.0.0-rc.1` candidate, but `1.0.0` and its complete feature freeze are postponed indefinitely. This document explains the product shape. The [v1 API reference](../docs/v1-api-reference.md), [support matrix](../docs/v1-support-matrix.md), and [known limitations](../docs/v1-known-limitations.md) define the supported contract.

A rule engine answers questions such as "Which orders need review?" or "Where should this applicant go next?" In pg-react, ordinary PostgreSQL tables and views describe the facts, policy conditions, and possible results. pg-react then supplies the behavior that a query does not preserve on its own: stable identity, a lifecycle for each result, repeatable decisions, durable work, policy versions, limited supporting evidence, and a safe way to change policy.

The available features now go well beyond the old M18 plan. Decisions, policy sets, shared conditions, effective-dated policies, parameter families, practical time-based rules, and provenance are installed today. M34 through M39 let teams compare a deployed declaration with a proposal over current or typed hypothetical facts, replay caller-supplied history, backtest at most two policies, and inspect bounded why-changed evidence without changing production state.

## What v1 supports

| Capability | v1 state | What it means in practice |
|---|---|---|
| Deterministic decisions | Shipped, ordinary API | The lowest numeric priority wins. If the best priority is tied, the result is `AMBIGUOUS`. If nothing qualifies, the result is `NO_CANDIDATE`. |
| Policy sets and applicability | Shipped, ordinary API | A versioned set groups rules and decisions. A separate PostgreSQL relation identifies the subjects that may use the set. |
| Effective-dated policy | Shipped, advanced API | Explicit half-open validity intervals determine when versions apply, and the database records transitions using database time. |
| Parameter families | Shipped, advanced API | Parameters stay in typed PostgreSQL rows. pg-react does not turn them into text templates or copied rules. |
| Declaration comparison | Shipped, ordinary API | Teams can compare a deployed declaration with a proposed declaration over the authoritative facts that exist now. |
| Hypothetical facts and backtesting | Shipped, qualified API | Teams can apply typed hypothetical changes, replay caller-supplied history, and compare at most two policies over that history. |
| Shared conditions | Shipped, advanced API | Authors name and version reusable condition relations, then state which policies consume them. |
| Practical temporal policy | Shipped, advanced API | The installed contracts cover deadlines, duration, absence, cooldown, hysteresis, and fixed UTC tumbling windows. |
| Bounded provenance | Shipped, advanced API | Explanations show finite, role-checked evidence for supported decisions and derived facts. |

## Choosing one result predictably

Many business policies can produce several possible results for one subject. A routing policy might send the same order to several queues, for example. The business still needs one winner, or a clear warning that the policy cannot choose. It must not depend on whichever database row happens to appear first.

SQL produces the possible results, which pg-react calls candidates:

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

The declaration tells pg-react how to identify the applicant and each candidate, which column contains the priority, and which values form the result:

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

The lowest numeric priority wins. If two candidates share the best priority, pg-react returns `AMBIGUOUS` instead of inventing a tie-breaker. If no candidate remains, it returns `NO_CANDIDATE`. pg-react tracks the winning state separately, including its generation, revision, competing candidates, whether a worker can claim it, and the evidence that explains it.

The advanced decision-analysis family examines whether a policy covers the intended cases and whether its candidates conflict. Its checks include tied winners, overlaps that the policy forbids, required defaults that are missing, and limits on how winners are distributed.

## Grouping policies and defining who they apply to

A policy set groups typed rule and decision declarations under one version that cannot change. A separate applicability relation lists the subjects that are eligible for that policy set. An eligible subject may use the set, but that does not mean a member rule currently matches the subject.

Keeping eligibility separate helps with policies that differ by tenant, region, contract, or product. Teams can change which declarations belong to a set, or which subjects are eligible for it, without copying a scope condition into every rule. `pgreact.policy_set()` uses the ordinary declaration workflow: `validate`, `preview`, and `deploy`.

## Scheduling when a policy applies

The time when a team deploys a policy is not always the time when the business wants it to take effect. pg-react accepts explicit `[valid_from, valid_to)` intervals, which include the start and exclude the end. A team can therefore install a policy before its active period begins.

The installed effective-policy family checks these intervals, rejects invalid overlap, and records version changes at a boundary measured by the database clock. Any work created under a version keeps that version's immutable identity. Choosing a version according to the time recorded in an event is a different contract. Code must not treat database-time effective dates as event-time selection.

The ordinary decision and policy-set constructors also accept `valid_from` and `valid_to`. Use the specialized effective-policy APIs when a policy needs the advanced version schedule and its supporting evidence.

## Keeping policy differences in data

Policies often share the same logic but use different values. A fraud threshold might vary by country, while an SLA might vary by plan. PostgreSQL already represents this pattern well: store the values as rows and join them to the business data.

```sql
CREATE VIEW rule_def.suspicious_transfer AS
SELECT t.id, t.customer_id, t.amount, p.threshold
FROM app.transfers AS t
JOIN policy.risk_thresholds AS p
	ON p.segment = t.risk_segment
WHERE t.amount > p.threshold;
```

The advanced parameter-family APIs put controls around that parameter relation. They add typed keys, schema validation, ownership, version identity, limited inspection, and an audit trail for changes. They do not substitute values into text, accept arbitrary JSON parameters, or generate one copy of a rule for every row.

A parameter change is still a change to a fact. If someone changes a threshold, pg-react sends affected subjects through the same lifecycle rules that apply to any other change in authoritative data.

## Comparing a proposed declaration

Before deployment, `pgreact.compare()` and `pgreact.compare_results()` can show how a proposed rule, decision, or policy set differs from the deployed declaration. Both versions run against the authoritative facts that exist now:

```text
current facts + deployed declaration
versus
current facts + proposed declaration
```

The result contains limited evidence for `current`, `proposed`, `delta`, `lifecycle`, and the `work` that the proposal would create. The comparison is read-only. It does not deploy the proposal, change lifecycle state, create durable work, call consequences, or change the point through which pg-react considers the facts current.

This current-fact form measures the effect of a declaration change.
`sampled_time` must name the current authoritative frontier, which is the point
through which pg-react considers the facts current. The M35 overload accepts
typed hypothetical changes. Rule comparison also requires one unique,
non-null `bigint` key, although separate advanced authoring paths accept a
wider range of typed keys.

Each requested limit can return from 1 through 1000 evidence rows. If the result is larger, pg-react marks it `partial`, reports inexact counts, and provides no continuation token. This cost information helps with diagnosis, but it is not a complete capacity model.

## Why replay requires caller-supplied history

pg-react does not keep an authoritative history of every source fact. M36
replay therefore requires an explicit snapshot and finite ordered history from
the caller. M37 backtesting runs at most two policies over that same history.
Both operations isolate lifecycle state and execute no consequences.

Current facts cannot reconstruct missing history. A replay claim is valid only
for the supplied inputs, logical times, and source progress.

## Reusing shared conditions

Large policy sets often repeat a business idea such as `high_risk_customer`. PostgreSQL views already let teams define that condition once and reuse it. The advanced shared-condition family adds a named and versioned policy boundary around the view, with typed identity, ownership, source fingerprints, an explicit list of consumers, and limited explanation evidence.

Authors must declare sharing. pg-react does not search for matching SQL subplans or rewrite rules around an expression that looks shared. Consumers depend on the declared condition relation, and pg-react blocks removal while any declared consumer still needs it.

## Handling time-based policy

The current time-based features answer common operational questions. They can determine whether a condition stayed true for a required duration, whether a required fact remained absent until a deadline, whether a subject remains in a cooldown period, and whether a value recovered enough to cross a hysteresis boundary. They can also assign events to fixed windows that start from the UTC epoch and report whether a window is final.

These contracts keep three kinds of time separate: the database clock, the time recorded in an event, and the delay before a worker processes it. Durable deadlines, watermarks that record progress, ordered corrections, and limited history allow recovery to converge without treating a process clock as the source of truth.

v1 does not promise rolling or sliding frequency windows, or general sequences such as "A then B." Those features need their own rules for state, ordering, and resource use.

## Explaining results with bounded provenance

Provenance is the evidence that shows where a result came from. pg-react records this evidence for supported derived facts, missing facts used as conditions, aggregates, windows, and decisions. Public explanations use stable keys and a finite amount of evidence. They do not depend on physical tuple locations or attempt to return an unlimited proof tree.

The advanced provenance APIs return supporting items in a standard order, along with counts and markers that say whether the evidence is grounded, cyclic, shortened, or unavailable where the installed contract permits those states. Access is limited to the configured provenance reader or advanced-reader role, the relation owner, or an operator.

The current contract explains supported derived facts and decisions that exist or changed. pg-react does not provide general lineage for every SQL query, and it does not promise a complete answer to every question about why something did not happen.

## Keeping PostgreSQL and pg-react in distinct roles

SQL produces facts, candidates, and relationships. pg-react owns the durable meaning that SQL alone does not define, including identity, lifecycle, version selection, ambiguity, work, and limited explanations.

This division leaves several features outside the product. pg-react does not add a second expression language, parameter templates, hidden changes to source data, or arbitrary policy bytecode. It is also not a synchronous write hook, a service that imposes one global order, a distributed transaction coordinator, or a general workflow engine. Delivery to external consumers happens at least once, so consumers must remove duplicates.

For executable examples, start with [Authoring rules and policies](../docs/v1-authoring.md) and the [order review showcase](../showcase/order-review/README.md).

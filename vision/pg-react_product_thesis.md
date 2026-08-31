# Why pg-react exists

Related documents: [Practical rule-engine features](pg-react_practical_rule_engine_features.md), [PostgreSQL as an operational data platform](operational-data-platform.md), and [The trifecta](the-trifecta.md).

> Current state: M39 and extension `0.36.0` are the qualified baseline. M40 bounded why-not is the current planning milestone. The repository retains the prepared `1.0.0-rc.1` candidate, but `1.0.0` and its complete feature freeze are postponed indefinitely. The [documentation home](../docs/index.md) and [support matrix](../docs/v1-support-matrix.md) define the current product contract.

Modern applications already contain rule engines, even when nobody calls them that. A rule engine watches facts, checks whether they meet a condition, and decides what must happen next. In a typical application, those rules are scattered through service branches, scheduled queries, database triggers, retry workers, and exception tables. One branch notices that a customer crossed a risk threshold. Another job finds an overdue invoice. Other code updates access after a role change or stops deletion when a legal hold begins.

Checking one condition is rarely difficult. The difficult part is remembering what the condition has already caused as the underlying data changes. The system must survive retries, policy changes, and crashes without treating old work as new or losing track of why the work exists. pg-react solves that problem inside PostgreSQL.

## Rules become durable policy state

A query can show that an invoice is overdue now, but the result only describes the present. It does not remember when the invoice first became overdue, whether the system already created collection work, whether the invoice recovered and later became overdue again, or whether a worker crashed after claiming that work.

pg-react gives every logical match a stable business identity, called a semantic identity. For example, the identity can be the invoice rather than a particular database row update. pg-react then records the match as a lifecycle: the condition becomes true, may change while it remains true, becomes false, and may later become true again. That later return starts a new generation, which represents a new continuous period of truth and prevents stale work from the earlier period from coming back to life.

A constraint rule records which facts currently satisfy a policy. A command rule can also attach a typed consequence and create durable work. pg-react records claims, leases, retries, attempts, and recovery so operators can inspect what happened after a process fails. The result is more than a friendlier database trigger. It is a durable policy layer for relational data.

## PostgreSQL remains the source of truth

When PostgreSQL already owns the business facts, copying them into another rule system creates a second identity system, permission model, recovery path, and transaction boundary. The copied state can disagree with the database that still owns the customer, invoice, order, or access record.

pg-react keeps the facts and the rules close together. Conditions and candidates remain ordinary PostgreSQL relations, which means tables, views, or query results. Developers declare rules as typed SQL values. PostgreSQL also stores the lifecycle, decisions, work, attempts, and explanations, so operators can inspect them with SQL. When a consequence changes database records, PostgreSQL transactions keep those changes together with the related pg-react state changes.

Some boundaries remain. A source used for evaluation must follow the documented ownership and access rules, and pg-react rejects sources protected by row-level security. Key support also depends on the API. Advanced authoring supports a wider range of typed keys, while rule comparison requires one unique, non-null `bigint` key.

## What pg-react provides now

The ordinary v1 workflow uses `pgreact.rule()`, `pgreact.decision()`, and `pgreact.policy_set()`. Each supports the same three verbs: `validate` checks a declaration, `preview` shows what it means, and `deploy` makes it active. Stable names also let developers check `status`, ask pg-react to `explain`, or `remove` a declaration. Public views show current matches, decisions, policies, work, attempts, and health.

A decision handles cases where several valid answers compete for the same subject. Each candidate has a numeric priority, and the lowest number is best. If two candidates tie for the best priority, pg-react reports the ambiguity instead of silently choosing one. A policy set groups versioned rules and decisions and uses a relation to say where that policy applies.

The installed advanced APIs cover derived facts, positive recursion, stratified negation and aggregation, shared conditions, time-based policy, effective dates, parameter families, bounded provenance, and decision analysis. In plain terms, these features let one fact depend on another, let rules refer back to earlier results within controlled limits, express the absence or summary of facts safely, share repeated conditions, schedule policy versions, vary rules by relational parameters, and retain a limited chain of supporting evidence. They are supported APIs, but a developer does not need them to write a first rule.

PostgreSQL-managed workers provide the normal runtime. They evaluate rules and execute work after the source data commits. pg-react does not intercept a write and accept or reject it before the transaction finishes.

## Operational policy is the main use case

pg-react fits ordinary business controls whose truth changes over time. Examples include financial exceptions and reconciliation, access drift and deprovisioning, retention eligibility and legal holds, security exceptions and expired approvals, and intervention for inventory, service-level agreements, billing, or data quality.

These cases have the same basic shape. Several facts in PostgreSQL combine into a condition. The important event is not every physical row update, but the moment when the business condition becomes true, changes, or stops being true. The response needs durable state, durable work, or both. pg-react does not need unrestricted logical inference to handle that job. It needs a predictable lifecycle, deterministic policy, and evidence that an operator can query.

## Policy changes need evidence

Policy often changes on a different schedule from application code. Thresholds move, contracts renew, regulations take effect, and routing priorities change. Before a team deploys a new version, it needs to see how the proposed policy differs from the current one.

pg-react compares a proposal with deployed behavior over current facts or typed hypothetical changes. It can also replay caller-supplied history and backtest at most two policy versions over that history. Bounded why-changed evidence identifies modeled causes for a supported difference.

These operations report current and proposed results, lifecycle changes, decisions, and would-be work without deploying the proposal or executing effects. M39 qualifies their shared identities, limits, authorization, and no-effect behavior. pg-react does not capture missing history, retain a simulation job, or answer arbitrary counterfactual questions about SQL.

## Explanation is part of correctness

A financial control that blocks a journal must identify the policy and evidence behind that result. An access decision must show which policy version applied. When one rule derives a new fact from other facts, an operator needs enough supporting evidence to understand why the derived fact exists.

pg-react provides bounded explanations and advanced provenance for the rule behavior it supports. Provenance is the recorded connection between a result and the facts that support it. The explanation is deliberately finite. pg-react does not promise to trace arbitrary SQL, build an unlimited proof tree, or reveal source data that the caller cannot otherwise read. A limit on evidence is part of the product guarantee because an explanation that can consume unlimited work is not safe operational evidence.

## The product has clear limits

pg-react does not synchronously approve authorization requests. It does not impose one global order on all work, coordinate distributed transactions, solve optimization problems, or replace a general workflow and human-task platform.

An outbox row also cannot make an external effect happen exactly once. Delivery is at least once, so a consumer must recognize a repeated message by its stable identity and avoid applying it twice. Independent workers remain concurrent. For a logical restore, restore the application data, replay declarations, rebuild pg-react state, and reconcile the result. pg-react does not claim that live private catalogs can be restored portably.

The release candidate has a narrow qualified boundary: PostgreSQL 18.3, pg_trickle 0.81.0, Linux `amd64`, `READ COMMITTED`, coordinated refresh, and the PostgreSQL-managed runtime. The [support matrix](../docs/v1-support-matrix.md) records the exact settings and build facts. Other combinations remain unqualified until the repository produces evidence for them.

## The product test

An ordinary PostgreSQL developer should be able to describe a policy with relations and typed declarations, inspect the current decision with SQL, compare a proposed declaration without causing effects, and recover durable work without learning private engine identifiers.

The implementation may need strata, supports, watermarks, corrections, leases, and recovery state. These internal terms describe how the engine orders dependent rules, records evidence, tracks evaluation progress, handles revised results, lends work to a worker for a limited time, and recovers after failure. The public model should remain smaller: facts, conditions, lifecycle, decisions, policy, work, and evidence.

pg-react succeeds when it turns PostgreSQL facts into durable policy state and work while preserving PostgreSQL's types, permissions, transactions, and familiar SQL inspection model.

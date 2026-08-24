# Why pg-react exists

Related documents: [Practical rule-engine features](pg-react_practical_rule_engine_features.md), [PostgreSQL as an operational data platform](operational-data-platform.md), and [The trifecta](the-trifecta.md).

> Current state: M34 and extension `0.31.0` are the qualified baseline. The repository retains the prepared `1.0.0-rc.1` candidate, but `1.0.0` and its complete feature freeze are postponed indefinitely while development continues one milestone at a time. The [documentation home](../docs/index.md) and [support matrix](../docs/v1-support-matrix.md) define the current product contract.

Modern applications already contain rule engines. They hide in service branches, scheduled queries, triggers, retry workers, and exception tables. A customer crosses a risk threshold. An invoice becomes overdue. A role change requires new access. A legal hold suspends deletion.

The predicate is rarely the hard part. The hard part is turning changing relational truth into durable, explainable work without losing identity across retries, policy changes, and recovery.

pg-react exists to solve that problem inside PostgreSQL.

## The product is durable policy state

A query can show that an invoice is overdue now. The query does not remember when the condition began, whether it already created work, whether the invoice recovered and later became overdue again, or whether a worker crashed after claiming the work.

pg-react gives each logical match a semantic identity. It records activation, change, deactivation, and reactivation as a durable lifecycle. A reactivation starts a new generation rather than reviving stale work from the previous active period.

Constraint rules record current policy truth. Command rules may bind typed consequences and create durable work. Claims, leases, retries, attempts, and recovery keep that work inspectable after process failure.

This is more useful than "database triggers, but nicer." pg-react is a durable policy layer for relational state.

## PostgreSQL remains authoritative

When PostgreSQL already owns the facts, copying them into another rule runtime creates another identity system, permission model, recovery path, and transaction boundary. The rule engine can then disagree with the database that still owns the business record.

pg-react takes the opposite position. Conditions and candidates remain ordinary PostgreSQL relations. Declarations are typed SQL values. Lifecycle, decisions, work, attempts, and explanations remain queryable in PostgreSQL. Database consequences and pg-react state changes use PostgreSQL transactions.

This does not erase every boundary. Evaluated sources must satisfy the documented ownership and access rules. RLS-protected sources are rejected. Key support also depends on the API: advanced authoring supports wider typed keys, while rule comparison requires one non-null, unique `bigint` key.

## What pg-react provides now

The ordinary v1 workflow uses `pgreact.rule()`, `pgreact.decision()`, and `pgreact.policy_set()` with the same verbs: `validate`, `preview`, and `deploy`. Stable names support `status`, `explain`, and `remove`. Public views expose current matches, decisions, policies, work, attempts, and health.

Decisions treat the lowest numeric priority as best for each subject and expose ambiguity instead of choosing an arbitrary winner. Policy sets group versioned rules and decisions and use a relation to define applicability.

Installed advanced families add derived facts, positive recursion, stratified negation and aggregation, shared conditions, temporal policy, effective dates, parameter families, bounded provenance, and decision analysis. These are supported APIs, but they are not required for the ordinary first-rule path.

PostgreSQL-managed workers are the normal runtime. Evaluation and work execution happen after source data commits; pg-react is not a synchronous write-path hook.

## Operational policy is the main use case

The best pg-react use cases are ordinary business controls whose truth changes over time:

- financial exceptions and reconciliation;
- access drift and deprovisioning;
- retention eligibility and legal holds;
- security exceptions and expired approvals;
- inventory, SLA, billing, and data-quality intervention.

These problems share one shape. Several PostgreSQL facts form a relational condition. The transition matters more than another physical row update. The response needs durable state, work, or both.

pg-react does not need unrestricted inference to be valuable. It needs predictable lifecycle, deterministic policy, and evidence an operator can query.

## Policy change needs evidence

Policy changes on a different schedule from application code. Thresholds move, contracts renew, regulations take effect, and routing precedence changes. A policy engine earns its place when teams can inspect and compare those changes before deployment.

pg-react now supports effective-dated policy, relational parameter families, deterministic decisions, decision analysis, and versioned policy sets. M34 adds `pgreact.compare()` and `pgreact.compare_results()` for read-only comparison of a deployed declaration with a proposal over current authoritative facts.

Comparison reports bounded current, proposed, delta, lifecycle, and would-be work evidence. It does not deploy the proposal or execute effects. A partial result has inexact counts and no continuation token.

The current feature is narrower than general simulation. The M34 baseline does not apply hypothetical fact changes and does not provide historical replay or backtesting. Those remain future directions, not current product claims.

## Explanation is part of correctness

A financial control that blocks a journal must identify the policy and evidence behind the result. An access decision must expose which version applied. A derived fact should expose enough support evidence to explain why it exists.

pg-react provides bounded explanation and advanced provenance for the semantics it supports. The boundary matters. It does not promise arbitrary SQL lineage, an infinite proof tree, or access to source data that the caller cannot otherwise read.

Finite evidence is a product guarantee, not a weakness. An explanation that can consume unbounded work is not operational evidence.

## The product has clear limits

pg-react is not a synchronous authorization proxy, a global-ordering service, a distributed transaction coordinator, an optimization solver, or a general workflow and human-task platform.

An outbox row cannot make an external effect exactly once. Delivery is at least once, and consumers must deduplicate by stable identity. Independent workers remain concurrent. Logical restore uses application data plus declaration replay, rebuild, and reconciliation; pg-react does not claim portable restoration of live private catalogs.

The release candidate also has a narrow qualified boundary. It includes PostgreSQL 18.3, pg_trickle 0.81.0, Linux `amd64`, `READ COMMITTED`, coordinated refresh, and the PostgreSQL-managed runtime. The [support matrix](../docs/v1-support-matrix.md) records the exact settings and build facts. Other combinations are unqualified until the repository produces evidence for them.

## The product test

An ordinary PostgreSQL developer should be able to describe a policy with relations and typed declarations, inspect the current decision with SQL, compare a proposed declaration without effects, and recover durable work without learning private engine identifiers.

The implementation can contain strata, supports, watermarks, corrections, leases, and recovery state. The public model should stay smaller: facts, conditions, lifecycle, decisions, policy, work, and evidence.

pg-react succeeds when PostgreSQL truth becomes durable policy state and action intent without leaving PostgreSQL's type, permission, transaction, and inspection model behind.

# The post-v0.43.1 vision for pg-react

> Release baseline (September 2026): M54 and extension `0.43.1` are the
> qualified baseline for this vision. `1.0.0` remains postponed indefinitely.
> [`ROADMAP.md`](../ROADMAP.md) is the canonical delivery plan.

Related documents: [Product thesis](pg-react_product_thesis.md),
[Practical rule-engine features](pg-react_practical_rule_engine_features.md),
and [PostgreSQL as an operational data platform](operational-data-platform.md).

pg-react turns changing PostgreSQL facts into durable policy state and work.
PostgreSQL owns the facts. Authors use relations, views, and typed SQL
declarations. pg-react records stable result identity, lifecycle, decisions,
work, attempts, and bounded explanations.

The project no longer needs a 30-milestone feature sequence. `0.43.1` already
contains a broad rule engine and, more importantly, one ordinary path for
creating, reviewing, deploying, replacing, inspecting, and recovering rules,
decisions, and policy sets. The next releases should prove that product in real
installations and remove blockers found there. They should not add semantics
because an old vision document reserved a milestone number for them.

## What v0.43.1 establishes

M54 makes the existing product easier to adopt without adding rule, decision,
temporal, reasoning, workflow, or distributed-system semantics. Its ordinary
path has stable names and a common `validate`, `preview`, review, `deploy`, and
inspect workflow. Review tokens bind deployment to a reviewed plan but grant no
permission. Stable-name recovery keeps internal UUIDs out of normal operations.

The baseline also fixes the product boundary:

- PostgreSQL remains the authoritative fact store and transaction boundary.
- Rules, decisions, policy sets, lifecycle, work, and explanations remain
  inspectable through public SQL.
- Comparison and evidence are bounded and may report partial results.
- External effects are delivered at least once, so consumers must deduplicate.
- The qualified environment is PostgreSQL 18.3, pg_trickle 0.81.0, pgrx 0.18.0,
  Linux `amd64`, `READ COMMITTED`, and the PostgreSQL-managed runtime.
- Existing advanced APIs do not automatically belong in the ordinary,
  qualified workflow.

The [M54 contract](../docs/m54-contract.md),
[release notes](../docs/m54-release-notes.md), and
[known limitations](../docs/m54-known-limitations.md) define the exact release.

## How the next milestone is chosen

The project commits to one milestone at a time after the `0.43.1` field-evidence
period. Five candidates remain. Their identifiers preserve continuity with the
roadmap and release history; their numbers do not prescribe delivery order.

Selection follows three rules:

1. M55 or M56 starts immediately when schema change, rebuild, restore, failover,
   or reconciliation evidence exposes a safety problem.
2. M58 or M45 starts when a real prospective installation is blocked by
   authorization or rolling and hopping windows.
3. Otherwise, M59 is the default next milestone after the field-evidence period.

A candidate enters the committed horizon only with a named blocking workload,
executable acceptance criteria, and an owner. The release after it is selected
from the evidence it produces.

## The five candidates

### M59: Qualify supported scale

M59 is the default next milestone. It measures the operating boundary of the
current product rather than adding a performance feature.

Qualification must publish repeatable curves for rule count, match count,
fan-out, reevaluation, cascade depth, lifecycle churn, work throughput,
decision candidates, package replacement, comparison size, catalog growth,
write-ahead log volume, retention, restart, backup and restore, reconciliation,
and sustained overload. It must cover both many-rules/few-matches and
few-rules/many-matches workloads, including no-change cycles and bursts of
command work.

Reports must show latency growth, backpressure, or failure instead of hiding
the point where a workload leaves the supported range. A metric that cannot be
measured faithfully is `unavailable`, not an estimate presented as evidence.
M59 succeeds when an operator can decide whether a proposed installation fits
inside published limits and can predict recovery cost at that limit.

### M58: Align with PostgreSQL authorization

M58 starts only when PostgreSQL grants, security context, or row-level security
blocks a real workload that otherwise fits pg-react.

The milestone must state whose authority applies during evaluation,
explanation, comparison, simulation, work claiming, and administration. It
should use PostgreSQL roles, ownership, and grants wherever they express the
required rule. Unsupported configurations must fail during validation, and
bounded explanations must not reveal facts the caller cannot read.

M58 does not promise general RLS support. It qualifies the smallest security
configuration that removes the observed blocker while preserving repeatable
evaluation, recovery, and evidence.

### M45: Qualify rolling and hopping windows

M45 starts only when missing event-time windows block an otherwise suitable
policy. Its job is to bring rolling and hopping windows into the qualified
ordinary path, not to create a general event-processing language.

Authors must declare the event-time source, window size, hop, late-event rule,
correction horizon, and retention bound. Source progress, not worker wall-clock
timing, decides when a result is complete. The same facts, time inputs, source
progress, and retained correction state must produce the same result after
restart, replay of database recovery, or rule replacement.

The milestone should support the smallest window profile required by the
blocking workload. Business calendars, arbitrary event sequences, and other
temporal forms wait for separate evidence.

### M55: Make schema changes safe

M55 starts when ordinary PostgreSQL DDL cannot be shown safe for deployed
policies. Before a supported change to a table, column, type, function, or view,
pg-react must identify affected declarations and show the safe order for
replacement or removal.

PostgreSQL dependencies and exact object identities remain authoritative.
pg-react adds rule-specific validation, findings, and preview. It does not add
a schema registry or attempt to interpret arbitrary migration tools.

M55 succeeds when an operator can plan and execute a supported schema change
without silently invalidating evaluation, losing durable work, or joining
private catalogs.

### M56: Make rebuild and reconciliation safe

M56 starts when rebuild, restore, failover, or reconciliation behavior blocks
an operating decision. Public SQL must show why a rebuild is required, which
declarations it affects, how far it has progressed, what work remains blocked,
and whether rebuilt state agrees with authoritative source data.

The engine must preserve durable match state and work that the rebuild does not
affect. If it cannot prove agreement between old and rebuilt state, it must stop
the affected operation and report the reason. Operators must be able to tell
when workers may resume without relying on a private repair procedure.

## Requirements carried by every release

Each selected milestone must pass the same release checks:

- Use the existing ordinary authoring, review, deployment, inspection, and
  recovery path unless evidence proves that path cannot express the feature.
- Test exact public SQL results for fresh installation, adjacent upgrade,
  failure, restart, backup and restore, and the relevant concurrency cases.
- Publish latency, writes, write-ahead log volume, storage, retention, and
  recovery costs at the claimed boundary. Mark unavailable measurements.
- Apply PostgreSQL ownership and authorization consistently and test that
  explanations do not leak evidence.
- Reject unsupported combinations during validation.
- Include a migration guide, support matrix, known limitations, and executable
  qualification evidence for the exact release artifact.
- Use at least one workload from a design partner, external evaluator, or real
  application migration before widening the supported contract.

These are release requirements, not future cleanup milestones. A feature that
works alone but makes the ordinary path harder to teach should remain advanced,
be narrowed, or be removed.

## What is no longer a milestone sequence

The former M46 through M49 temporal sequence is deferred. M45 must first show
that qualified windows solve a real adoption problem. Business calendars,
finite event sequences, and absence-after-event rules need their own evidence
before they return to the roadmap.

The former M50 through M52 interaction sequence is also deferred. pg-react
already has advanced firing, conflict, derivation, and recursion behavior.
More interaction semantics require a blocking workload and an explanation
model that operators can use through public SQL.

Long-lived history from M57 is part of M59 retention, storage, and recovery
qualification. The former M60 through M62 goals of one authoring, inspection,
and recovery model now apply to every release. Production qualification is
continuous rather than a separate M63 gate. M64 and a `2.0.0` feature freeze no
longer define the destination while `1.0.0` itself remains postponed.

## Scope stays narrow

Every candidate must preserve these limits:

- SQL and typed PostgreSQL relations remain the rule and fact model.
- pg-react owns only state and semantics that SQL does not retain by itself.
- Results stay deterministic, bounded, recoverable, and inspectable.
- PostgreSQL transactions decide database-local state changes.
- Unsupported combinations stop during validation rather than fail later.
- No client-language DSL, visual or AI authoring system, or hosted control plane.
- No general workflow engine, approval router, or arbitrary event processor.
- No cross-database transaction model or exactly-once external delivery claim.

## The destination

pg-react should be the rule engine a PostgreSQL team chooses when a changing
condition over relational data must become durable, explainable state or work.
A developer should be able to define a policy, compare a proposed change,
deploy a reviewed plan, inspect an outcome, recover from failure, and upgrade
the extension through public SQL and ordinary PostgreSQL operations.

`0.43.1` is the baseline for proving that product. The next release should
remove the most important blocker found in use. If field evidence does not
justify a new capability, the correct roadmap decision is to improve the
current product without inventing another milestone.
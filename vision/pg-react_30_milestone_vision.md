# The M35-M64 vision for pg-react

> Planning status (August 2026): M34 is complete, extension `0.31.0` is the v1 feature boundary, and the repository targets `1.0.0-rc.1`. The release-candidate cycle and `1.0.0` come before M35. [`ROADMAP.md`](../ROADMAP.md) remains the canonical milestone schedule.

Related documents: [Product thesis](pg-react_product_thesis.md), [Practical rule-engine features](pg-react_practical_rule_engine_features.md), and [PostgreSQL as an operational data platform](operational-data-platform.md).

pg-react should first and foremost be an excellent PostgreSQL-native rule engine. PostgreSQL owns the facts. SQL expresses conditions and candidates. pg-react adds durable identity, lifecycle, decisions, work, time, and bounded evidence.

That is enough scope for a substantial product. pg-react does not need to become a hosted policy service, a general workflow system, a visual authoring suite, a distributed event processor, or a second programming language. It should make relational rules unusually safe to run and change.

The initial product wedge is auditable operational control over business data that PostgreSQL already owns. Financial exceptions and access drift are the reference markets because they value durable lifecycle, safe policy change, explanation, reconciliation, and recovery. They should break ties in sequencing without limiting the engine to those domains.

This vision starts at M35 and covers another 30 possible milestones. M35 follows the contract in `ROADMAP.md`. M36 through M64 describe an option space, not a queue or a promise to implement every item. The numbers are stable references. Evidence may reorder, merge, replace, or permanently reject any directional milestone.

## Decision horizons

### Committed horizon

The only committed sequence is the release-candidate cycle, `1.0.0`, and the entry gate that precedes M35. Work beyond M35 enters the canonical roadmap only with executable acceptance criteria, an owner, and evidence that it advances the product wedge.

### Strategic horizon

The first post-v1 vertical slice should combine hypothetical fact simulation (M35), semantic policy differences (M43), why-changed comparison (M38), and end-to-end causal paths (M41), then pass the simulation qualification gate (M39). This gives operators one safe-change journey from proposal to explanation.

The first qualified slice may restrict declaration kinds, key shapes, hypothetical change forms, and evidence depth. It must still deliver the complete proposal-to-explanation journey for its supported subset.

Policy-set packaging (M53), DDL impact planning (M55), rebuild and reconciliation (M56), authorization alignment (M58), and supported-scale qualification (M59) are also strategic. Their implementation should advance alongside earlier capabilities rather than wait for every temporal or rule-interaction milestone.

### Research horizon

Historical replay and comparative backtesting (M36-M37) remain research until representative users establish workable source-history contracts. New temporal forms and rule interactions require workload evidence before entering the roadmap. Bounded database-local closure (M52) is an independent experiment and never lies on the critical path to the other milestones.

## Gates shared by every capability area

Correctness is necessary but does not decide whether a capability belongs in the product. Before implementation, each milestone must define the evidence that would justify shipping it and the evidence that would cause the team to narrow or reject it.

Qualification milestones reuse a versioned reference workload corpus and add capability-specific scenarios where necessary.

Every qualification milestone must include:

- at least three production-shaped workloads across the reference markets where the capability applies, with at least one derived from an external evaluator or design partner, migrated from a real application schema, or independently reviewed by an operator responsible for the corresponding control;
- migration evidence from rules previously implemented in application branches, scheduled queries, or triggers;
- evidence from successful and unsuccessful evaluations, including lost-user evidence caused by installation, preload, managed-service, row-level security, or compatibility constraints;
- measured time for a PostgreSQL developer to deploy a first rule and explain an unexpected outcome using public SQL;
- declared latency, write, WAL, memory, storage, and recovery-to-authoritative-state budgets at supported scale;
- a compatibility matrix in which unsupported feature combinations fail during validation;
- a simplification review that may unify APIs, remove a feature, or keep an advanced family out of the ordinary workflow.

Operations, security, compatibility, restore, and scale are continuous release gates from M35 onward. The later milestone numbers mark where their public models are consolidated, not when that work starts. A capability that passes in isolation but makes the common workflow unteachable or creates an incoherent interaction should not ship.

## Capability area 1: Make policy changes safe

M34 compares a deployed declaration with a proposal over current authoritative facts. The next step is to vary facts and time without creating a second evaluator or mutating production state.

### M35: Hypothetical fact simulation

M35 accepts typed hypothetical inserts, updates, and deletes against an explicit policy, applicability snapshot, source frontier, and sampled time. It returns bounded lifecycle, decision, and would-be work changes. Within published limits, those changes must match production semantics.

The directional contract covers inserts, updates, and deletes. Its first qualified profile may support a declared subset and must reject unsupported change forms during validation.

Simulation must leave source data, pg-react state, frontiers, and external systems unchanged. SQL relations hold the hypothetical changes. pg-react adds no scenario language or alternate fact model.

### M36: Historical replay

M36 evaluates one frozen policy over a user-supplied initial snapshot and an ordered history of fact changes. The caller supplies history because pg-react is not a source-history archive. It cannot reconstruct facts that PostgreSQL no longer holds.

Replay advances database time, event time, and source frontiers through explicit inputs. The result must match the production engine at every supported step without executing consequences.

### M37: Comparative backtesting

M37 runs two frozen policy versions over the same supplied history. It reports exact differences in matches, lifecycle transitions, decisions, and would-be work, plus bounded evidence for the affected subjects.

Backtesting should answer a practical deployment question: what would this policy have changed? It is not an optimizer, a forecasting system, or proof that historical behavior predicts future behavior.

### M38: Why-changed comparison

M38 explains why two versions, revisions, or frontiers differ. It connects each reported delta to changed facts, applicability, support, parameters, deadlines, or decision candidates.

The explanation remains finite and deterministic. pg-react should identify the supported causal difference, not attempt arbitrary SQL lineage or open-ended counterfactual reasoning.

### M39: Simulation qualification

M39 adds no new simulation mode. Its first gate qualifies current-fact comparison, hypothetical changes, semantic policy differences, why-changed explanations, and causal paths as one coherent contract with shared findings, limits, authorization, evidence, and result shapes. Replay and backtesting join this contract only if their research gates pass; they do not block the initial safe-change journey.

The milestone should prove semantic equivalence with isolated production runs, publish resource ceilings, and make cancellation or failure leave no hypothetical state behind. Representative users must complete proposal, simulation, difference, and explanation tasks without private joins or separate mental models.

## Capability area 2: Make outcomes explainable

Rules become easier to trust when an operator can move from an outcome to the facts and policy that caused it. The engine should answer bounded questions well instead of promising a universal proof system.

### M40: Bounded why-not

M40 explains missing results only for rule shapes with a finite answer. A decision might identify that no candidate matched. A derivation might identify a missing positive dependency, a failed threshold, an inapplicable policy, or an inactive effective period.

The engine must reject unsupported questions rather than invent an explanation. General SQL counterfactuals remain out of scope.

### M41: End-to-end causal paths

M41 connects existing evidence across named conditions, derived facts, decisions, lifecycle, and work. Public paths use business keys and declaration names instead of private catalog identifiers.

An operator should be able to start with a work item or decision and follow a bounded path back to authoritative facts. Cycles, truncation, unavailable evidence, and authorization gaps stay explicit.

### M42: Evidence snapshots

M42 preserves compact evidence for selected audited outcomes after ordinary source data or detailed history expires. A snapshot records the policy version, business keys, result, relevant time, and bounded support needed to explain the outcome.

This is not a database snapshot or a second source of truth. Authors opt in for specific declarations, and retention follows PostgreSQL ownership and authorization.

### M43: Semantic policy differences

M43 describes supported declaration changes in policy terms rather than relying only on a textual SQL diff. Examples include a changed modeled parameter value, applicability relation, effective interval, priority, declared result column, or action binding. A threshold embedded only in arbitrary SQL receives a textual or object-level difference, not a semantic interpretation.

The feature should report only semantics that pg-react already models. It must not claim to understand the business meaning of arbitrary SQL text.

### M44: Explanation qualification

M44 freezes one explanation contract across current state, comparisons, decisions, and work. Historical changes, replay, and backtesting use the same contract only if those capabilities have passed their research gates. It aligns ordering, redaction, truncation, retention, and stable identities.

Qualification should include large support sets, cycles, pruned history, changed authorization, upgrades, and restored databases. Explanation is operational evidence, so its cost and failure modes need published bounds.

## Capability area 3: Cover practical time-based rules

pg-react already supports deadlines, duration, absence, cooldown, hysteresis, and fixed tumbling windows. This capability area adds common temporal shapes while keeping state finite and clock semantics explicit.

### M45: Rolling and hopping windows

M45 supports rules such as "three failed payments in the previous hour" through bounded rolling or hopping windows. Authors must choose the event-time source, window size, step, lateness policy, and retained correction horizon.

The implementation should reuse the existing watermark and correction model. It should reject configurations whose state cannot stay within declared limits.

### M46: Business calendar windows

M46 adds days, months, billing periods, and named business calendars where fixed UTC durations are wrong. The contract must define time zones, daylight-saving transitions, month boundaries, and late input. Reevaluation from the same declared facts, time inputs, frontiers, and retained correction state must produce the same result.

PostgreSQL date and time types remain the authoring model. pg-react should not introduce a calendar expression language.

### M47: Finite event sequences

M47 supports short patterns such as event A followed by event B within a fixed interval for one semantic key. Sequence length, partial matches, ordering, expiration, and retained evidence all have hard bounds.

This milestone must not grow into a general complex-event-processing language. A few common finite sequences cover the intended rule-engine use cases.

### M48: Absence after an event

M48 supports rules such as "payment started, but settlement did not arrive before the deadline." The result becomes authoritative only when the relevant event-time frontier proves the absence.

The engine records which event opened the wait, which frontier closed it, and how a permitted late correction changes the result. Process clocks never decide the outcome.

### M49: Temporal rule qualification

M49 makes every temporal result consumable as an ordinary named condition or derived fact. Decision and command rules should not care whether their input came from a join, a deadline, a window, or a sequence.

The milestone adds recovery, retention, correction, and scale evidence across all supported temporal forms. It must also prove deterministic reevaluation from the same declared facts, time inputs, frontiers, and retained correction state. It adds replay evidence only if M36 passes its research gate. No additional temporal syntax belongs in M49.

## Capability area 4: Improve rule-set behavior

Traditional rule engines offer many ways for rules to interact. pg-react should add only the interactions that have deterministic PostgreSQL semantics and clear operational value.

### M50: Explicit firing policies

M50 extends the default once-per-continuous-match lifecycle with a small set of explicit policies, such as once ever, once per window, cooldown, and manual reset. Each policy becomes durable state that survives restart, restore, and rule replacement.

Worker timing must not affect whether a rule fires. Unsupported combinations should fail during validation.

### M51: Conflict groups

M51 lets several command rules declare that only one may create work for a business key. The group has deterministic precedence and exposes both the winner and the suppressed matches.

This reuses decision semantics where possible. It does not add an agenda whose ordering depends on execution timing.

### M52: Bounded database-local closure

M52 explores one narrow synchronous rule set whose database-local effects may cause more eligible rules to run before commit. The contract requires serialized evaluation, deterministic order, maximum firings, cycle detection, and complete rollback on failure.

External actions stay asynchronous and outside the closure. This research may proceed only after several important workloads show that the asynchronous model is inadequate and a small fixed-point contract solves them. If transaction latency becomes rule-set dependent in ways operators cannot bound, or if users must reason about a hidden agenda, the milestone should be dropped.

### M53: Complete policy-set packaging

M53 lets existing policy sets include shared conditions, parameter relations, and explicit dependencies under one versioned name. A policy set can be validated, compared, exported, deployed, inspected, and removed as a unit.

The underlying objects remain PostgreSQL relations and typed pg-react declarations. This extends the current grouping boundary without adding nested sets or a package language.

This milestone belongs to the strategic horizon and may be delivered before M45-M52 when production adoption needs a safer deployment unit.

### M54: Rule-set qualification

M54 adds no rule interaction. It tests conflict groups, firing policies, bounded closure, policy sets, and existing recursion under replacements, failures, concurrency, restore, and upgrade.

The result should remain understandable through ordinary SQL inspection. M54 must also decide whether each interaction still earns its place after combination testing. Any feature that requires a hidden execution agenda, private repair procedure, or disproportionate conceptual burden should be removed or remain experimental.

## Capability area 5: Deepen PostgreSQL operation

A PostgreSQL-native rule engine must behave well through schema changes, access control, maintenance, growth, backup, and restore. These concerns are core product work, not secondary platform work.

The milestones below consolidate contracts developed continuously from M35. They should move ahead of semantic expansion whenever recovery, authorization, deployment, or scale blocks a reference workload.

### M55: DDL impact planning

M55 shows which declarations depend on a proposed table, column, type, function, or view change. It identifies invalidated rules and the safe order for replacement or removal before PostgreSQL applies the change.

PostgreSQL dependencies and exact object identities remain authoritative. pg-react adds rule-specific findings and preview, not a separate schema registry.

### M56: Online rebuild and reconciliation

M56 makes supported rebuilds explicit when a rule, dependency, or maintained relation changes. Operators can see the rebuild frontier, affected declarations, blocked work, and reconciliation result through public SQL.

The engine should preserve unaffected lifecycle and work. It must fail closed when it cannot prove that old and rebuilt state agree.

### M57: Long-lived history

M57 qualifies retention and storage for installations that run for years. Retention settings control when pg-react can prune activations, attempts, support evidence, corrections, and comparisons. Replay results enter the retention contract only if M36 passes its research gate.

Partitioning or compaction belongs here only when measured workloads require it. Recovery, audit, and explanation horizons take precedence over smaller catalogs.

### M58: PostgreSQL authorization alignment

M58 reduces special pg-react permission concepts where PostgreSQL roles, ownership, grants, and security contexts can express the same rule. Evaluation, explanation, simulation, work claims, and administration must each have an exact authority model.

Richer source-security support belongs here only if pg-react can preserve deterministic evaluation and prevent evidence leaks. Unsupported row-level security configurations should continue to fail closed.

### M59: Supported-scale qualification

M59 expands only the scale and PostgreSQL configurations backed by repeatable evidence. Tests cover rule count, match count, dependency fan-out, work backlog, temporal state, retained history, memory, WAL, recovery time, and upgrade time.

The project should publish useful limits instead of universal throughput claims. New configuration combinations remain unsupported until the same correctness and recovery evidence passes. Qualification must cover interactions among effective dates, temporal corrections, firing policies, policy replacement, retained evidence, recursion, authorization, restore, and work generation when those features are supported. It includes replay only if M36 passes its research gate.

## Compatibility strategy

The v1 support tuple is deliberately narrow: PostgreSQL 18.3, pinned pg_trickle 0.81.0, Linux `amd64`, `READ COMMITTED`, coordinated refresh, required preload, and the documented managed-worker topology. The project should treat controlled installations as the default until evaluation, adoption, or lost-user evidence justifies a wider matrix.

Expansion should proceed one dimension at a time. PostgreSQL major versions and pg_trickle releases need independent install, upgrade, recovery, and semantic-equivalence evidence. The versioned SQL adapter should continue to isolate pg_trickle coupling, but a compatible range is a claim to prove, not infer. Preload remains an accepted constraint until evaluation, adoption, or lost-user evidence shows that it materially blocks the product wedge. Managed PostgreSQL is supportable only where the service exposes the required extensions, preload settings, backup behavior, and operational controls.

Each qualification release must state whether it keeps the controlled envelope or expands it. Universal portability is not a goal; a useful, maintained support matrix is.

## Capability area 6: Consolidate the rule engine

The final capability area should make pg-react smaller from the user's point of view. It should unify workflows, remove accidental complexity where compatibility permits, and prove that the full engine still behaves like PostgreSQL.

### M60: One authoring model

M60 gives rules, decisions, policy sets, and temporal declarations one documented authoring workflow. Typed constructors, `validate`, `preview`, `deploy`, stable names, and deterministic export remain the common vocabulary.

Released compatibility calls may delegate to the same implementation. The project should not add a new DSL, SDK family, or configuration format to hide SQL.

### M61: One inspection model

M61 aligns public views and functions for current state, history, decisions, work, simulation, and explanation. Replay joins this model only if M36 passes its research gate. Stable business identities connect the records without private catalog joins.

Common investigations should use ordinary `SELECT` statements. JSON remains limited to bounded nested evidence and canonical declarations.

### M62: One recovery model

M62 unifies restart, rebuild, reconciliation, physical restore, logical restoration, and supported failover around explicit public barriers. Operators can determine what is authoritative, what must be rebuilt, and when work may resume.

The contract continues to acknowledge at-least-once external delivery. No backup or recovery feature can turn an external effect into an exactly-once effect.

### M63: Production qualification

M63 runs at least three representative financial-exception and access-drift workloads that meet the shared evidence requirements through install, rule migration, policy change, load, failure, restore, and upgrade. It measures first-rule time, investigation time, simulation or comparison latency, write and storage overhead, and restore-to-authoritative-state time. The exact packaged artifacts and documented procedures must pass.

This milestone favors fewer supported combinations with strong evidence. It also records which proposed capabilities were merged, deferred, or rejected and why. Broader claims wait for users and repeatable tests that justify them.

### M64: PostgreSQL-native rule engine 2.0

M64 adds no new reasoning semantics. It freezes the smallest coherent public contract that survived the previous milestones and sets the compatibility boundary for `2.0.0`.

A PostgreSQL developer should be able to define relational rules, inspect durable outcomes, test changes, explain decisions, recover failures, and upgrade the extension without learning a second runtime model. If the product feels like a policy platform layered beside PostgreSQL, M64 has failed.

## Scope stays narrow

Every proposed milestone must pass the same filter:

- PostgreSQL remains the authoritative store and execution boundary.
- SQL and typed relations remain the rule language and fact model.
- pg-react owns only semantics that SQL does not retain by itself.
- Results, state, limits, and failures remain inspectable through PostgreSQL.
- New semantics stay deterministic, bounded, recoverable, and demand-driven.
- Unsupported combinations fail during validation rather than degrade at runtime.
- The ordinary authoring, inspection, and recovery workflow remains teachable in one sitting.
- The user value of a capability justifies its interaction and compatibility burden.

These constraints form a conceptual complexity budget. Qualification may spend that budget only on demonstrated workloads, and it must recover the budget by simplifying or deleting weaker features. Bounded resource use does not excuse an unbounded mental model.

The roadmap excludes hosted control planes, human workflow, visual or AI rule authoring, client-language DSLs, arbitrary optimization, unrestricted event patterns, untrusted dynamic code, distributed cross-database evaluation, and exactly-once external delivery. A separate project can pursue those products if users need them.

## The destination

The destination is not the broadest rule engine. It is the rule engine a PostgreSQL team reaches for when a relational condition must become durable, explainable state or work, starting with financial exceptions and access drift.

Teams should be able to express rules with the database objects they already understand. They should be able to compare a policy before deployment, inspect why a decision changed, use practical time-based rules, and recover after failure. Where representative source-history contracts justify M36, they should also be able to replay supplied history. The engine should keep those guarantees through ordinary PostgreSQL transactions, types, roles, backup, restore, and SQL inspection.

That product is ambitious enough. pg-react should use the M35-M64 option space to make it excellent.

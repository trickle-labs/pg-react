# The M35-M64 vision for pg-react

> Planning status (September 2026): M43 is complete, extension `0.40.0` is the current qualified baseline, and M44 is the current milestone. It targets extension `0.41.0`. `1.0.0` and its complete feature freeze are postponed indefinitely. [`ROADMAP.md`](../ROADMAP.md) remains the canonical milestone schedule.

Related documents: [Product thesis](pg-react_product_thesis.md), [Practical rule-engine features](pg-react_practical_rule_engine_features.md), and [PostgreSQL as an operational data platform](operational-data-platform.md).

pg-react should first and foremost be an excellent rule engine that lives inside PostgreSQL. A rule engine watches facts, tests conditions, and records what follows. PostgreSQL continues to own those facts, and authors continue to express conditions and possible results in SQL. pg-react supplies what a query alone does not preserve: a stable identity for each rule and result, a durable record of how a result changes over time, decisions, work to perform, explicit time handling, and enough evidence to explain an outcome without retaining an unlimited history.

That is already a substantial product. pg-react does not need to become a hosted policy service, a general workflow system, a visual authoring suite, a distributed event processor, or a second programming language. Its job is narrower and more useful: make rules over relational data safe to run, inspect, and change.

The first market is operational control over business data that PostgreSQL already owns, with an audit trail for every important outcome. Financial exceptions and access drift are the reference markets because they need results that survive restarts, policy changes that can be tested safely, explanations, reconciliation after change, and recovery after failure. Those markets should settle close sequencing decisions, but they should not limit the engine to finance or access control.

This vision begins with M35 and describes 30 possible milestones through M64. M35 through M43 are complete, and M44 is the current milestone in `ROADMAP.md`. M45 through M64 are possibilities, not a queue and not a promise that every item will ship. Their numbers give the team stable names for discussion. Evidence may change the order, combine milestones, replace them, or show that one should never be built.

## Decision horizons

### Committed horizon

The project commits to one milestone at a time. M44 is the current milestone. Later work enters the canonical roadmap only when it has acceptance criteria that tests can execute, a named owner, evidence that it helps the initial market, and evidence from the preceding milestone. This keeps a long vision from turning into a long list of promises.

### Strategic horizon

M34 through M39 let an operator propose a policy, test it against current facts, hypothetical changes, or supplied history, and understand why the result changed. M39 qualifies those parts as one journey. M40 adds a bounded answer when an expected current result is absent. M41 adds causal paths from current outcomes to authoritative facts. M42 retains selected evidence after ordinary data expires. M43 adds a bounded account of modeled policy differences. M44 plans to qualify one explanation contract across the current supported journey.

The first version of that journey may support only some declaration kinds, business-key shapes, hypothetical changes, and levels of evidence. Within that supported subset, however, the whole journey from proposal to explanation must work. A narrow complete experience is more valuable than a broad collection of disconnected features.

Several operational capabilities matter just as much: packaging a whole policy set in M53, planning the effect of schema changes in M55, rebuilding and reconciling state in M56, matching PostgreSQL authorization in M58, and proving supported scale in M59. Work on these capabilities should advance alongside earlier rule features. It should not wait until every possible time-based rule or rule interaction exists.

### Research horizon

M38 must preserve the M37 boundary. Users supply useful source history, and pg-react does not reconstruct it. New forms of time-based rules and new ways for rules to interact also need evidence from real workloads before they enter the roadmap. M52, which explores whether a small group of rules can trigger one another inside one database transaction, is a separate experiment. Nothing else in this vision depends on it.

## Gates shared by every capability area

Correct results are necessary, but correctness alone does not earn a feature a place in the product. Before implementation, each milestone must state what evidence would justify shipping it and what evidence would cause the team to narrow or reject it.

Qualification milestones are checkpoints where the team proves that several features work together under realistic conditions. They reuse a versioned collection of reference workloads and add scenarios for the capability under test when necessary.

Every qualification milestone must include:

- at least three workloads shaped like production systems across the reference markets where the capability applies, with at least one derived from an external evaluator or design partner, migrated from a real application schema, or independently reviewed by an operator responsible for the corresponding control;
- migration evidence from rules previously implemented in application branches, scheduled queries, or triggers;
- evidence from successful and unsuccessful evaluations, including lost-user evidence caused by installation, preload, managed-service, row-level security, or compatibility constraints;
- measured time for a PostgreSQL developer to deploy a first rule and explain an unexpected outcome using public SQL;
- declared budgets at supported scale for latency, writes, write-ahead log volume, memory, storage, and the time needed to restore authoritative state;
- a compatibility matrix in which unsupported feature combinations fail during validation;
- a simplification review that may unify APIs, remove a feature, or keep an advanced family out of the ordinary workflow.

Operations, security, compatibility, restore, and scale remain release requirements from M35 onward. The later milestone numbers mark where pg-react brings their public models together, not where that work begins. A capability should not ship if it works alone but makes the ordinary workflow too hard to teach or behaves inconsistently with other features.

## Capability area 1: Make policy changes safe

M34 can compare a deployed rule declaration with a proposed one using the current authoritative facts. The next step is to ask what would happen if facts or time changed, without building a second rule engine and without changing production state.

### M35: Hypothetical fact simulation

M35 accepts typed, hypothetical inserts, updates, and deletes. The caller names the policy, the set of subjects to which it applies, the point through which source data is known, and the time to use for the test. pg-react then reports how durable matches would start or end, how decisions would change, and what work the engine would have created. The report stays within published limits, and its supported results must match what the production engine would do.

The directional contract covers inserts, updates, and deletes. Its first qualified profile may support a declared subset and must reject unsupported change forms during validation.

Simulation must leave source data, pg-react state, source progress, and external systems unchanged. Ordinary SQL relations hold the hypothetical changes. pg-react adds no scenario language and no alternate model for facts.

### M36: Historical replay

M36 evaluates one fixed policy against an initial snapshot and an ordered history of fact changes supplied by the user. The caller must provide that history because pg-react is not an archive of every source change. It cannot reconstruct facts that PostgreSQL no longer holds.

During replay, explicit inputs advance the database clock, the event timestamps used by rules, and the point through which source changes are known. At every supported step, the result must match the production engine without carrying out any resulting work.

### M37: Comparative backtesting

M37 runs two fixed policy versions over the same supplied history. It reports exact differences in matches, changes to their durable state, decisions, and work that each version would have created. It also returns a limited amount of supporting evidence for the affected subjects.

Backtesting should answer a practical deployment question: what would this policy have changed? It is not an optimizer, a forecasting system, or proof that historical behavior predicts future behavior.

### M38: Why-changed comparison

M38 explains why two policy versions, revisions, or points in source progress produce different results. It connects each difference to the facts, applicability, supporting evidence, parameters, deadlines, or decision candidates that changed.

The explanation must have a fixed bound and produce the same answer from the same inputs. pg-react identifies supported causes. It does not try to trace every possible dependency in arbitrary SQL or answer unlimited questions about what might have happened.

### M39: Simulation qualification

M39 adds no new kind of simulation or explanation. It proves that comparison with current facts, hypothetical changes, replay, backtesting, and why-changed evidence work as one contract. They must share findings, limits, authorization rules, evidence, and result identities. Later capabilities must pass their own gates before they join this qualified contract.

The milestone should prove semantic equivalence with isolated production runs, publish resource ceilings, and make cancellation or failure leave no hypothetical state behind. Representative users must complete proposal, simulation, difference, and explanation tasks without private joins or separate mental models.

## Capability area 2: Make outcomes explainable

Operators can trust rules more readily when they can start with an outcome and trace it back to the policy and facts that caused it. pg-react should answer a defined set of explanation questions well. It should not promise to prove every possible claim about arbitrary SQL.

### M40: Bounded why-not

M40 explains a missing result only when the rule has a finite, supported answer. For a decision, the answer might be that no candidate matched. For a derived fact, it might be a missing required input, a threshold that the data did not meet, a policy that did not apply, or a policy period that was not active.

The engine must reject unsupported questions rather than invent an explanation. General SQL counterfactuals remain out of scope.

### M41: End-to-end causal paths

M41 connects existing evidence across named conditions, facts derived by other rules, decisions, durable match state, and work. The public path uses business keys and rule names that an operator knows, not internal catalog identifiers.

An operator should be able to start with a work item or decision and follow a path of limited length back to authoritative facts. If the path contains a cycle, reaches its size limit, lacks evidence, or crosses data the operator cannot access, pg-react must say so.

### M42: Evidence snapshots

M42 preserves compact evidence for selected audited outcomes after ordinary source data or detailed history expires. This evidence snapshot records the policy version, business keys, result, relevant time, and limited supporting facts needed to explain the outcome.

This is not a database snapshot or a second source of truth. Authors opt in for specific declarations, and retention follows PostgreSQL ownership and authorization.

### M43: Semantic policy differences

M43 describes supported rule changes in policy terms instead of showing only a textual SQL difference. It can report a changed parameter value that pg-react models, a different applicability relation, a different effective period, a new priority, a changed result column, or a different action binding. If an author hides a threshold inside arbitrary SQL, pg-react can show the text or database object that changed, but it cannot explain the business meaning of that threshold.

The feature should report only semantics that pg-react already models. It must not claim to understand the business meaning of arbitrary SQL text.

### M44: Explanation qualification

M44 establishes one stable explanation contract for current state, comparisons, decisions, and work. Historical changes, replay, and backtesting use the same contract only after they pass their research gates. The contract gives all explanations the same rules for ordering, hiding unauthorized details, limiting large results, retaining evidence, and identifying the same subject over time.

Qualification should include large support sets, cycles, pruned history, changed authorization, upgrades, and restored databases. Explanation is operational evidence, so its cost and failure modes need published bounds.

## Capability area 3: Cover practical time-based rules

pg-react already supports deadlines, duration, absence, cooldown, hysteresis, and fixed windows that divide time into consecutive blocks. The next milestones add common time-based rule shapes while limiting how much state they retain and stating exactly which clock decides each result.

### M45: Rolling and hopping windows

M45 supports rules such as "three failed payments in the previous hour." A rolling window moves continuously with the evaluation time, while a hopping window moves in fixed steps and may overlap the previous window. Authors must choose where event time comes from, how large the window is, how far it moves at each step, how the rule handles late events, and how long the engine may correct an earlier result.

The implementation should reuse the existing model that records how far event processing has progressed and when a late event may correct a result. It should reject configurations that cannot keep retained state within declared limits.

### M46: Business calendar windows

M46 adds calendar days, months, billing periods, and named business calendars for rules where a fixed number of UTC seconds would give the wrong answer. The contract must define time zones, daylight-saving changes, month boundaries, and late input. A second evaluation with the same facts, time inputs, source progress, and retained correction state must produce the same result.

PostgreSQL date and time types remain the authoring model. pg-react should not introduce a calendar expression language.

### M47: Finite event sequences

M47 supports short event patterns, such as event A followed by event B within a fixed interval for one business key. The engine places hard limits on the number of events in a sequence, incomplete matches, ordering choices, expiration time, and retained evidence.

This milestone must not grow into a general complex-event-processing language. A few common finite sequences cover the intended rule-engine use cases.

### M48: Absence after an event

M48 supports rules such as "payment started, but settlement did not arrive before the deadline." The result becomes authoritative only when source progress proves that all relevant events through the deadline have arrived, so the missing settlement is a real absence rather than a delayed event.

The engine records which event started the wait, what point in source progress proved the absence, and how an allowed late correction changes the result. The wall clock of a worker process never decides the outcome.

### M49: Temporal rule qualification

M49 makes every time-based result available as an ordinary named condition or derived fact. Decision rules and rules that create work should not need to know whether an input came from a SQL join, a deadline, a window, or an event sequence.

The milestone adds recovery, retention, correction, and scale evidence across all supported temporal forms. It must also prove that the same facts, time inputs, points in source progress, and retained correction state always produce the same result. It adds replay evidence only if M36 passes its research gate. No additional temporal syntax belongs in M49.

## Capability area 4: Improve rule-set behavior

Traditional rule engines let rules affect one another in many ways. These interactions can become hard to predict when execution order changes the answer. pg-react should add only interactions that have clear operational value and produce the same result under defined PostgreSQL behavior.

### M50: Explicit firing policies

By default, pg-react fires once while a condition remains continuously true, and it can fire again after the condition becomes false and later true. M50 adds a small set of explicit alternatives, such as once ever, once per window, after a cooldown, or after a manual reset. The chosen policy becomes durable state that survives a restart, restore, or rule replacement.

Worker timing must not affect whether a rule fires. Unsupported combinations should fail during validation.

### M51: Conflict groups

M51 lets several rules that create work declare that only one of them may create work for a given business key. The conflict group uses a defined priority that always selects the same winner, and operators can inspect both that winner and the matching rules that pg-react suppressed.

This reuses decision semantics where possible. It does not add an agenda whose ordering depends on execution timing.

### M52: Bounded database-local closure

M52 explores a narrow case in which one rule changes database-local facts and makes another rule eligible before the transaction commits. The engine would repeat this process until no more eligible rules remain. To keep that process understandable, the contract requires one-at-a-time evaluation in a defined order, a maximum number of firings, detection of loops, and complete rollback if anything fails.

External actions remain asynchronous and outside this transaction-local process. Research may proceed only if several important workloads show that the asynchronous model is inadequate and that this small repeat-until-finished contract solves the problem. The team should drop the milestone if operators cannot bound transaction time or must reason about a hidden execution queue.

### M53: Complete policy-set packaging

M53 lets existing policy sets place shared conditions, parameter relations, and explicit dependencies under one versioned name. Operators can validate, compare, export, deploy, inspect, and remove the complete set as one unit.

The underlying objects remain PostgreSQL relations and typed pg-react declarations. This extends the current grouping boundary without adding nested sets or a package language.

This milestone belongs to the strategic horizon and may be delivered before M45-M52 when production adoption needs a safer deployment unit.

### M54: Rule-set qualification

M54 adds no new way for rules to interact. It tests conflict groups, firing policies, the transaction-local experiment from M52, policy sets, and existing recursion while rules are replaced, operations fail, transactions run concurrently, databases are restored, and the extension is upgraded.

Operators must still be able to understand the result through ordinary SQL queries. M54 must also decide whether each interaction still deserves a place after combination testing. Any feature that needs a hidden execution queue, a private repair procedure, or far more explanation than its value warrants should be removed or remain experimental.

## Capability area 5: Deepen PostgreSQL operation

A rule engine that lives in PostgreSQL must behave well through schema changes, access control, maintenance, growth, backup, and restore. These are core product requirements, not secondary platform work.

The milestones below consolidate contracts developed continuously from M35. They should move ahead of semantic expansion whenever recovery, authorization, deployment, or scale blocks a reference workload.

### M55: DDL impact planning

M55 shows which rule declarations depend on a proposed change to a table, column, type, function, or view. Before PostgreSQL applies the schema change, pg-react identifies the rules that the change would invalidate and the safe order in which to replace or remove them.

PostgreSQL dependencies and exact object identities remain authoritative. pg-react adds rule-specific findings and preview, not a separate schema registry.

### M56: Online rebuild and reconciliation

M56 makes supported rebuilds visible when a rule, dependency, or relation maintained by the engine changes. Through public SQL, operators can see how far the rebuild has progressed, which rules it affects, what work remains blocked, and whether rebuilt state agrees with authoritative source data.

The engine should preserve durable match state and work that the rebuild does not affect. If it cannot prove that old and rebuilt state agree, it must stop the affected operation instead of assuming that the state is safe.

### M57: Long-lived history

M57 proves retention and storage behavior for installations that run for years. Retention settings control when pg-react may delete old activations, work attempts, supporting evidence, corrections, and comparisons. Replay results join this retention contract only if M36 passes its research gate.

Partitioning or compaction belongs here only when measured workloads require it. Recovery, audit, and explanation horizons take precedence over smaller catalogs.

### M58: PostgreSQL authorization alignment

M58 removes special pg-react permission concepts wherever PostgreSQL roles, ownership, grants, and security contexts can express the same rule. The contract must state exactly whose authority applies to rule evaluation, explanation, simulation, claiming work, and administration.

pg-react should support more source-security configurations only when it can preserve repeatable evaluation and prevent explanations from leaking evidence. Unsupported row-level security configurations should continue to stop safely during validation.

### M59: Supported-scale qualification

M59 expands only the scale and PostgreSQL configurations backed by repeatable evidence. Tests cover the number of rules and matches, the number of downstream dependencies one fact can affect, the work backlog, time-based state, retained history, memory, write-ahead log volume, recovery time, and upgrade time.

The project should publish useful limits instead of universal throughput claims. New configuration combinations remain unsupported until the same correctness and recovery evidence passes. Qualification must cover interactions among effective dates, temporal corrections, firing policies, policy replacement, retained evidence, recursion, authorization, restore, and work generation when those features are supported. It includes replay only if M36 passes its research gate.

## Compatibility strategy

The v1 support combination is deliberately narrow: PostgreSQL 18.3, pinned pg_trickle 0.81.0, Linux `amd64`, `READ COMMITTED`, coordinated refresh, required preload, and the documented managed-worker topology. The project should treat controlled installations as the default until evaluation, adoption, or evidence about users lost to these limits justifies wider support.

Support should expand one dimension at a time. Each PostgreSQL major version and pg_trickle release needs its own evidence for installation, upgrade, recovery, and equivalent rule behavior. The versioned SQL adapter should continue to isolate pg-react from pg_trickle changes, but the project must prove any claimed compatible range. It must not infer compatibility from similar version numbers. Preload remains an accepted constraint until evaluation, adoption, or lost-user evidence shows that it blocks the initial market. A managed PostgreSQL service is supportable only if it exposes the required extensions, preload settings, backup behavior, and operational controls.

Each qualification release must state whether it keeps the controlled envelope or expands it. Universal portability is not a goal; a useful, maintained support matrix is.

## Capability area 6: Consolidate the rule engine

The final capability area should make pg-react feel smaller to its users even after the engine gains more capability. It should bring workflows together, remove complexity where compatibility permits, and prove that the complete engine still behaves like part of PostgreSQL.

### M60: One authoring model

M60 gives rules, decisions, policy sets, and time-based declarations one documented authoring workflow. Authors use the same typed constructors, `validate`, `preview`, `deploy`, stable names, and exports that produce the same output from the same input.

Released compatibility calls may delegate to the same implementation. The project should not add a new DSL, SDK family, or configuration format to hide SQL.

### M61: One inspection model

M61 aligns public views and functions for current state, history, decisions, work, simulation, and explanation. Replay joins this model only if M36 passes its research gate. Stable business identities connect records, so operators do not need to join private catalog tables.

Common investigations should use ordinary `SELECT` statements. JSON remains limited to bounded nested evidence and canonical declarations.

### M62: One recovery model

M62 gives restart, rebuild, reconciliation, physical restore, logical restoration, and supported failover one recovery model with explicit public checkpoints. Operators can determine which state is authoritative, what pg-react must rebuild, and when workers may resume.

The contract continues to acknowledge that pg-react may deliver external work more than once. No backup or recovery feature can guarantee that an effect outside PostgreSQL happens exactly once.

### M63: Production qualification

M63 runs at least three representative financial-exception and access-drift workloads that meet the shared evidence requirements. Each workload goes through installation, migration of existing rules, policy change, load, failure, restore, and upgrade. The tests measure the time to deploy a first rule, investigate an outcome, run a simulation or comparison, and restore authoritative state. They also measure write and storage overhead. The exact packaged artifacts and documented procedures must pass.

This milestone favors fewer supported combinations with strong evidence. It also records which proposed capabilities were merged, deferred, or rejected and why. Broader claims wait for users and repeatable tests that justify them.

### M64: PostgreSQL-native rule engine 2.0

M64 adds no new rule behavior. It freezes the smallest coherent public contract that survived the previous milestones and sets the compatibility boundary for `2.0.0`.

A PostgreSQL developer should be able to define rules over relational data, inspect outcomes that survive restarts, test changes, explain decisions, recover from failures, and upgrade the extension without learning a second runtime model. If the product feels like a separate policy platform beside PostgreSQL, M64 has failed.

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

Together, these constraints limit how much users must learn. A qualification milestone may add complexity only for workloads that demonstrate its value, and it must offset that cost by simplifying or deleting weaker features. A feature is not acceptable merely because its CPU and memory use have limits. Users must also be able to understand it.

The roadmap excludes hosted control planes, human workflow, visual or AI rule authoring, client-language DSLs, arbitrary optimization, unrestricted event patterns, untrusted dynamic code, distributed cross-database evaluation, and exactly-once external delivery. A separate project can pursue those products if users need them.

## The destination

The goal is not to build the broadest rule engine. It is to build the rule engine a PostgreSQL team chooses when a condition over relational data must become durable, explainable state or work. Financial exceptions and access drift come first.

Teams should express rules with database objects they already understand. Before deployment, they should be able to compare a proposed policy with the current one. Afterward, they should be able to explain why a decision changed, use practical time-based rules, and recover after failure. If representative users show that they can supply the history M36 requires, teams should also be able to replay that history. The engine must keep these guarantees through ordinary PostgreSQL transactions, types, roles, backup, restore, and SQL inspection.

That product is ambitious enough. pg-react should use the M35-M64 option space to make it excellent.

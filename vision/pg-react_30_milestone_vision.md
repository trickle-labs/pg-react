# From Durable Rules to a PostgreSQL Policy Platform

## A speculative 30-milestone roadmap for pg-react

Related vision documents: [Product thesis](pg-react_product_thesis.md) · [Practical rule-engine features](pg-react_practical_rule_engine_features.md)

pg-react already has the beginnings of a distinctive product thesis: PostgreSQL contains the authoritative facts, SQL describes relational truth, and pg-react adds the durable semantics needed to turn that truth into decisions, lifecycle, explanation, and work. The interesting question is not how many rule-engine features can be accumulated. The interesting question is how far that idea can be taken without losing the qualities that make it compelling in the first place.

A useful long-term roadmap should therefore avoid becoming a shopping list of traditional rule-engine capabilities. The goal should not be to reproduce every concept from Drools, CEP engines, policy servers, workflow products, or event-processing systems. Instead, each milestone should make one of four things better: policy should become easier to express, safer to change, easier to explain, or more reliable to operate.

The following 30 milestones imagine pg-react evolving from the production-hardened M18 baseline into a much broader PostgreSQL-native policy platform. The sequence is deliberately conservative. Each phase earns the right to introduce more power by first proving the previous layer understandable and operationally sound. Later milestones are increasingly speculative and should remain demand-driven. The destination is not “the most expressive rule engine possible.” It is a system in which sophisticated business policy can remain recognizably PostgreSQL.

---

# Phase 1 — Finish the core operating model

The first phase after M18 should not immediately chase glamorous policy features. It should complete a few structural capabilities that make the existing rule system more composable, more responsive, and easier to explain. These are the foundations on which later business-policy features depend.

## M19 — Selective immediate maintenance

M19 introduces a carefully bounded read-your-writes path for constraint rules and database-local derivation rules. The important word is **selective**. pg-react should not abandon its asynchronous, coordinated model and attempt to make every rule synchronous. Instead, authors should be able to mark a proven subset of rules as eligible for immediate maintenance when application correctness genuinely requires derived truth to be visible in the same transaction.

This milestone is valuable because many users will eventually run into the gap between “the rule engine will catch up safely” and “the next statement in this transaction needs the result now.” Entitlement derivation, quota checks, local consistency constraints, and certain policy-driven writes can all create this demand.

M19 should freeze a narrow isolation and locking contract, reject unsupported dependency shapes, and keep arbitrary external consequences asynchronous. Its real contribution is not speed. It establishes a trustworthy bridge between ordinary PostgreSQL transactions and pg-react-maintained truth.

## M20 — Shared conditions

Once users build larger rule sets, duplicated business concepts become a bigger problem than duplicated code. Several rules may independently define “high-risk customer,” “account delinquent,” “legal hold active,” or “inventory constrained.” M20 gives those concepts explicit identity.

A shared condition should be a named, versioned, maintained relation that several rules can consume. PostgreSQL still defines the condition using SQL, but pg-react understands its ownership, consumers, lifecycle, deployment dependencies, and explanation boundary.

This creates a domain vocabulary inside the database. Instead of five unrelated rules embedding subtly different definitions of “high risk,” one canonical condition can feed payment review, step-up authentication, credit policy, and customer-service workflows. The benefit is as much organizational as computational: policy authors can reason in named concepts rather than repeated predicates.

## M21 — Retention and catalog scale

By this point, pg-react will have accumulated substantial durable history: activations, jobs, attempts, supports, explanations, windows, corrections, and diagnostics. M18 should have measured where the storage and performance cliffs actually are. M21 uses that evidence to introduce audited pruning and, only where justified, catalog partitioning or other scale-oriented storage changes.

This milestone is intentionally unglamorous. It is what lets the product survive long-lived installations. Retention policies must preserve published recovery, replay, rollback, and explanation horizons. Open windows, pending work, active supports, and data still needed for reconciliation cannot disappear merely because a cleanup job prefers a smaller table.

A rule engine becomes trustworthy when old state disappears only under an explicit policy. M21 makes that principle executable.

## M22 — Bounded support provenance

pg-react already has finite explanation and support concepts. M22 deepens them by recording stable contributing business bindings for derived facts. The goal is not arbitrary SQL lineage. It is a bounded answer to “which facts actually supported this result?”

For example, an entitlement could explain that it exists because employee 42 has role `approver`, belongs to region `NO`, and is covered by policy version 7. A reconciliation finding could point to the specific order and settlement keys that disagree. A derived risk fact could identify the lower-level facts that produced it.

The milestone should preserve strict bounds: canonical support ordering, maximum counts, cycle markers for recursion, continuation only through advanced interfaces, and role-checked visibility. M22 makes explanation much more useful without turning pg-react into a general provenance research system.

## M23 — Practical temporal conditions

M17 gives pg-react event-time tumbling windows. Earlier milestones provide database-time deadlines. M23 should combine those foundations into the temporal rules ordinary businesses actually ask for: “has been true for 10 minutes,” “did not happen before the deadline,” “do not fire again for 30 minutes,” and “re-arm only after the condition has recovered.”

These semantics appear constantly in SLAs, compliance, security drift, billing, monitoring, and remediation. They are rule-engine problems because the difficulty lies in durable timing and lifecycle, not the predicate itself.

M23 should resist the label “CEP.” It should add a few small, explicit temporal primitives whose state is bounded and whose clock domain is unambiguous. Database-time duration, absence-by-deadline, cooldown, and hysteresis are enough to unlock a large amount of practical value.

---

# Phase 2 — Make business policy first-class

With the core operating model complete, pg-react can begin addressing a different class of problem: policy itself changes, varies across populations, and often needs deterministic selection semantics. This phase moves pg-react from a durable reaction engine toward a true business-policy system.

## M24 — Effective-dated policy versions

Business policy frequently changes on a business date rather than a deployment date. A tax rule starts January 1. A contract changes at renewal. A pricing policy becomes effective next quarter.

M24 should let a rule or program version declare a canonical validity interval such as `[valid_from, valid_to)`. A future policy can be deployed and validated in advance, remain dormant until its effective boundary, and become authoritative deterministically through pg-react’s logical time model.

This separates two important facts: when software was deployed and when business policy became applicable. That distinction matters for auditability, compliance, and controlled change.

## M25 — Parameterized policy families

Many policies have identical logic but different values by tenant, geography, product, risk class, or customer tier. Users should not need 500 copies of the same rule merely because each tenant has a different threshold.

M25 should formalize typed relational parameters as part of a policy family. Parameters remain ordinary PostgreSQL rows and participate in normal joins; there is no need for string templating or a new expression language. pg-react adds the surrounding semantics: validation, ownership, preview, explanation, deployment relationships, and policy-family identity.

A threshold change becomes a fact change, not hidden mutation of compiled rule logic. That keeps the system relational and predictable.

## M26 — Decision tables

A huge fraction of business rules are really decision problems: several policies may match, but one authoritative outcome must be selected. Underwriting tiers, shipping policies, customer classes, discounts, routing decisions, approval levels, and risk categories all fit this shape.

M26 should let SQL produce decision candidates while pg-react owns deterministic winner semantics. A candidate relation might contain a subject key, policy identifier, priority, and result. The engine guarantees exactly how a winner is chosen, rejects ambiguity when the contract requires uniqueness, preserves winner lifecycle, and explains both the winning candidate and relevant competitors.

This avoids creating a decision-table DSL. PostgreSQL still expresses the conditions. pg-react gives the decision durable meaning.

## M27 — Decision coverage and conflict analysis

Once decision tables exist, users will want to know whether their policy set is coherent before deployment. M27 turns policy quality into something pg-react can inspect.

For supported decision programs, validation and preview should detect conflicts such as ties, overlapping policies that violate exclusivity, missing defaults, unreachable candidates, or populations with no valid outcome. It should also identify policy edits that cause large changes in winner distribution.

The feature is valuable because policy errors often arise not from one wrong predicate, but from interactions between otherwise valid rules. M27 makes those interactions visible before they become production incidents.

## M28 — Public API convergence and ergonomics

Before adding another semantic family, pg-react should make its representative M0–M27 capabilities feel like one product. M28 introduces a versioned declaration and target model, a small names-first ordinary verb set, common finding and result envelopes, and one lifecycle from validation through deployment and inspection.

The façade remains additive and delegates to the authoritative specialized APIs. Its purpose is to preserve exact semantics, security, recovery, and compatibility while making future capabilities extend declarations and results instead of adding another unrelated public workflow.

## M29 — Policy-set gating

Organizations rarely apply every rule everywhere. Policies vary by jurisdiction, product line, tenant, rollout cohort, contract, or regulatory regime. Today this can be encoded inside every condition, but doing so mixes applicability with policy logic.

M29 introduces explicit policy-set gating. A versioned policy set can be enabled for a defined population or regime while the contained rules remain unchanged. This gives teams a clean mechanism for staged rollout, jurisdiction-specific policy, customer-specific programs, and controlled transitions.

The design should remain relational: gating populations should be typed PostgreSQL facts or named conditions, not hidden feature flags inside engine code.

---

# Phase 3 — Make policy safe to change

At this point pg-react can express and operate substantial policy. The next problem is change risk. A powerful rule system becomes genuinely valuable when users can see what a policy change would do before they commit it.

## M30 — Hypothetical fact simulation

M30 introduces side-effect-free what-if evaluation. A caller supplies bounded hypothetical inserts, updates, or deletes and asks what the selected rule or program would conclude.

The simulation should use the same normalized semantics as production but mutate no authoritative tables, create no durable jobs, advance no real watermarks, and execute no consequences. It should return resulting matches, derived facts, decision outcomes, and would-be lifecycle transitions.

This is useful in interactive applications, support tooling, eligibility analysis, debugging, and policy design. It also creates the evaluation kernel needed for later backtesting.

## M31 — Deployment impact simulation

M30 changes facts under the current policy. M31 changes policy against current facts.

Before replacing a rule or program, users should be able to compare the currently deployed version with the proposed version and see which business keys would activate, deactivate, change derived values, select different decision winners, or produce different would-be work.

This turns deployment preview from schema validation into business impact analysis. A policy author can answer “who changes?” before the new version is made authoritative.

## M32 — Historical replay

Historical replay extends simulation over a deterministic sequence of fact changes. The user provides an initial snapshot and an ordered history, and pg-react evaluates one frozen policy version through that history without executing real consequences.

This does not mean pg-react becomes a source CDC archive. Historical facts remain user-supplied. The feature merely guarantees that the same lifecycle, derivation, deadline, and event-time semantics can be replayed in isolation.

That capability is especially valuable for fraud, compliance, SLA, finance, and operations teams that need to understand how a rule behaves over time rather than at one snapshot.

## M33 — Comparative backtesting

M33 runs two policy versions over the same historical input and compares their results. Instead of merely saying that the new policy is valid, pg-react can report how many activations were added, removed, or changed, which decision outcomes moved, and where resource usage differs.

A fraud team could compare a proposed rule against three months of transactions. A finance team could measure how many historical journals a new control would have blocked. An entitlement team could see how a new policy would alter grants and revocations.

This milestone transforms policy change from intuition into evidence.

## Later direction — Policy promotion workflow

Once simulation and backtesting exist, they can form a disciplined promotion path: draft, validate, simulate, backtest, approve, schedule, activate.

This should not become a general human workflow engine. The goal is narrower: make the lifecycle of a policy artifact explicit and inspectable. A deployed policy can carry immutable evidence showing which validation, simulations, backtests, approvals, and effective dates justified its activation.

At this stage pg-react starts to look less like a component and more like a serious policy operating system.

---

# Phase 4 — Make decisions deeply explainable

Policy is safer when people can understand not just what happened, but how one state differed from another and which causal chain mattered.

## M34 — Why-changed explanations

M34 answers a question operators ask constantly: “why did this change?”

Rather than showing only current evidence, pg-react should compare two frontiers, revisions, or policy versions and identify the bounded causal difference: a support appeared, a threshold changed, a lower fact disappeared, a deadline was crossed, or a different decision candidate became dominant.

This makes regressions and policy updates far easier to diagnose.

## M35 — Bounded why-not

“Why is this true?” is easier than “why isn’t this true?” because absence can have enormous search spaces. M35 should therefore support why-not only for rule shapes where a bounded, deterministic explanation is possible.

For a decision or derivation, the engine might identify the first canonical missing dependency, failed aggregate threshold, absent required shared condition, or blocked effective period. It should not claim to solve arbitrary SQL counterfactual reasoning.

Even a bounded why-not capability would be extremely valuable for support and policy design.

## M36 — Decision lineage

M36 connects explanation across layers. A user should be able to follow a stable path from authoritative facts to shared conditions, derived facts, decision candidates, winner selection, activation, and resulting work.

The emphasis is on business identities, not private engine IDs. The result should feel like a causal narrative rather than a dump of internal catalogs.

This is particularly compelling for financial controls, access governance, privacy policy, and regulated decisions.

## M37 — Evidence snapshots

Some decisions need explanations long after ordinary source data has changed or been pruned. M37 introduces compact evidence snapshots for explicitly configured audited decisions.

These snapshots should capture only bounded, necessary evidence: relevant business keys, policy version, decision result, effective time, aggregate/window summaries, and selected support references. They should not become full database snapshots.

The feature lets organizations preserve the justification for important historical decisions without retaining every transient internal row forever.

## M38 — Policy diff semantics

Textual SQL diffs are useful to developers but poor descriptions of policy change. M38 should compute semantic diffs between normalized policy versions.

A diff might say that a threshold changed from 10,000 to 7,500, a new shared condition was added, one decision candidate moved ahead of another, the effective interval changed, or a new parameter domain became eligible.

Combined with impact simulation and backtesting, this gives reviewers a much clearer picture of what a policy edit actually means.

---

# Phase 5 — Add practical temporal intelligence

By now pg-react has strong business-policy semantics and safe change tooling. Temporal reasoning can widen carefully without turning the product into a general complex-event processor.

## M39 — Rolling and hopping windows

M17’s tumbling windows are excellent for fixed buckets but do not naturally express “three failures in the previous hour.” M39 adds bounded rolling or hopping windows with the same rigor around event time, watermarks, lateness, correction identity, retention, and recovery.

The goal is to support ordinary frequency-based rules without introducing unbounded event history.

## M40 — Calendar windows

Many businesses reason in days, months, quarters, billing periods, and local business calendars rather than fixed UTC durations. M40 adds carefully specified calendar windows.

The difficulty is not syntax; it is semantics around timezone, daylight-saving transitions, month length, business boundaries, and deterministic replay. A narrow, explicit contract matters more than broad calendar expressiveness.

## M41 — Bounded sequence rules

M41 introduces simple finite sequences such as “A happened, then B happened within ten minutes” for one semantic key.

This is the first milestone that meaningfully approaches CEP territory, so the scope should remain intentionally small: fixed sequence length, bounded partial-match state, explicit event-time semantics, deterministic expiration, and no general pattern language.

## M42 — Temporal absence sequences

The next practical extension is “A happened, but B did not happen before the deadline.” This pattern appears in payments, onboarding, SLAs, fraud, and compliance.

Because absence depends on time completeness, this milestone should build directly on watermarks and deadline semantics. The engine must be able to explain not merely that B was absent, but at what complete frontier that absence became authoritative.

## M43 — Temporal policy composition

Rather than adding ever more temporal syntax, M43 makes temporal results reusable as ordinary named conditions and derived facts.

A condition such as `payment_missing_30d` or `three_failures_1h` should become just another PostgreSQL-native truth that decision tables, derivations, and command rules can consume. This keeps the architecture compositional and avoids a separate “temporal rule language.”

---

# Phase 6 — Mature rule-set behavior

The final phase introduces some of the capabilities people associate with traditional rule engines, but only after pg-react has built strong constraints, explanation, and change safety around them.

## M44 — Conflict and activation groups

Some policies are intentionally mutually exclusive. Several command rules may match, but only one should create work for a business key.

M44 adds explicit conflict and activation groups with deterministic winner policy and explanation. This is similar to decision tables but applies to rule consequences rather than merely derived outcomes.

The engine should never rely on accidental worker timing to decide which rule wins.

## M45 — Rich refraction policies

The existing lifecycle model naturally supports “once per continuous truth interval.” Real systems sometimes need other firing policies: once ever, once per window, explicit reset, cooldown, or re-arm after recovery.

M45 introduces those policies explicitly. The crucial design principle is that refraction remains part of durable lifecycle semantics rather than hidden worker behavior.

## M46 — Bounded synchronous rule sets

Only after all the previous safety and explanation work should pg-react consider a synchronous firing loop.

M46 would support one serialized database-local rule set whose consequences may update facts and cause additional eligible rules to run before commit. The contract must freeze deterministic ordering, causal controls, maximum firings, cycle limits, rollback behavior, and supported rule shapes.

External actions remain outside the loop. General workflow orchestration remains out of scope. This is a narrow fixed-point facility, not a return to opaque expert-system execution.

## M47 — Policy modules

As the feature set grows, users need a packaging boundary larger than one rule or program. M47 introduces versioned PostgreSQL-native policy modules containing shared conditions, parameter sources, decision programs, derivations, actions, and explicit dependencies.

A module should expose a public contract and remain deployable, testable, simulated, backtested, and explained as a coherent unit. It should not become a proprietary package language; the underlying artifacts remain PostgreSQL objects and pg-react declarations.

This milestone makes large policy estates manageable.

## M48 — PostgreSQL policy platform

M48 should intentionally add almost no new reasoning semantics.

Like M18, it is a consolidation milestone. Its job is to prove that the accumulated system still feels simple. A PostgreSQL developer should be able to author policy, validate it, simulate changes, backtest versions, schedule effective dates, deploy modules, inspect current decisions, trace explanations, operate failures, and audit historical outcomes without understanding internal supports, frontiers, correction tables, or worker protocols.

By this point the system may contain highly sophisticated machinery internally. The public experience should remain recognizably PostgreSQL.

---

# How the phases build toward the vision

The sequence matters because each phase solves a different barrier to adoption.

M19 through M23 make the engine structurally complete enough to support larger real systems. They improve composability, retention, explanation, responsiveness, and practical time behavior.

M24 through M29 turn rules into **business policy** and converge its public surface. Policy gains versions, effective dates, typed variation, deterministic decisions, applicability boundaries, and one ordinary workflow.

M30 through M33 make that policy **safe to change**. Users no longer need to deploy first and understand impact second. Simulation, replay, and backtesting bring evidence into the change process.

M34 through M38 make the system **deeply explainable**. Current truth, historical change, causal lineage, and policy differences become first-class inspection surfaces.

M39 through M43 add **practical temporal intelligence** while preserving bounded state and composability. Time becomes something authors can reason about without adopting an event-pattern language.

M44 through M48 mature the engine into a broader **policy platform**, adding carefully controlled rule interaction, richer firing semantics, packaging, and finally another hardening phase that forces all the complexity back behind a simple PostgreSQL-facing model.

The overall path looks like this:

```text
M19–M23   complete the rule runtime
    ↓
M24–M29   make business policy first-class and converge its public API
    ↓
M30–M33   make policy safe to change
    ↓
M34–M38   make decisions deeply explainable
    ↓
M39–M43   add bounded temporal intelligence
    ↓
M44–M48   mature into a PostgreSQL policy platform
```

The unifying idea should remain constant throughout: **PostgreSQL defines and stores the facts; SQL remains the primary language of truth; pg-react adds durable policy semantics around that truth.**

That is the guardrail that prevents the roadmap from becoming an accumulation of rule-engine features for their own sake.

---

# The destination

If these milestones were ever completed, pg-react would occupy an unusual position.

A finance team could define controls, backtest a proposed policy over historical journals, schedule the new version for the next accounting period, and explain why one journal was blocked. An identity team could maintain desired entitlements from shared conditions and parameterized policy, simulate a reorganization before changing access, and trace a revoked permission back to the employment and policy facts that caused it. A compliance team could express deadline and absence rules, preserve evidence for audited decisions, and compare two policy regimes semantically before activating the new one. A product team could use decision tables and parameterized policy families without introducing a separate rules language or policy service.

Internally, pg-react might contain recursion, support graphs, frontiers, logical time, event-time windows, correction histories, decision state, simulation sandboxes, and bounded synchronous loops.

Externally, the experience should still sound simple:

> Define truth in PostgreSQL.  
> Declare which truth matters as policy.  
> See what the policy means before deploying it.  
> Understand why it reached a decision.  
> Trust it to react correctly when the underlying facts change.

That is a much more compelling destination than merely becoming a feature-rich rule engine.

It would make pg-react a PostgreSQL-native system for **living business policy**: policy that can be expressed, composed, tested, changed, explained, recovered, and operated with the database remaining the single authoritative foundation.

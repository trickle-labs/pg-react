# Planned PostgreSQL-facing API redesign

> **Status:** Non-normative design notice  
> **Audience:** Contributors and maintainers  
> **Timing:** Planned before the first public release; no fixed milestone or calendar deadline  
> **Scope:** Public SQL APIs, manifests, command-line interfaces, terminology, diagnostics, and documentation

## Purpose

`pg-react` is still pre-release. Its current public surface has grown alongside the implementation of lifecycle management, durable execution, rule packs, derived knowledge, recursion, stratified negation, aggregation, and related operational guarantees.

That surface is useful for implementing and proving each milestone, but it should not be assumed to be the final PostgreSQL-facing product interface.

Before the first public release, the project intends to perform a deliberate API and usability redesign so that normal usage feels like PostgreSQL first and a rule engine second. The redesign is expected relatively soon in the project’s development, but it does not yet have a fixed milestone number or delivery date.

This document exists to prevent accidental compatibility debt while additional semantic milestones are implemented. It does **not** define or freeze the replacement API.

## What the redesign is expected to achieve

The future interface should let a PostgreSQL developer work primarily with a small set of familiar concepts:

- PostgreSQL views or relations that describe conditions;
- explicit semantic keys;
- typed PostgreSQL functions or outbox actions;
- rules that connect conditions to actions;
- derived relations and facts;
- status, diagnostics, and explanations.

Engine concepts such as immutable versions, activations, generations, episodes, supports, components, frontiers, strata, aggregate evidence, leases, and reconciliation will remain available where they are necessary for correctness or advanced operation. They should not all be prerequisite knowledge for common authoring and inspection tasks.

Likely design directions include:

- concise rule creation with safe defaults;
- inference of redundant information such as rule category, compatible action signatures, dependency polarity, components, and strata;
- name-based authoring and routine inspection, while retaining immutable identifiers for exact history and recovery;
- unified entry points for status, diagnostics, and explanation;
- progressive disclosure of advanced engine state;
- simpler persistent-worker operation;
- PostgreSQL-native deployment and promotion workflows.

These are design goals, not a committed API specification.

## What remains authoritative

Until the redesign is completed, milestone contracts remain authoritative for the semantic and operational behavior they explicitly define, including:

- truth and lifecycle semantics;
- deterministic identity and versioning;
- atomicity and frontier visibility;
- execution, retry, and external-effect guarantees;
- dependency, recursion, negation, and aggregation semantics;
- validation and rejection boundaries;
- provenance and explanation correctness;
- reconciliation, recovery, security, and upgrade behavior;
- executable evidence and regression gates.

The redesign should preserve these guarantees unless a later normative design decision explicitly replaces them.

## What remains provisional

Unless a contract explicitly states otherwise for a released artifact, contributors should treat the following as provisional:

- public function and view names;
- parameter names, ordering, defaults, and overloads;
- schema placement of author, operator, and worker functions;
- exact return-table and JSON presentation shapes;
- manifest fields and environment-mapping syntax;
- the amount of dependency information authors must declare explicitly;
- command-line commands, arguments, environment variables, and worker invocation patterns;
- user-facing terminology inherited from internal engine concepts;
- which identifiers users must supply in routine workflows;
- documentation structure and examples.

Passing tests or inclusion in an unreleased API inventory does not by itself make a surface permanent.

## Guidance for work before the redesign

### Minimize new public surface

Add a new public function, view, manifest field, or command only when the current milestone needs it to prove an end-to-end public workflow. Prefer extending internal primitives or using narrowly scoped provisional entry points over introducing broad convenience APIs prematurely.

### Preserve semantics separately from presentation

Keep correctness logic, catalogs, validation, and execution behavior independent from the exact SQL or CLI presentation wherever practical. A later PostgreSQL-facing function should be able to normalize user intent and call the already-proven engine primitive without rewriting the engine.

### Keep the internal model richer than the accepted syntax

A milestone may intentionally accept only one narrow form, such as one aggregate dependency or one supported comparison. Internal representations should not unnecessarily assume that the current accepted subset is the permanent maximum.

For example, validation may reject multiple aggregate dependencies today while the dependency model still supports multiple typed edges in the future.

### Infer structure, but do not remove future extension points

The future interface should infer engine structure whenever it follows unambiguously from PostgreSQL objects. However, inference must not make it impossible to support later semantics that require explicit declarations.

Users should not manually assign strata or components. The architecture should still leave room for future dependency annotations, temporal relationships, worker capabilities, richer evidence, or other semantics that cannot be inferred from ordinary view dependencies.

### Avoid unnecessary leakage of internal identifiers

New workflows should not require rule-version, program-version, relation-version, support, episode, or frontier identifiers unless exact historical identity is necessary. Preserve those identifiers internally and in advanced inspection APIs so a later name-first interface remains possible.

### Use extensible diagnostic and explanation structures

New explanation and diagnostic data should use versioned or typed envelopes where practical. Do not design a result format that can represent only the current milestone’s evidence kinds.

Future explanations may need to represent additional support, aggregate, temporal, or execution evidence without replacing every entry point.

### Mark provisional documentation clearly

Documentation for unreleased milestones should describe the supported workflow accurately while avoiding claims that exact names and signatures are permanent. Prefer language such as “current repository API” or “repository candidate contract” where appropriate.

### Continue writing exact executable tests

Tests should continue to freeze complete semantic outcomes, failure behavior, recovery results, and public evidence for each milestone. Where a test freezes a provisional API inventory, structure it so the inventory can be intentionally replaced during the redesign without weakening the underlying semantic gates.

### Include a PostgreSQL-user workflow in every semantic milestone

Each advanced milestone should include a brief idealized workflow showing how a PostgreSQL developer ought eventually to express, inspect, and explain the feature.

The workflow may be aspirational and need not match the current repository API exactly. Its purpose is to test whether new semantics can fit a coherent PostgreSQL-facing model.

## Compatibility policy before the first public release

Breaking changes to the public SQL API, manifests, CLI, and terminology are expected before the first public release.

Repository candidates and milestone versions may provide direct upgrade paths for engineering, recovery, and regression evidence. Those paths do not automatically create a promise that every current public call shape will remain available in the final product.

Contributors should therefore avoid:

- adding compatibility aliases solely to preserve unreleased names;
- building new features around accidental API details;
- documenting provisional interfaces as permanent;
- treating internal test usage as evidence of external adoption;
- expanding a provisional interface merely because it already exists.

Once the redesign is made normative, its contract should clearly state which surfaces become compatibility commitments and from which release those commitments begin.

## What this document does not authorize

This notice does not:

- delay or block currently approved semantic milestones;
- replace milestone-specific contracts;
- authorize speculative catalogs or abstractions;
- require implementation of the previously discussed API sketches;
- require a custom rule language or non-SQL DSL;
- weaken correctness, recovery, security, or explanation requirements;
- establish a calendar deadline;
- make the current interface unusable for development and testing.

The current API should remain coherent, documented, and executable while it exists. It simply should not accumulate unnecessary permanence.

## When the redesign becomes normative

The PostgreSQL-facing redesign becomes normative only when the roadmap promotes it into an explicit milestone or release contract with:

- a frozen vocabulary and public API inventory;
- complete author, operator, and worker workflows;
- migration or replacement rules for the provisional surface;
- executable usability and compatibility gates;
- rewritten task-oriented documentation;
- a clear statement of when public compatibility begins.

Until then, the project should optimize milestone APIs for proving semantics while preserving the freedom to redesign the final product boundary deliberately.

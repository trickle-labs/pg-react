# M28 — Public API Convergence and Ergonomics

## Proposed milestone for pg-react extension 0.25.0

> **Status:** Proposed milestone  
> **Predecessor:** M27 / extension `0.24.0`  
> **Direct upgrade:** `0.24.0 -> 0.25.0`  
> **Primary outcome:** make the complete M0–M27 product feel like one coherent PostgreSQL API before additional policy capabilities are added  
> **Semantic scope:** no new rule, decision, temporal, reasoning, execution, or delivery semantics

---

## Why this milestone should exist

pg-react has reached an important transition point. The project has successfully expanded from a small durable reaction engine into a much richer PostgreSQL-native policy system. It can represent rules, maintained facts, recursive derivation, stratified absence, aggregates, deadlines, event-time windows, shared conditions, effective-dated policy, parameter families, decision programs, and decision coverage analysis. Each milestone has been carefully bounded and has generally preserved PostgreSQL as the language and source of truth.

That success creates a new product risk: the engine may remain internally coherent while the public API gradually becomes a collection of feature-shaped function families.

M27 illustrates both sides of the situation. Its semantics are strong: an author can analyze a proposed decision version against an explicit population and candidate catalog, detect uncovered subjects, unreachable candidates, forbidden overlaps, tied winners, missing defaults, and unexpected distribution changes, and then require a fresh passing analysis before deployment. But the capability also adds a specialized sequence of public operations such as validation, authoring an analysis, executing it, admitting a version, inspecting status and history, running specialized diagnostics, and removing the analysis.

That API is understandable in isolation. The danger appears when the same pattern is repeated for policy-set gating, hypothetical simulation, deployment impact analysis, replay, backtesting, promotion workflows, richer explanation, and later temporal features. A PostgreSQL developer should not need to memorize a new miniature API every time pg-react gains a capability.

M28 therefore pauses semantic expansion and establishes the public API architecture that future milestones must fit. Its purpose is not to replace working APIs or hide important operational distinctions behind a vague catch-all function. Its purpose is to create a small, stable, ordinary façade; classify existing specialized routines as advanced compatibility surfaces; define common declarations and result envelopes; and make the default documentation teach one mental model across the entire product.

The guiding principle is:

> **Grow data and supported object kinds more often than verbs.**

A mature pg-react should be able to become much more capable while the number of operations a normal user needs to understand grows very slowly.

---

## Outcome

M28 proves that a normal PostgreSQL developer can use every representative M0–M27 capability through one coherent public workflow:

```text
define
  ↓
validate
  ↓
preview
  ↓
deploy
  ↓
run
  ↓
status / explain / doctor
```

Specialized APIs remain available where they provide advanced control, compatibility, exact operational actions, or lossless evidence. They are not removed, renamed, or behaviorally weakened. The ordinary façade delegates to the same authoritative implementation and must not become a second evaluation or deployment engine.

After M28, future capabilities such as policy-set gating, hypothetical simulation, impact analysis, replay, and backtesting must extend this model rather than introduce an unrelated authoring and inspection family.

---

## Entry gate

M28 begins only after all of the following are true:

1. The immutable `v0.24.0` release identity, archive checksum, OCI digest, SBOM, provenance, and release evidence are published and recorded.
2. The populated direct `0.23.0 -> 0.24.0` upgrade passes.
3. Every inherited M0–M27 semantic, security, recovery, compatibility, performance, documentation, and usability gate passes unchanged.
4. The complete M0–M27 public API inventory is generated from the released extension, including function identities, overloads, arguments, defaults, result types, grants, volatility, security-definer status, public views, and contract-version fields.
5. A frozen ergonomics fixture records the current specialized workflows and exact results for at least:
   - an ordinary command rule;
   - a derived program;
   - one practical temporal rule;
   - an effective-dated or parameterized policy;
   - an M26 decision program; and
   - an M27 decision analysis and deployment admission.
6. The project freezes an API classification policy covering ordinary, advanced, compatibility, administrative, and internal surfaces before new façade functions are implemented.

The entry fixture is important because M28 must improve the public experience without changing the meaning of any existing operation. The milestone cannot use “ergonomics” as permission to blur semantics, weaken admission checks, or silently alter durable state.

---

# Design principles

## 1. One ordinary mental model

The common workflow should not depend on whether the underlying object is called a rule, derivation program, shared condition, parameter family, temporal condition, decision program, or decision analysis. Those distinctions still matter in declarations and evidence, but the basic lifecycle should remain familiar.

A user should learn that declarations can be validated, previewed, deployed, inspected, and explained. They should not first have to learn which historical milestone introduced the object and which function family belongs to that milestone.

## 2. Grow data, not verbs

New capabilities should normally add:

- a new supported declaration `kind`;
- new validated declaration fields;
- new result sections;
- new evidence kinds;
- new public relation columns; or
- new options on an existing generic operation.

They should not automatically add a complete family of `validate_feature`, `author_feature`, `run_feature`, `feature_status`, `feature_history`, `feature_doctor`, and `remove_feature`.

This is not an absolute ban on new functions. A genuinely new user operation—such as future side-effect-free `simulate` or historical `backtest`—may deserve a new top-level verb. The milestone establishes that every such addition requires an explicit API justification and compatibility review.

## 3. Progressive disclosure

The ordinary interface should use stable names, business keys, and concise summaries. UUIDs, immutable version IDs, support identities, frontiers, correction identities, fingerprints, and protocol details remain available when exact evidence or automation requires them, but they should not dominate common examples.

A user should be able to begin with:

```sql
SELECT pgreact_api.status('orders-policy');
```

and request deeper evidence only when necessary.

Progressive disclosure does not mean discarding details. It means putting details behind explicit options, advanced views, or compatibility functions rather than requiring everyone to reason in engine internals.

## 4. No hidden mutation

Generic APIs must preserve clear side-effect boundaries:

- `validate` is read-only;
- `preview` is read-only;
- `status`, `explain`, and `doctor` are read-only;
- `deploy` performs one declared atomic deployment;
- `remove` performs one declared removal;
- `run` performs the inherited coordinator operation.

The milestone must not introduce a generic `operate(target, action_text)` function that hides many materially different state transitions behind arbitrary strings. Retrying failed work, reconciling state, advancing a watermark, correcting a window, or finalizing a temporal frontier remain explicit operations unless a later contract proves a clearer safe abstraction.

## 5. Compatibility before aesthetic purity

M0–M27 specialized APIs are released contracts. M28 may classify them as advanced or compatibility surfaces and may stop teaching them as the ordinary path, but it does not remove them or change their exact behavior.

The new façade must delegate to existing authoritative routines or shared internal implementations. There must never be two subtly different definitions of validation, preview, deployment admission, decision selection, lifecycle, or explanation.

## 6. PostgreSQL-native declarations

M28 must not replace SQL with a proprietary rule language. PostgreSQL relations, typed functions, `regclass` identities, names, keys, and ordinary permissions remain the foundation.

The milestone may introduce a versioned declaration envelope so generic verbs can accept several object kinds. The declaration envelope is a transport and composition format, not a second predicate language. SQL still defines conditions, candidates, parameter relations, and derived relations.

## 7. Stable, versioned result envelopes

Common operations should return envelopes with stable top-level fields so callers do not need to relearn the result shape for every object kind. Feature-specific details can appear in bounded nested sections.

A common envelope might contain:

```json
{
  "contract_version": 16,
  "operation": "preview",
  "target": {
    "kind": "decision_program",
    "name": "orders-policy",
    "version": "proposed"
  },
  "state": "attention",
  "summary": {},
  "findings": [],
  "evidence": {},
  "diagnostics": [],
  "truncated": false
}
```

The exact schema must be frozen by the milestone. The important property is consistency: target identity, state, findings, diagnostics, evidence, and truncation should have common meanings.

---

# Proposed public model

## A versioned declaration envelope

M28 should define one canonical declaration envelope used by ordinary authoring APIs. The recommended shape is a small typed wrapper containing a versioned `jsonb` body:

```sql
CREATE TYPE pgreact_api.declaration AS (
    api_version text,
    kind        text,
    name        text,
    spec        jsonb
);
```

The exact PostgreSQL representation is a milestone decision. A domain or versioned JSONB document may be preferable if it produces better upgrade behavior. Whatever representation is selected must satisfy these requirements:

- every declaration has an explicit API version;
- every declaration has one stable object kind and name;
- object references remain schema-qualified where appropriate;
- validation reports unknown and misplaced fields;
- defaults are explicit in preview output;
- canonical normalization produces a deterministic digest;
- equivalent declarations normalize identically regardless of JSON key order;
- unrecognized future fields are never silently ignored;
- no declaration can mutate durable state before validation succeeds.

A generic helper constructor may be provided:

```sql
SELECT pgreact_api.declaration(
    kind => 'decision_program',
    name => 'orders-policy',
    spec => jsonb_build_object(...)
);
```

This is one generic constructor, not one constructor per milestone. Authors may also build the typed value directly.

## Canonical ordinary verbs

M28 should freeze the following ordinary authoring and inspection verbs:

```sql
pgreact_api.validate(declaration)
pgreact_api.preview(declaration [, options])
pgreact_api.deploy(declaration [, preconditions])
pgreact_api.remove(target [, preconditions])

pgreact_api.status(target [, options])
pgreact_api.explain(target [, subject] [, options])
pgreact_api.doctor([target])

pgreact_api.run([sampled_time])
```

The exact overloads should be kept deliberately small. The milestone should prefer one options document over a large number of positional or defaulted scalar parameters.

`replace` does not necessarily need to be a separate generic verb. A deployment precondition can safely distinguish creation from replacement:

```json
{
  "expected_current_version": "…",
  "allow_create": false
}
```

However, if the project concludes that an explicit `replace` verb is materially safer and clearer, it may remain in the canonical set. M28 must decide this before the façade freezes rather than leaving both patterns casually available.

## A generic target reference

Ordinary inspection should use names first. A target reference should be able to identify an object by stable public kind and name, with optional immutable version identity when exact historical evidence is needed.

Illustrative examples:

```sql
SELECT pgreact_api.status(
    pgreact_api.target('decision_program', 'orders-policy')
);

SELECT pgreact_api.explain(
    pgreact_api.target('decision_program', 'orders-policy'),
    subject => '{"order_id": 42}'::jsonb
);
```

The target constructor should support schema-qualified names and should reject ambiguous resolution. Search-path-dependent dispatch is not acceptable. UUID-only workflows remain available through advanced APIs but should not be required in ordinary documentation.

## Public views remain important

Generic functions should not replace relational inspection. Stable public views remain the best interface for filtering, joining, monitoring, and reporting.

M28 should define which information belongs in:

- generic result envelopes;
- stable public views;
- feature-specific public views;
- advanced evidence functions; and
- compatibility routines.

For example, `status()` can summarize all decision analyses, while `pgreact.decision_analysis_findings` remains the natural relation for querying findings across programs.

---

# How M27 should look through the façade

M27 is the reference convergence case because it currently requires a multi-step specialized workflow.

The ordinary M28 path should allow the proposed decision declaration to include its coverage and admission requirements:

```sql
SELECT pgreact_api.preview(
    pgreact_api.declaration(
        kind => 'decision_program',
        name => 'orders-policy',
        spec => jsonb_build_object(
            'candidate_relation', 'policy.proposed_candidates',
            'subject_key', 'subject_id',
            'candidate_key', 'candidate_id',
            'priority', 'priority',
            'results', jsonb_build_array('outcome'),
            'analysis', jsonb_build_object(
                'population_relation', 'policy.subject_population',
                'population_key', 'subject_id',
                'candidate_catalog', 'policy.candidate_catalog',
                'candidate_key', 'candidate_id',
                'required_default_column', 'required_default',
                'require_default', true,
                'exclusive', true,
                'max_absolute_distribution_delta', 100
            )
        )
    )
);
```

The preview result should contain the M27 findings and exact distribution deltas. If blocking requirements fail, the result state is `attention` and deployment is not allowed.

Deployment should reuse the exact preview digest, frontier, relation fingerprints, and admission evidence:

```sql
SELECT pgreact_api.deploy(
    declaration => :policy,
    preconditions => jsonb_build_object(
        'preview_digest', :preview_digest
    )
);
```

If the population, catalog, current version, proposed version, or relevant frontier changes, deployment must reject the stale preview exactly as `admit_decision_version` does today.

The existing specialized M27 functions remain available for users who need independent reusable analyses, custom analysis lifecycles, explicit admission history, or lower-level automation. The façade does not remove that capability. It simply makes the common case feel like normal preview and deployment.

---

# Deliverables

## 1. Complete public API inventory and classification

Generate and check in a machine-readable inventory of every public function, overload, view, type, grant, result contract, and ordinary documentation reference from M0–M27.

Each surface is classified as:

- **ordinary** — recommended for common workflows;
- **advanced** — public, supported, but requires deeper product knowledge;
- **compatibility** — preserved for existing clients and exact historical contracts;
- **administrative** — installation, role configuration, repair, or privileged operations;
- **internal** — not granted through the public façade.

The inventory becomes a release gate. A future pull request that adds a public routine must classify it and state why an existing ordinary verb cannot express the operation.

## 2. Versioned declaration and target types

Introduce the canonical declaration envelope, target reference, option/precondition representation, normalization rules, and deterministic digests.

The design must remain forward-compatible without silently accepting unknown semantics.

## 3. Generic validation, preview, deployment, and removal

Implement the ordinary façade over representative M0–M27 object kinds. The first release does not need to express every obscure advanced operation through a declaration, but it must cover the normal authoring path for:

- constraint and command rules;
- derived relations/programs;
- temporal/deadline policies;
- shared conditions;
- effective-dated policy;
- parameter families;
- decision programs; and
- decision coverage/admission requirements.

Every façade operation delegates to the same validation and mutation contracts as the specialized APIs.

## 4. Unified inspection behavior

Extend `status`, `explain`, and `doctor` so they accept the canonical target reference and return common envelopes.

The existing name-first global operations remain compatible. Feature-specific status and doctor functions may remain advanced, but ordinary documentation should not require them.

## 5. Common error and finding taxonomy

Freeze consistent meanings for:

- `ERROR`, `WARNING`, and informational findings;
- blocking versus non-blocking findings;
- object identity;
- field paths;
- remediation hints;
- stale evidence;
- bounded evidence and truncation;
- authorization failures; and
- compatibility/deprecation notices.

A declaration error should identify the object, field, invalid value class, and corrective action. A stale preview should identify which fingerprint or frontier changed without leaking unauthorized data.

## 6. Names-first workflows

Ensure every ordinary workflow can use stable public names and business keys. Immutable IDs remain returned and queryable but are not mandatory input unless the caller is deliberately targeting one historical version.

## 7. Documentation convergence

Rewrite the ordinary documentation around one lifecycle:

1. define PostgreSQL relations/functions;
2. create a declaration;
3. validate;
4. preview;
5. deploy;
6. run;
7. inspect and explain.

Feature guides should explain their declaration fields and evidence rather than introduce an independent verb family.

A separate advanced API reference documents specialized M0–M27 routines and exact compatibility guarantees.

## 8. API governance rule

Add an explicit project rule:

> A new milestone may add a top-level ordinary verb only when it introduces a genuinely new user operation that cannot be expressed safely and clearly through an existing verb, declaration kind, result section, public relation, or advanced API.

Any exception requires an ADR describing alternatives, compatibility impact, and why a new verb improves rather than fragments the mental model.

---

# Compatibility and migration

M28 is additive.

All existing M0–M27 function identities, result shapes, grants, views, and semantics remain available. The direct `0.24.0 -> 0.25.0` upgrade adds the façade and metadata without rewriting existing policy state or requiring existing users to migrate declarations.

The specialized APIs remain authoritative compatibility surfaces. The project may label some of them “advanced” in documentation, but it must not emit noisy deprecation warnings merely because a simpler façade exists. Removal or incompatible change requires the established compatibility process and, where appropriate, a future major version.

Façade-created objects must be indistinguishable from equivalent specialized-API-created objects when inspected through lossless advanced views. Conversely, the façade must be able to inspect and manage eligible objects originally created through specialized APIs.

The upgrade must preserve:

- immutable object and version identities;
- current truth and winners;
- lifecycle generations and revisions;
- supports and provenance;
- temporal frontiers, watermarks, corrections, and finalization;
- pending and completed work;
- M27 analyses, findings, fingerprints, and admission history;
- grants and role boundaries; and
- exact recovery behavior.

---

# Security model

Generic functions must not become privilege shortcuts.

Validation, preview, deployment, removal, status, explanation, and diagnostics must enforce the exact ownership and role checks inherited from the underlying object kind. The generic façade may only perform an operation the caller could perform through the authoritative specialized API.

The declaration envelope must not permit callers to smuggle private relation OIDs, unsafe search paths, arbitrary SQL strings, or internal object identifiers past normal validation.

Result envelopes must preserve row-level disclosure boundaries. A reader may be allowed to know that an analysis has blocking findings without seeing sensitive example subjects. Advanced evidence remains separately granted and bounded.

`PUBLIC` receives no new access merely because generic functions are added.

---

# Explicit non-goals

M28 does **not** add:

- policy-set gating;
- hypothetical fact simulation;
- deployment impact simulation;
- historical replay;
- comparative backtesting;
- policy promotion workflows;
- new temporal operators;
- new decision semantics;
- synchronous rule firing;
- automatic repair;
- a client SDK;
- a visual editor;
- an AI authoring layer;
- a proprietary policy language; or
- a generic stringly typed action executor.

M28 does not remove specialized APIs, flatten important domain distinctions, or make all objects share identical lifecycle semantics. It creates one ordinary interaction model while preserving exact object-specific contracts underneath.

M28 also does not require every administrative and recovery action to collapse into the canonical verbs. Operations such as reconciliation, retry, correction, finalization, and watermark advancement remain explicit where their distinct safety contracts matter.

---

# Implementation sequence

## Slice 1 — Inventory and freeze

Generate the exact M0–M27 public inventory, classify every surface, freeze representative workflows, and identify naming, argument-count, result-shape, and discoverability problems.

No façade code begins before this inventory is reviewed.

## Slice 2 — Declaration, target, and envelope contracts

Implement the canonical declaration and target types, normalization, digesting, field-path validation, common result envelope, and options/preconditions model.

Prove deterministic normalization across key ordering, restart, restore, and upgrade.

## Slice 3 — M27 convergence vertical slice

Implement the generic preview/deploy path for one M26 decision program with M27 coverage requirements. Prove that preview findings and deployment admission are byte-equivalent to the specialized M27 workflow and that stale evidence is rejected.

This is the milestone’s critical vertical slice.

## Slice 4 — Representative M0–M25 façades

Add ordinary façade support for the representative rule, derivation, temporal, shared-condition, effective-date, and parameter-family fixtures.

Do not attempt to expose every advanced tuning knob in the first façade. Advanced options may remain in specialized declarations until a clear common representation exists.

## Slice 5 — Unified inspection and documentation

Converge `status`, `explain`, and `doctor`, restructure the guides, and run independent usability exercises.

## Slice 6 — Compatibility, recovery, and release

Run every inherited gate, populated upgrade, backup/restore, logical restore, standby promotion, role/grant audit, documentation audit, and public inventory comparison before publishing `v0.25.0`.

---

# Exit gates

All M28 gates are release-blocking.

## Ordinary workflow gate

A PostgreSQL developer unfamiliar with M19–M27 terminology can complete the representative authoring path using only ordinary documentation and the canonical façade:

```text
define → validate → preview → deploy → run → status/explain
```

They do not need to call feature-specific status, doctor, analysis, or admission functions.

## Coverage gate

The façade supports the frozen representative workflows for rules, derivation, temporal policy, shared conditions, effective dates, parameter families, decisions, and decision analysis.

## Semantic equivalence gate

For every representative workflow, the generic façade and specialized API produce exactly equivalent normalized declarations, durable state, public truth, lifecycle, evidence, diagnostics, grants, and final checksums.

## M27 admission gate

Generic preview returns the exact M27 findings, distributions, evidence ordering, truncation flags, blockers, and remediation. Generic deployment rejects failed or stale evidence before any policy, lifecycle, provenance, or work state changes.

## Read-only boundary gate

`validate`, `preview`, `status`, `explain`, and `doctor` produce no durable mutations, jobs, actions, frontier changes, or hidden repairs.

## Compatibility gate

Every released M0–M27 public function and view remains present with the same identity, grants, defaults, result type, and semantics. All inherited tests pass unchanged.

## Security gate

The façade grants no caller more authority or evidence than the corresponding specialized API. Cross-owner operations, unauthorized evidence access, unsafe relations, RLS boundaries, and private-catalog access remain rejected.

## API inventory gate

The machine-readable inventory contains no unclassified public surface. Any new ordinary top-level verb has an approved API justification. Documentation identifies one ordinary path and one advanced compatibility reference.

## Argument ergonomics gate

Ordinary authoring examples contain no feature-specific function with more than a small frozen number of scalar arguments. Complex declarations use named fields in the canonical declaration rather than long positional signatures.

## Names-first gate

Every ordinary example uses stable names and business keys. UUIDs appear only in returned evidence or explicitly advanced historical/version workflows.

## Recovery and upgrade gate

Fresh install, direct `0.24.0 -> 0.25.0` upgrade, crash/restart, physical restore, logical restore, reconciliation, and standby promotion preserve exact existing state and façade/specialized equivalence.

## Documentation and usability gate

Every ordinary documentation snippet executes in CI. An independently observed PostgreSQL developer can complete the M27 decision preview and safe deployment workflow through the façade without maintainer interpretation.

## Performance gate

The façade adds only a bounded, published overhead relative to direct specialized calls and does not duplicate materialization, analysis, or evaluation work.

---

# Risks and mitigations

## Risk: the generic API becomes vague

A function such as `deploy(jsonb)` can become difficult to understand if every semantic distinction is hidden in an opaque document.

**Mitigation:** use explicit versioned kinds, strict field validation, canonical normalized previews, field-path errors, and stable typed target references. Preserve specialized APIs for advanced exact control.

## Risk: JSON becomes a second rule language

If predicates, transformations, or expressions move into JSON, pg-react loses its PostgreSQL-native advantage.

**Mitigation:** declarations reference PostgreSQL relations, columns, functions, and existing policy objects. They do not encode a new condition expression language.

## Risk: façade and specialized behavior drift

Two implementations could produce subtly different validation or deployment outcomes.

**Mitigation:** the façade must delegate to shared authoritative internals, and equivalence tests compare exact state and outputs.

## Risk: too much compatibility clutter

Keeping every historical function visible may still overwhelm users browsing the schema.

**Mitigation:** documentation, public inventory metadata, comments, and generated references clearly distinguish ordinary and advanced surfaces. Compatibility is preserved without presenting every function as equally recommended.

## Risk: over-generalization hides safety boundaries

A single generic operation might encourage unsafe assumptions across very different object kinds.

**Mitigation:** common verbs share interaction semantics, not object semantics. Each declaration kind retains exact validation, locking, lifecycle, recovery, and authorization rules.

---


# Making API ergonomics a permanent product discipline

M28 should not be treated as a one-time cleanup release after which feature-specific API growth resumes. Its more important contribution is to establish **API ergonomics as a permanent product discipline**. Every later milestone should be evaluated not only on whether its semantics are correct, but also on whether those semantics fit the public mental model without forcing ordinary users to learn a new subsystem.

The project already treats correctness, recovery, security, performance, compatibility, documentation, and usability as continuing workstreams. API ergonomics should become an explicit part of the same release discipline. A feature is not complete merely because its internal catalog, SQL implementation, and evidence gate work. It is complete only when a PostgreSQL developer can discover the capability, express the common case with a small number of named concepts, understand the result, diagnose failure, and move to deeper controls only when needed.

The ongoing goal should be:

> **The engine may become more sophisticated, but the ordinary user journey should remain stable.**

Future milestones should therefore expand the meaning of declarations, targets, findings, evidence, simulation inputs, and public relations more often than they expand the set of top-level operations.

## A standing API design policy

After M28, every milestone proposal should include a dedicated **Public API impact** section before its contract is frozen. That section should answer:

1. What new user goal does the milestone enable?
2. What is the shortest safe path for the common case?
3. Which existing ordinary verb expresses that goal?
4. Which declaration kind or fields must be added?
5. Which result-envelope sections must be extended?
6. Can the capability be inspected through existing `status`, `explain`, and `doctor` operations?
7. Does the milestone introduce any new top-level verb? If so, why can it not be represented clearly and safely by an existing operation?
8. Which specialized APIs remain necessary for advanced control?
9. How does the change preserve names-first workflows and progressive disclosure?
10. What usability evidence will prove that the feature did not fragment the product?

A milestone should not enter implementation while these answers remain vague. This mirrors pg-react’s existing semantic discipline: public interaction contracts should be frozen before product code makes accidental choices durable.

## Maintain an ordinary-verb budget

The project should maintain a deliberately small **ordinary-verb budget**. The expected long-term set should remain close to:

```text
validate
preview
deploy
remove

run

status
explain
doctor

simulate
backtest
```

Even this list should not be treated as a target to fill. `simulate` and `backtest` should appear only when those genuinely new user operations are implemented. New capabilities such as policy-set gating, richer temporal declarations, evidence snapshots, or policy modules should normally fit the existing verbs.

A new ordinary verb should require an ADR that compares at least three options:

- extending an existing declaration or option schema;
- exposing the capability through an existing ordinary verb plus a public relation; and
- adding a new top-level operation.

The ADR should explain why a new verb reduces rather than increases conceptual complexity. Convenience alone is not enough, because one convenient function per milestone eventually creates an inconvenient product.

## Require an ergonomics budget for every feature

Every feature adds cognitive cost. Some cost is unavoidable, but it should be measured and budgeted.

Each future milestone should state:

- the number of new ordinary concepts introduced;
- the number of new required declaration fields;
- the number of new top-level ordinary functions;
- the number of new result-envelope concepts;
- whether a normal workflow now requires UUIDs or internal terminology;
- whether documentation introduces a separate lifecycle or vocabulary; and
- whether an existing task becomes simpler, unchanged, or more complicated.

The preferred outcome is often **zero new verbs, zero required internal identifiers, and one or two new declaration concepts**. A milestone that adds substantial semantics may still justify more, but the cost should be visible and deliberate.

The API inventory introduced by M28 can make this enforceable. CI can compare the current public inventory against the previous released version and require explicit approval for every added ordinary surface.

## Design the happy path before the advanced path

For each capability, the project should design and test the ordinary user journey before exposing every expert control.

For example, policy-set gating should first answer:

> “How does an author say that this policy applies to EU customers?”

The ordinary answer might be one `applicability` section in a declaration, followed by the familiar `preview` and `deploy` operations. Only afterward should the project expose advanced controls for independent gate lifecycle, transition auditing, or low-level reconciliation.

Similarly, hypothetical simulation should first support one clear operation:

```sql
SELECT pgreact_api.simulate(target, scenario);
```

The common result should use the same findings, target identity, evidence, and truncation model as preview and explanation. Advanced options for sampled time, frontiers, selected evidence, or resource budgets should remain optional.

This ordering prevents the internal implementation model from dictating the public API.

## Keep one vocabulary across milestones

Later milestones should reuse established words rather than invent near-synonyms.

A `target` should remain a target whether it refers to a rule, decision program, policy set, simulation, or historical policy version. A `finding` should have the same severity and blocker semantics everywhere. `Evidence` should always be bounded and disclose truncation. `Preview` should always be read-only. `Deploy` should always be an atomic authoritative transition with explicit stale-precondition behavior.

The project should maintain a small public vocabulary glossary and reject milestone-specific terminology when an existing word already expresses the concept. Internal terms such as frontier, support, correction identity, component, stratum, or immutable engine ID may still appear in deep evidence, but ordinary operations should lead with policy names, business keys, states, reasons, and recommended next steps.

## Reuse result envelopes aggressively

Future capabilities should extend shared result envelopes rather than return unrelated JSON shapes.

For example:

- policy-set gating can add an `applicability` section;
- hypothetical simulation can add `hypothetical_changes` and `would_change`;
- deployment impact analysis can add `current`, `proposed`, and `delta`;
- historical replay can add `input_frontier`, `output_frontier`, and replay summaries;
- backtesting can add comparative metrics and selected changed subjects;
- why-changed explanations can add a bounded `causal_delta`.

The surrounding envelope should still contain the same target identity, operation, state, findings, diagnostics, evidence, authorization outcome, and truncation fields. This consistency benefits interactive users, SQL clients, monitoring, documentation, and future SDKs without requiring pg-react to introduce a client-specific protocol.

## Preserve relational inspection

API convergence should never mean “everything returns one giant JSON document.”

PostgreSQL users expect to filter, aggregate, join, and monitor data relationally. Every milestone should decide which outputs deserve stable public views. Generic operations are best for one target, one workflow, or one bounded report; public relations are best for fleet-wide inspection and automation.

For example, `preview()` may return a summary of M27 findings, while `pgreact.decision_analysis_findings` remains the best interface for querying every blocking conflict. A future `simulate()` call may return a bounded report, while a simulation-results relation may support detailed analysis within a retained simulation scope.

Maintaining both a coherent verb layer and a relational inspection layer is part of being genuinely PostgreSQL-native.

## Establish ordinary, advanced, and administrative tiers

M28 should permanently formalize three documentation and discovery tiers.

### Ordinary

The shortest recommended path for application authors and operators. These APIs use stable names, business keys, safe defaults, common envelopes, and progressive disclosure.

### Advanced

Supported feature-specific operations for users who need exact lifecycle control, reusable analyses, specialized evidence, explicit frontiers, custom limits, or automation beyond the common workflow.

### Administrative

Installation, role configuration, repair, migration, retention, recovery, and privileged maintenance operations.

Compatibility routines can be documented alongside advanced APIs but should carry clear historical context. This tiering lets pg-react preserve its strong compatibility discipline without presenting hundreds of public functions as equally important to a new user.

## Add ergonomic acceptance tests

Every future milestone should include at least four API-focused gates in addition to semantic evidence:

1. **Common-path test:** the representative use-case completes through ordinary APIs only.
2. **Discoverability test:** `status`, `doctor`, documentation, or SQL comments identify the next valid operation without requiring private knowledge.
3. **Progressive-disclosure test:** advanced identifiers and evidence are available but absent from the default happy-path transcript unless needed.
4. **Compatibility-equivalence test:** ordinary and advanced workflows reach the same authoritative result.

For larger milestones, an independently observed PostgreSQL developer should complete the workflow without being told which milestone-specific functions exist. The test is not whether the user can copy a prepared command blindly; it is whether the public model helps them recover from an intentional validation error and understand why deployment is blocked.

## Measure ergonomics over time

The project should publish a small API-ergonomics scorecard with each release. Useful metrics include:

- count of ordinary top-level verbs;
- count of required concepts in the getting-started path;
- count of scalar arguments in ordinary examples;
- percentage of common workflows using names rather than UUIDs;
- number of feature-specific functions required by ordinary documentation;
- time to complete representative tasks;
- number of private-catalog or advanced API references in common guides;
- number of distinct result-envelope shapes; and
- compatibility-surface growth.

These metrics are not perfect measures of usability, but they expose drift. If each milestone adds three new ordinary functions or if the canonical example grows from five concepts to twenty, the project will see the problem before users do.

## Treat documentation as part of the API

The API users experience is the combination of function names, declaration shapes, result messages, examples, and troubleshooting guidance. Future releases should update one authoritative task-oriented path rather than simply append another milestone guide.

Each feature guide should begin with:

- the user problem;
- the smallest working declaration;
- `validate → preview → deploy`;
- the normal `status` and `explain` path;
- one expected failure with actionable remediation; and
- the boundary beyond which advanced APIs are needed.

Generated API references remain useful, but the main documentation should be organized around tasks rather than catalogs of functions.

## Schedule periodic convergence milestones

M28 should establish the architecture, but later accumulation may still create friction. The roadmap should reserve the right to schedule another M18/M28-style consolidation milestone after a major cluster of capabilities—perhaps after simulation and backtesting, and again after richer temporal reasoning.

Such a milestone should add little or no semantics. It should simplify declarations, unify evidence, improve names and summaries, remove duplication from ordinary documentation, audit compatibility, and repeat human usability studies.

This creates a healthy rhythm:

```text
add a bounded capability
    ↓
prove semantics and operations
    ↓
add several related capabilities
    ↓
converge and simplify the public experience
```

Without periodic convergence, even a well-designed generic façade can accumulate accidental complexity.

## Make ergonomics a release blocker

Most importantly, API ergonomics should have authority. A future milestone should not ship merely because its correctness suite passes if its normal workflow requires internal IDs, duplicates an existing verb, produces an unrelated result shape, or forces ordinary users into an advanced feature family without justification.

The release decision should ask two equally serious questions:

1. Is the new capability correct and recoverable?
2. Does it still feel like pg-react?

The second question protects the long-term product advantage. Many systems can accumulate powerful rule features. Far fewer can remain understandable while doing so.


# Effect on the roadmap

This milestone should become the new **M28**. The existing proposed sequence shifts by one:

- **M29 — Policy-set gating**
- **M30 — Hypothetical fact simulation**
- **M31 — Deployment impact simulation**
- **M32 — Historical replay**
- **M33 — Comparative backtesting**

The shift is strategically useful. These upcoming capabilities would otherwise be likely to introduce additional feature-specific API families. M28 establishes the declaration, target, result, and governance model they must use.

Policy-set gating should become a declaration kind or policy applicability section rather than a new family of ordinary authoring verbs. Hypothetical simulation and backtesting may justify the genuinely new verbs `simulate` and `backtest`, but they should reuse the same target references, declarations, options, findings, evidence, and result envelopes established here.

---

# Definition of success

M28 succeeds when pg-react becomes easier to learn even though no existing capability has been removed.

A new user should see a small set of verbs and a consistent workflow. An expert should still have access to exact specialized controls and lossless evidence. Existing clients should continue to work unchanged. Future milestones should have a clear place to add their declarations and results without growing a new mini-API.

The desired mature mental model is:

> **Define PostgreSQL truth. Declare policy. Validate and preview it. Deploy it safely. Run it. Inspect and explain the result.**

If pg-react can preserve that mental model while continuing toward simulation, replay, backtesting, richer explanation, and temporal intelligence, API simplicity will become one of the project’s strongest advantages rather than a constraint on its ambition.

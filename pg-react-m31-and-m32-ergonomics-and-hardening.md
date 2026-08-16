# M31 + M32: PostgreSQL-Native Ergonomics and V1 Hardening

> **Status:** Proposed v1 program<br>
> **Date:** 2026-08-16<br>
> **Predecessor:** M30 / proposed extension `0.27.0`<br>
> **M31 proposed release:** extension `0.28.0`<br>
> **M32 proposed release:** extension `0.29.0`<br>
> **Required release candidate:** at least one exact `1.0.0-rc.N` artifact<br>
> **Final release:** extension `1.0.0`<br>
> **Direct v1 qualification and GA upgrade targets:** `0.26.0 -> 1.0.0-rc.N` and `0.26.0 -> 1.0.0`<br>
> **Replaces:** the currently planned M31 deployment-impact simulation and M32 historical replay milestones<br>
> **Primary outcome:** make pg-react easy for PostgreSQL developers to learn and operate, then freeze and prove that interface as the supported `1.0.0` contract<br>
> **Semantic scope:** no new rule, reasoning, temporal, decision, execution, policy, or delivery semantics after M30

---

## 1. Decision

M31 and M32 should complete the path from the M30 behavioral foundation to pg-react `1.0.0`.

The program is divided deliberately:

> **M30 makes the product correct. M31 makes the correct product easy to use. M32 proves it is stable enough to freeze.**

The current roadmap assigns M31 to deployment-impact simulation and M32 to historical replay. Those capabilities are valuable, but neither is necessary to make the existing engine a powerful, ergonomic PostgreSQL-native rule engine. Both introduce substantial new semantic and testing surface immediately before the point where the project most needs convergence and stability. They should therefore move after `1.0.0`.

M31 MUST focus on the PostgreSQL developer experience.

M32 MUST focus on compatibility, installation, upgrades, recovery, security, performance, documentation, and independent usability evidence.

M31 design validation begins during M30: the five-person usability cohort is recruited before M31 starts, and early transcript or prototype feedback may still change the interface. Fresh-install, populated `0.26.0` upgrade, rollback-by-restore and recovery, role-isolation, packaged-artifact, and performance evidence also runs continuously through M30 and M31; M32 consolidates already-green evidence rather than discovering these matrices for the first time.

Neither milestone may introduce a second evaluation model, new reasoning semantics, a proprietary rule language, historical replay, hypothetical simulation, or another ordinary API family.

---

# Part I: M31

# M31: PostgreSQL-Native Ergonomics

> **Proposed extension:** `0.28.0`<br>
> **Predecessor:** M30 / `0.27.0`<br>
> **Direct upgrade:** `0.27.0 -> 0.28.0`<br>
> **Primary outcome:** make ordinary pg-react usage feel like PostgreSQL with durable rules, rather than a framework whose internal engine concepts must be learned first<br>
> **Feature policy:** no new runtime semantics

M31 implementation MUST NOT begin until all M30-A through M30-D gates and the independent technical review pass, the five-person usability cohort is recruited, early design feedback is recorded, and the continuous v1 qualification lane is green.

---

## 2. M31 objective

M31 is complete when a PostgreSQL developer can understand, author, deploy, inspect, diagnose, replace, and remove the ordinary pg-react objects without:

- constructing JSON by hand for the common path;
- supplying UUIDs;
- accessing private catalogs;
- knowing which historical milestone introduced a feature;
- choosing among overlapping API families;
- understanding activations, episodes, supports, frontiers, fingerprints, strata, or worker protocols before creating a first rule;
- reading engine internals to interpret an error;
- remembering different inspection workflows for different ordinary object kinds.

The engine may remain substantially richer internally.

The ordinary experience should expose only the concepts needed to make the correct decision at the current level of use.

This follows the project's existing PostgreSQL-facing design goal: ordinary users should primarily work with PostgreSQL relations, semantic keys, typed actions, rules, derived relations, status, diagnostics, and explanations, while advanced engine identities remain available when exact operational evidence is required.

---

## 3. M31 product principles

### 3.1 PostgreSQL is the language

Conditions remain ordinary PostgreSQL queries exposed through relations or views.

Actions remain typed PostgreSQL functions or explicitly registered external-delivery sinks.

Parameters remain PostgreSQL data.

Applicability remains PostgreSQL data.

Decision candidates remain PostgreSQL data.

pg-react MUST NOT introduce a predicate DSL, expression language, YAML condition syntax, JavaScript evaluator, or proprietary rule language.

### 3.2 One ordinary mental model

The ordinary product model MUST reduce to six concepts:

1. **Condition**<br>
   PostgreSQL data describing what is true.

2. **Rule**<br>
   Connects a condition to lifecycle behavior and optional actions.

3. **Action**<br>
   Typed PostgreSQL function or registered external delivery.

4. **Decision**<br>
   Selects an authoritative result from relational candidates.

5. **Policy set**<br>
   Restricts existing policy behavior to an eligible subject population.

6. **Work**<br>
   Durable requested execution and its outcome.

Derivations, temporal state, provenance, event-time correction, parameter families, effective dates, supports, frontiers, leases, attempts, and reconciliation remain available as advanced concepts.

### 3.3 Safe defaults over required configuration

An author SHOULD specify only information pg-react cannot derive safely.

M31 SHOULD infer, where unambiguous:

- whether a rule is constraint-only or command-producing;
- condition row type;
- action argument compatibility;
- watched non-key columns;
- object owner;
- schema-qualified object identity;
- subject identity when it is equal to match identity;
- default lifecycle action absence;
- default global versus explicitly scoped behavior;
- current version during name-first inspection.

Inference MUST fail rather than guess when multiple interpretations are valid.

### 3.4 Names first, immutable identity underneath

Routine authoring and inspection MUST use stable names.

Immutable UUIDs, version IDs, digests, episode IDs, frontier identities, and support identities remain available in advanced evidence and history.

A routine workflow MUST NOT require copying an internal UUID from one query into another.

### 3.5 Relational first, JSON when depth requires it

Anything users commonly filter, join, aggregate, alert on, or monitor MUST be available relationally.

JSONB remains appropriate for:

- canonical interchange declarations;
- nested explanation evidence;
- bounded proof trees;
- automation envelopes;
- future-compatible detail payloads.

JSONB MUST NOT replace ordinary SQL columns where stable relational fields exist.

### 3.6 Errors must teach the correction

A validation error MUST identify:

- what object failed;
- what field or PostgreSQL identity caused the failure;
- why it is invalid;
- whether deployment is blocked;
- exactly what the user can change.

Expected user errors SHOULD return stable findings.

Unexpected infrastructure errors SHOULD use stable SQLSTATE values together with PostgreSQL `DETAIL` and `HINT`.

---

## 4. Canonical v1 schema strategy

M31 MUST resolve the current naming split between ordinary `pgreact_api` functions and `pgreact` inspection objects.

The canonical v1 experience SHOULD use:

```text
pgreact
```

for ordinary public functions, types, and views.

Examples:

```sql
SELECT pgreact.rule(...);
SELECT pgreact.preview(...);
SELECT pgreact.deploy(...);
SELECT pgreact.run();
SELECT pgreact.status(...);
SELECT * FROM pgreact.rules;
SELECT * FROM pgreact.work;
```

`pgreact_internal` remains private.

Existing released `pgreact_api` functions MUST remain available through compatibility wrappers where preserving their contract is required. Compatibility wrappers MUST delegate to the same authoritative internal implementation and MUST NOT become a second behavior path.

M31 documentation MUST teach one schema only for new ordinary usage.

The project naming section already states that PostgreSQL functions belong in `pgreact`, while much of the current ordinary API is demonstrated through `pgreact_api`; M31 closes that product inconsistency.

---

## 5. Typed authoring becomes the primary interface

### 5.1 Generic JSON declarations become interchange format

The versioned M28 declaration format remains useful for:

- CI;
- GitOps;
- promotion between environments;
- canonical digests;
- automated tooling;
- export and import;
- future language bindings.

It MUST remain supported.

It MUST NOT remain the primary hand-authored SQL interface.

M28 intentionally established declarations as a transport and composition format rather than a second rule language. M31 builds a PostgreSQL-native authoring layer that normalizes into that same representation.

### 5.2 Typed constructors

M31 MUST provide typed constructors for every ordinary v1 deployable kind.

At minimum:

```sql
pgreact.rule(...)
pgreact.decision(...)
pgreact.policy_set(...)
```

Each constructor returns the canonical declaration value consumed by:

```sql
pgreact.validate(...)
pgreact.preview(...)
pgreact.deploy(...)
```

There MUST still be only one deployment engine.

### 5.3 Rule constructor

The ordinary rule constructor SHOULD approximate:

```sql
SELECT pgreact.rule(
    name         => 'manual_review_required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    match_keys   => ARRAY['order_id']::name[],
    subject_keys => ARRAY['customer_id']::name[],
    on_activate  =>
        'rule_action.open_review(
            pgreact.activation_context,
            rule_def.high_value_risky_order
        )'::regprocedure
);
```

A constraint rule SHOULD require only:

```sql
SELECT pgreact.rule(
    name       => 'invalid_invoice',
    condition  => 'rule_def.invalid_invoice'::regclass,
    match_keys => ARRAY['invoice_id']::name[]
);
```

The exact function signatures are frozen by the M31 contract, but they MUST satisfy these requirements:

- names use PostgreSQL scalar types;
- relations use `regclass`;
- functions use exact `regprocedure` identities;
- keys use `name[]`;
- timestamps use `timestamptz`;
- durations use `interval`;
- options with stable independent meaning use typed arguments where practical;
- uncommon or extensible settings MAY use one bounded options structure;
- named arguments are the canonical documentation form;
- unknown behavior is never silently inferred.

### 5.4 Action identity

M31 MUST freeze one ordinary representation for actions.

Database-local actions MUST resolve to exact function identity at deployment.

Function overload resolution MUST NOT depend on `search_path`.

The existing M13 action contract already records exact function OID, qualified `regprocedure`, function digest, dispatcher identity, and dispatcher digest so later overload or search-path changes cannot silently retarget work. M31 preserves that guarantee.

### 5.5 Policy-set constructor

An ordinary policy set SHOULD approximate:

```sql
SELECT pgreact.policy_set(
    name          => 'eu_review_policy',
    members       => ARRAY[
        pgreact.target('rule', 'manual_review_required')
    ],
    applicability => 'policy.eu_customers'::regclass,
    subject_keys  => ARRAY['customer_id']::name[],
    valid_from    => '2026-09-01 00:00:00+00'::timestamptz
);
```

The constructor MUST normalize into the M30 authoritative policy-set representation.

### 5.6 Decision constructor

An ordinary decision SHOULD allow a PostgreSQL relation to remain authoritative for candidates and outputs.

Authors SHOULD NOT need to know the milestone-specific M26 or M27 API sequence.

The constructor MUST expose the minimum fields necessary to determine:

- subject identity;
- candidate identity;
- priority or existing frozen selection semantics;
- result columns;
- optional current coverage/admission requirements if they remain part of the ordinary deployment contract.

No new decision semantics are permitted.

---

## 6. Canonical ordinary verbs

M31 MUST freeze the intended `1.0.0` ordinary verb set.

The target set is:

```sql
pgreact.validate(declaration)
pgreact.preview(declaration [, options])
pgreact.deploy(declaration [, preconditions])
pgreact.remove(target [, preconditions])

pgreact.status(target [, options])
pgreact.explain(target [, subject] [, options])
pgreact.doctor([target])

pgreact.run([sampled_time])
```

M28 established this common workflow concept. M31 converts it from a convergence façade into the final PostgreSQL-native author experience.

No new top-level ordinary verb may be added in M31 unless:

1. an existing verb cannot represent the operation without becoming misleading;
2. the operation has materially different side effects;
3. the API inventory records the justification;
4. the v1 review explicitly approves it.

---

## 7. `run()` becomes unambiguous

The only ordinary coordinator operation MUST be:

```sql
SELECT pgreact.run();
```

or:

```sql
SELECT pgreact.run(sampled_time => ...);
```

M13 already defines the canonical coordinator as one globally serialized, atomic run.

M31 ordinary documentation MUST NOT teach:

```text
run_rule
run_policy
run_program
run_policy_set
run(target)
```

as separate coordinator concepts.

Compatibility functions MAY remain but MUST delegate to the global coordinator where their released contract requires it.

If a maintenance operation has materially different semantics, such as repair, retry, reconciliation, correction, or retention, it remains an explicitly named advanced or administrative operation.

---

## 8. Stable inspection model

### 8.1 Required ordinary views

M31 MUST freeze a compact relational inspection surface equivalent to:

```text
pgreact.rules
pgreact.matches
pgreact.decisions
pgreact.policy_sets
pgreact.work
pgreact.attempts
pgreact.health
```

The exact final inventory is an M31 contract decision.

The ordinary views MUST be sufficient for common SQL questions without joining private catalogs.

### 8.2 `pgreact.rules`

At minimum:

- rule name;
- active version;
- rule kind;
- condition relation;
- match keys;
- subject keys;
- scope mode;
- current state;
- current match count;
- active activation count;
- pending work count;
- health state;
- last complete run;
- drift state.

### 8.3 `pgreact.matches`

At minimum:

- rule name;
- match identity;
- subject identity;
- raw truth;
- effective truth;
- activation generation;
- revision;
- policy scope state;
- current payload or bounded representation;
- last transition time.

### 8.4 `pgreact.work`

At minimum:

- rule or decision name;
- match or subject identity;
- action;
- lifecycle event;
- generation and revision;
- state;
- priority;
- attempt count;
- next retry time;
- lease state;
- created time;
- completed time;
- public failure code.

The term **work** becomes ordinary vocabulary.

The exact internal episode and agenda identities remain available in advanced inspection.

### 8.5 `pgreact.health`

Fleet-wide operational health MUST be queryable as rows.

It MUST expose blockers such as:

- source drift;
- action drift;
- applicability drift;
- recovery barrier;
- incomplete frontier;
- failed work;
- exhausted retry;
- unsupported runtime tuple;
- pending declaration migration;
- stale worker protocol;
- invalid role configuration.

Monitoring MUST NOT require calling `doctor()` separately for every object.

---

## 9. `status`, `explain`, and `doctor`

### 9.1 `status`

`status` answers:

> What state is this object in now?

Its default result MUST be concise.

Advanced options MAY expose:

- immutable identities;
- fingerprints;
- frontiers;
- history;
- exact support evidence;
- worker protocol information.

### 9.2 `explain`

`explain` answers:

> Why is this subject or match in this state?

For a normal rule it MUST be possible to learn:

1. whether the underlying condition currently matches;
2. which match keys identify the row;
3. which subject keys govern policy scope;
4. whether policy scope admits it;
5. whether an activation exists;
6. which generation and revision are current;
7. which lifecycle event occurred;
8. which action was requested;
9. what happened to the work;
10. which blocking reason applies if nothing happened.

An ordinary user SHOULD NOT need to join five engine catalogs to answer this question.

### 9.3 `doctor`

`doctor` answers:

> Can this installation or target operate safely, and if not, what must be fixed?

Global doctor output MUST include:

- extension version;
- PostgreSQL compatibility;
- pg_trickle compatibility;
- managed-runtime readiness;
- role configuration;
- recovery state;
- coordinator state;
- worker state;
- source and function drift;
- blocked targets;
- failed work;
- pending migration;
- unsupported conditions.

Every blocking finding MUST provide a remediation.

---

## 10. Common finding taxonomy

M31 MUST freeze a stable finding structure.

Every finding MUST contain:

```text
code
severity
blocking
target
field
message
hint
details
```

`severity` MUST be one of:

```text
ERROR
WARNING
INFO
```

Stable categories MUST cover at least:

- invalid declaration;
- missing PostgreSQL object;
- ambiguous PostgreSQL object;
- wrong key type;
- invalid action signature;
- unauthorized object;
- RLS unsupported;
- source drift;
- action drift;
- stale preview;
- unsupported ordinary kind;
- advanced-only operation;
- resource limit;
- recovery barrier;
- incomplete frontier;
- policy-scope incompatibility;
- declaration migration required;
- deprecated compatibility surface.

Finding codes become part of the `1.0.0` compatibility inventory.

Messages MAY improve after v1.

The semantic meaning of a stable code MUST NOT silently change.

---

## 11. Preview requirements

M31 MUST turn `preview` into the place where a PostgreSQL developer gains confidence before deployment.

For an ordinary rule, preview MUST include:

- normalized declaration;
- authoritative object identities;
- declaration digest;
- inferred defaults;
- condition shape;
- key types;
- compatible action identities;
- raw current match count;
- effective match count;
- scoped-out count where applicable;
- current deployed version;
- whether the operation would create or replace;
- source fingerprints;
- blocking findings;
- warnings;
- bounded representative evidence.

For policy sets it additionally MUST include:

- eligible subject count;
- member count;
- incompatible member findings;
- bounded subject evidence;
- effective-date state.

For decisions it MUST reuse existing current coverage, conflict, ambiguity, and admission evidence where that evidence is part of the deployed ordinary contract.

M31 does not add full deployment-impact simulation.

It does not promise exact per-subject hypothetical lifecycle changes under arbitrary undeployed definitions.

That capability remains post-v1.

---

## 12. Export and migration-friendly deployment

M31 MUST make SQL migrations a first-class deployment workflow.

### 12.1 Idempotent deployment

The ordinary API MUST support an explicit safe replacement precondition.

A migration SHOULD be able to state:

```sql
SELECT pgreact.deploy(
    declaration  => ...,
    preconditions => pgreact.preconditions(
        expected_current_version => '...',
        allow_create             => true
    )
);
```

The exact representation may differ.

The behavior MUST reject stale assumptions rather than overwrite a concurrently changed policy.

### 12.2 Canonical export

M31 MUST provide a read-only way to export a deployed ordinary object as its canonical declaration.

The export MUST be:

- deterministic;
- free of environment-specific internal UUIDs where possible;
- schema-qualified;
- versioned;
- suitable for diffing;
- suitable for storing in Git;
- suitable for deployment into another compatible environment after explicit validation.

### 12.3 No hidden promotion workflow

M31 does not create a CI/CD service or policy-promotion engine.

PostgreSQL migrations, ordinary deployment tools, and canonical declarations remain sufficient.

---

## 13. Documentation redesign

M31 MUST replace milestone-first documentation with task-first documentation.

The ordinary documentation hierarchy SHOULD become:

```text
Getting started
  Install pg-react
  Create your first rule
  Understand rule lifecycle

Authoring
  Rules
  Actions
  Policy scope
  Decisions
  Effective dates and parameters

Operating
  Run pg-react
  Inspect rules and matches
  Handle failed work
  Replace and remove rules
  Backup and restore
  Upgrade

Understanding behavior
  Preview
  Explain
  Diagnostics
  Delivery guarantees

Advanced
  Derivations
  Recursion
  Negation
  Aggregation
  Temporal behavior
  Event time
  Provenance
  Recovery and reconciliation

Reference
  SQL API
  Public views
  Finding codes
  Compatibility matrix
  Limits
```

Milestone documents remain in a historical or contributor section.

A new user MUST NOT need to understand M8, M13, M22, M29, or M30 to use the associated capability.

---

## 14. First-rule experience

The README MUST present one canonical rule workflow.

The complete workflow MUST contain:

1. application table;
2. condition view;
3. typed PostgreSQL action;
4. one typed `pgreact.rule(...)` declaration;
5. `preview`;
6. `deploy`;
7. `run`;
8. `matches`;
9. `work`;
10. `explain`.

It MUST execute verbatim in CI.

The first example MUST NOT introduce:

- JSON declaration construction;
- policy sets;
- decisions;
- derivations;
- retries;
- frontiers;
- UUIDs;
- worker protocols;
- advanced tuning.

Those belong in later guides.

---

## 15. Progressive disclosure

M31 documentation MUST teach concepts in this order:

```text
SQL condition
→ rule
→ action
→ current match
→ lifecycle
→ durable work
→ policy scope
→ decisions
→ advanced reasoning
→ operational internals
```

Engine vocabulary such as:

```text
activation
generation
revision
episode
support
frontier
component
stratum
lease
fingerprint
```

MAY appear in detailed explanation, operations, and advanced reference.

It MUST NOT dominate initial authoring examples.

---

## 16. M31 API cleanup

M31 MUST classify every public function, type, and view as:

- **ordinary**
- **advanced**
- **compatibility**
- **administrative**
- **internal**

No public object may remain unclassified.

### Ordinary

Taught by default and intended for stable v1 usage.

### Advanced

Supported and documented but assumes deeper engine knowledge.

### Compatibility

Preserved because an earlier release exposed it.

New documentation does not teach it.

### Administrative

Installation, role setup, repair, recovery, or privileged lifecycle control.

### Internal

Not directly granted or documented as supported user API.

---

## 17. What M31 should remove from ordinary usage

M31 MUST stop teaching the following as normal usage:

- hand-written JSON declarations;
- UUID-first target selection;
- milestone-specific authoring functions;
- feature-specific `run_*` coordinator functions;
- direct private-catalog queries;
- metadata-only targets;
- target-specific placeholder explanations;
- duplicate ways to perform the same ordinary operation;
- direct use of internal terms where a PostgreSQL-level term is sufficient.

These surfaces MAY remain as compatibility or advanced APIs where required.

M31 SHOULD NOT remove a released compatibility API merely because its name is unattractive.

The goal is one canonical path, not gratuitous breakage.

---

## 18. M31 executable usability fixtures

M31 MUST introduce task-oriented SQL fixtures in addition to semantic regression tests.

### Fixture A: first constraint rule

A PostgreSQL developer can:

- create a condition view;
- create a rule;
- preview;
- deploy;
- run;
- query matches.

### Fixture B: command rule

The developer adds a typed action and verifies durable work.

### Fixture C: lifecycle

A matching row enters, changes, leaves, and re-enters.

The user can identify every transition using ordinary inspection only.

### Fixture D: scoped rule

A rule is matched by `order_id` and scoped by `customer_id`.

One customer is admitted and one excluded.

`explain` makes the difference obvious.

### Fixture E: decision

A decision program is deployed from a PostgreSQL candidate relation.

The user can inspect winner, no-candidate, ambiguity, and out-of-scope states without specialized milestone functions.

### Fixture F: failed action

An action fails.

The user can find the failure, understand the retry state, identify the attempt history, repair the cause, and use the documented recovery operation without accessing a private table.

### Fixture G: safe replacement

A rule definition changes.

Preview identifies create versus replacement.

A stale precondition is rejected.

A fresh deployment succeeds.

### Fixture H: export

A deployed rule is exported to canonical declaration form, validated in a clean compatible database, and produces the same normalized digest after environment-qualified identities are resolved.

---

## 19. M31 human usability gate

Before M31 is considered complete, at least **five PostgreSQL developers who did not implement the tested API** MUST attempt the first-rule workflow without maintainer intervention.

Required measurement:

- median time from opening the guide to first effective match: **15 minutes or less**;
- at least **4 of 5** complete the task without undocumented help;
- no participant requires a private catalog query;
- no participant must manually discover an internal UUID;
- every repeated point of confusion is recorded.

Any issue encountered by at least **2 of 5** participants MUST be:

- fixed before M31 release; or
- documented as an explicit M32 release blocker with a concrete resolution.

The test is about API comprehensibility, not participant speed.

---

## 20. M31 required artifacts

M31 is incomplete without:

1. `docs/m31-contract.md`
2. `docs/m31-api-reference.md`
3. `docs/m31-migration.md`
4. `docs/m31-usability.md`
5. `docs/m31-evidence.md`
6. `docs/m31-readiness.md`
7. machine-readable complete API classification
8. stable finding-code inventory
9. typed constructor SQL
10. compatibility wrapper SQL
11. `tests/m31.sql`
12. `tests/m31.sh`
13. task-oriented documentation tests
14. populated direct-upgrade fixture
15. canonical export/import fixture
16. rewritten README ordinary workflow
17. rewritten task-first documentation index

---

## 21. M31 exit gates

M31 may publish as `0.28.0` only when:

### 21.1 Typed-authoring gate

Every ordinary deployable kind has a typed PostgreSQL constructor.

### 21.2 JSON-independence gate

The complete ordinary authoring workflow requires no hand-written JSON.

### 21.3 Names-first gate

No ordinary workflow requires an internal UUID.

### 21.4 Inspection gate

Ordinary relational views plus `status`, `explain`, and `doctor` answer all reference operational questions without private catalogs.

### 21.5 Error gate

Every reference invalid declaration returns an actionable stable finding.

### 21.6 Schema gate

The canonical v1 PostgreSQL schema strategy is implemented and compatibility behavior is explicit.

### 21.7 Coordinator gate

Only global `run()` is taught as the ordinary coordinator operation.

### 21.8 Export gate

Every ordinary deployed object can be rendered as a deterministic canonical declaration.

### 21.9 Documentation gate

Every ordinary documentation example executes in CI.

### 21.10 Usability gate

The five-person usability fixture meets the frozen completion thresholds.

### 21.11 Continuous-qualification gate

Fresh installation, populated upgrade from `0.26.0`, rollback-by-restore and recovery, role isolation, packaged-artifact execution, and the frozen benchmark profiles remain green against the M31 candidate.

### 21.12 Regression gate

Every M0 through M30 semantic, security, recovery, and concurrency gate passes unchanged.

---

# Part II: M32

# M32: V1 Hardening, Compatibility Freeze, and Release Qualification

> **Proposed extension:** `0.29.0`<br>
> **Predecessor:** M31 / `0.28.0`<br>
> **Direct upgrade:** `0.28.0 -> 0.29.0`<br>
> **Primary outcome:** freeze the supported product contract and prove that it can safely become `1.0.0`<br>
> **Feature policy:** feature freeze<br>
> **Successor:** at least one `1.0.0-rc.N`, then `1.0.0`

---

## 22. M32 objective

M32 does not make pg-react broader.

M32 proves that the M30 semantics and M31 interface are reliable enough for users to depend on for years.

M32 MUST NOT begin until the continuous qualification lane has green evidence from M30 and M31 for fresh installation, populated direct upgrade from `0.26.0`, rollback-by-restore and recovery, role isolation, packaged artifacts, and the frozen performance profiles. M32 reruns and consolidates that evidence against `0.29.0` and the numbered `1.0.0` release candidate; it does not defer first execution of any matrix until final qualification.

M32 MUST freeze:

- supported ordinary SQL API;
- ordinary public views;
- ordinary type identities;
- canonical declarations;
- finding codes;
- lifecycle semantics;
- policy-scope semantics;
- work semantics;
- external delivery guarantees;
- supported compatibility matrix;
- extension upgrade policy;
- backup and recovery model;
- resource limits;
- deprecation policy;
- security boundary;
- documentation contract.

After the M32 freeze, the burden of proof reverses.

Before the freeze, an API may justify why it should remain.

After the freeze, any incompatible change must justify why a major release is necessary.

---

## 23. M32 feature-freeze rule

Once the M32 contract is merged:

> **No new product capability enters the v1 release line.**

Permitted work:

- correctness fixes;
- concurrency fixes;
- recovery fixes;
- security fixes;
- diagnostics;
- documentation;
- performance improvements that preserve semantics;
- packaging;
- installation;
- upgrade fixes;
- compatibility fixes;
- error-message improvements;
- usability fixes that do not introduce new concepts.

Not permitted:

- new rule kinds;
- new reasoning semantics;
- new temporal operators;
- new decision-selection semantics;
- new policy-set semantics;
- simulation;
- deployment-impact comparison;
- replay;
- backtesting;
- new delivery guarantees;
- new ordinary verbs;
- a new DSL;
- client SDKs;
- visual authoring;
- workflow orchestration.

A correctness fix requiring a public contract change MUST restart the affected M32 compatibility and RC evidence.

---

## 24. V1 compatibility contract

M32 MUST publish one normative `v1-contract.md`.

### 24.1 Frozen ordinary surface

The contract MUST enumerate exact:

- ordinary function identities;
- argument types;
- required argument names where named usage is contractual;
- public types;
- ordinary views;
- required view columns and meanings;
- canonical declaration fields;
- result-envelope top-level fields;
- stable finding codes;
- lifecycle states;
- work states;
- decision states;
- scope states;
- documented default behavior.

### 24.2 Compatibility promise

For all `1.x` releases:

- existing valid v1 ordinary calls MUST continue to work;
- existing public view columns MUST not disappear or change meaning;
- new nullable columns MAY be added;
- new optional function overloads MAY be added where resolution cannot break existing calls;
- new result detail fields MAY be added;
- existing stable finding codes MUST retain their meaning;
- new finding codes MAY be added;
- canonical declarations valid under an earlier `1.x` release MUST either remain valid or receive an explicit versioned migration path;
- durable state MUST never require users to edit private catalogs.

### 24.3 Semantic compatibility

A minor or patch release MUST NOT silently change:

- what constitutes one semantic match;
- when generations begin or end;
- when revisions are created;
- how policy eligibility gates truth;
- how decision winners are selected;
- when work becomes eligible;
- retry and lease safety;
- revalidation before execution;
- transactional local-action behavior;
- external at-least-once guarantees;
- support and retraction semantics;
- effective-date interval interpretation;
- monotone database-time behavior;
- event-time correction/finalization semantics.

A deliberate incompatible change requires a future major release.

### 24.4 Advanced API policy

M32 MUST confirm the kind dispositions frozen in M30 and identify which advanced surfaces receive:

- the full v1 compatibility promise;
- semantic stability but provisional presentation;
- compatibility-only preservation;
- eventual deprecation.

No public API may be left with ambiguous support status, and no kind rejected by the M30 matrix may become accepted during M32.

---

## 25. Semantic versioning policy

Beginning with `1.0.0`:

### Patch release: `1.0.x`

May contain:

- bug fixes;
- security fixes;
- documentation fixes;
- packaging fixes;
- performance improvements preserving observable behavior.

### Minor release: `1.x.0`

May contain backward-compatible:

- new optional functionality;
- new object kinds;
- new advanced features;
- new views or columns;
- new finding codes;
- new declaration versions;
- post-v1 simulation or replay capabilities.

### Major release: `2.0.0`

Required for intentionally incompatible ordinary API or semantic changes.

An emergency correctness or security issue MAY force incompatible behavior, but the release notes MUST identify the violated previous behavior and exact migration impact.

---

## 26. Legacy “v1” documentation cleanup

The repository currently contains historical material describing the earlier `0.1.1` generation as “v1” and M4 as “v1 GA,” while current development has progressed through the later pre-`1.0.0` milestone sequence.

M32 MUST eliminate ambiguity without rewriting history.

Historical documents SHOULD be moved or relabeled under a namespace such as:

```text
docs/legacy/0.1.1/
```

or clearly headed:

```text
Historical v0.1.1 GA contract
Not the pg-react 1.0.0 contract
```

References to “v1” without a version number MUST refer to the new semantic-versioned `1.0.0` contract after M32.

Historical release evidence remains immutable and linked.

---

## 27. Upgrade contract

### 27.1 Direct upgrade from M29

Every numbered release candidate and the final `1.0.0` release MUST provide and test direct supported paths:

```text
0.26.0 -> 1.0.0-rc.N
0.26.0 -> 1.0.0
```

This matters because M29 is the last release before the proposed v1 convergence program.

The direct path MUST perform the same logical transformations as the staged path:

```text
0.26.0
→ 0.27.0
→ 0.28.0
→ 0.29.0
→ 1.0.0-rc.N
→ 1.0.0
```

### 27.2 Adjacent upgrades

M32 MUST also test:

```text
0.27.0 -> 0.28.0
0.28.0 -> 0.29.0
0.29.0 -> 1.0.0-rc.N
qualified 1.0.0-rc.N -> 1.0.0
```

### 27.3 Populated upgrade evidence

Upgrade fixtures MUST contain:

- global rules;
- scoped rules;
- active and inactive matches;
- several activation generations;
- change revisions;
- policy-set supports;
- a current decision winner;
- an ambiguous decision;
- derived facts with multiple supports;
- temporal state;
- effective-dated policy;
- parameter rows;
- pending work;
- retry-wait work;
- failed work;
- completed work;
- withdrawn work;
- skipped work;
- attempts;
- outbox rows;
- drift evidence;
- recovery metadata;
- compatibility declarations.

Upgrade MUST preserve all state whose semantics remain valid.

### 27.4 Upgrade must not execute business work

`ALTER EXTENSION ... UPDATE` MUST NOT:

- invoke user actions;
- create external outbox effects;
- silently activate policy-set gating;
- create false lifecycle transitions;
- treat rebuilds as business changes.

When an upgrade requires reconciliation, it MUST establish an explicit barrier and require the documented reconciliation operation.

---

## 28. Installation and compatibility matrix

Starting with the frozen M30 kind dispositions and the environment evidence accumulated through M30 and M31, M32 MUST publish one exact tested matrix.

It MUST identify:

- PostgreSQL major and minimum minor version;
- pg_trickle version;
- pgrx/Rust artifact provenance where relevant;
- operating system;
- CPU architecture;
- extension packaging method;
- container support;
- physical replication support;
- logical dump/restore support;
- RLS support or explicit non-support;
- supported isolation level;
- required preload settings;
- worker/runtime requirements.

A combination not present in the matrix MUST be described as unsupported or experimental.

`doctor()` MUST detect every compatibility property that PostgreSQL allows it to determine and report a blocking finding for an unsupported tuple.

M32 MUST prefer a narrow truthful matrix over an untested broad claim.

---

## 29. Packaging and release artifacts

The final v1 release MUST publish:

- source archive;
- extension SQL;
- compiled extension artifact for each supported binary target;
- OCI image where container installation is supported;
- SHA-256 checksums;
- SBOM;
- provenance/attestation information;
- exact dependency versions;
- release notes;
- direct upgrade scripts;
- installation guide;
- backup/restore guide;
- security guide;
- troubleshooting guide;
- compatibility matrix;
- known limits.

The published artifact, not a developer checkout, MUST execute the complete qualification suite.

---

## 30. Backup, restore, and disaster recovery

M32 MUST prove the documented recovery model.

Required scenarios:

### 30.1 PostgreSQL restart

An unclean restart preserves or safely recovers:

- authoritative rule state;
- activation state;
- policy scope;
- agenda state;
- attempts;
- leases;
- derived support;
- decision state;
- frontiers;
- barriers.

### 30.2 Physical backup and restore

A restored database MUST either:

- resume in an authoritative consistent state; or
- enter an explicit reconciliation barrier before new work can execute.

### 30.3 Logical dump and restore

All supported public configuration and durable semantic state MUST have a documented logical-restoration policy.

Where exact OIDs or physical identities cannot survive logical restore, the system MUST rebuild them through a documented safe operation.

### 30.4 Point-in-time recovery

PITR behavior MUST document the relationship among:

- database state;
- completed local consequences;
- transactional outbox rows;
- external effects already delivered before recovery.

No exactly-once external-effect claim may be introduced.

### 30.5 Standby promotion

A supported standby promotion MUST prove that stale leases, worker ownership, frontiers, and reconciliation state cannot cause duplicate successful ownership of work.

---

## 31. Security qualification

M32 MUST perform a complete public-surface security review.

### Required checks

- `PUBLIC` has no unintended execution privileges.
- Private schemas are inaccessible to ordinary roles.
- Every `SECURITY DEFINER` routine has a safe fixed `search_path`.
- Exact function identities prevent search-path hijacking.
- Ownership checks cannot be bypassed through façade wrappers.
- Reader roles cannot mutate state.
- Author roles cannot claim worker authority.
- Worker roles cannot deploy arbitrary rules.
- Operator roles receive only documented operational authority.
- Explanation does not leak protected subject evidence.
- Error details do not leak unauthorized object contents.
- Unsupported RLS fails explicitly.
- Declaration input cannot inject arbitrary SQL execution.
- Schema-qualified identities are used where authority matters.

A security blocker prevents `1.0.0`.

---

## 32. Performance qualification

M32 MUST establish reproducible v1 performance baselines.

### 32.1 Benchmark profiles

M31 MUST freeze at least three representative benchmark profiles before M32 qualification begins:

1. **Small operational database**
2. **Moderate rule workload**
3. **Published supported-boundary workload**

Each profile MUST record:

- PostgreSQL configuration;
- hardware;
- data volume;
- rule count;
- match count;
- policy-set member count;
- eligible-subject count;
- derivation count where applicable;
- pending-work volume;
- change rate;
- coordinator cadence.

### 32.2 Metrics

Measure at minimum:

- coordinator run latency;
- incremental change latency;
- activation throughput;
- work-claim latency;
- database-action throughput;
- policy eligibility update latency;
- decision evaluation latency;
- `status` latency;
- `explain` latency;
- storage growth;
- memory usage;
- WAL volume where relevant;
- recovery duration.

### 32.3 Regression budget

Against the frozen M31 baseline, M32 MUST investigate:

- median regression greater than **10%**;
- p95 regression greater than **20%**;
- unbounded storage, memory, or latency growth;
- a change from incremental behavior to full recomputation in a previously incremental path.

A regression above those thresholds may be accepted only if:

- the cause is understood;
- correctness or safety requires it;
- the impact is published;
- the release-readiness record explicitly approves it.

M32 does not promise a universal transactions-per-second figure.

It promises measured behavior for a published workload and environment.

---

## 33. Resource-limit qualification

Every bounded subsystem MUST have a documented limit or failure policy.

The v1 reference MUST include at minimum:

- match-key component limit;
- subject-key component limit;
- supported key types;
- policy-set member limit;
- eligibility population limit;
- proof/evidence page limits;
- derivation bounds;
- recursion bounds;
- aggregation bounds;
- decision-analysis bounds;
- temporal resource bounds;
- claim batch bounds;
- retry limits;
- worker concurrency bounds;
- retention constraints;
- diagnostic evidence limits.

Crossing a supported limit MUST:

- fail before unsafe partial mutation where possible;
- identify the exact limit;
- explain how to reduce or reconfigure the workload.

---

## 34. Observability qualification

A production v1 installation MUST expose enough state for an operator to answer:

- Is pg-react healthy?
- When did the coordinator last complete?
- Which targets are blocked?
- Why are they blocked?
- How much work is pending?
- How much work is retrying?
- Which actions are failing?
- Are failures increasing?
- Are leases stuck?
- Is a recovery barrier active?
- Is a source or function drifted?
- Are policy sets current?
- Is a deployment migration required?
- Is retention operating?
- Is the installed version supported?

All of these questions MUST be answerable through documented public SQL.

Private catalog access is not an observability strategy.

---

## 35. Operational runbooks

M32 MUST provide executable runbooks for:

1. installation;
2. initial role configuration;
3. first production deployment;
4. rule replacement;
5. policy-set replacement;
6. paused or blocked rule;
7. action failure;
8. retry exhaustion;
9. source drift;
10. action drift;
11. applicability drift;
12. database restart;
13. failed upgrade;
14. backup and restore;
15. standby promotion;
16. reconciliation;
17. retention;
18. extension removal where supported.

Each runbook MUST distinguish:

```text
observe
→ diagnose
→ repair prerequisite
→ invoke explicit pg-react operation
→ verify
```

No runbook may instruct a normal operator to manually modify a private pg-react table.

---

## 36. Documentation correctness gate

M32 MUST treat documentation as executable product surface.

Every SQL example in:

- README;
- getting-started guide;
- rule guide;
- policy-set guide;
- decision guide;
- operations guide;
- troubleshooting guide;
- upgrade guide;
- backup/restore guide;

MUST run in CI against the exact packaged candidate.

Examples that intentionally fail MUST assert their exact stable finding code.

Documentation and implementation divergence is a release blocker.

---

## 37. Independent v1 usability qualification

M32 MUST repeat usability testing against the packaged `0.29.0` candidate, and the evidence MUST remain valid or be rerun for every numbered `1.0.0` release candidate.

At least **five PostgreSQL developers who did not implement pg-react** must complete the first-rule task.

Required thresholds:

- at least **4 of 5** complete without undocumented assistance;
- median first effective rule: **15 minutes or less**;
- every participant can locate the rule in `status`;
- every participant can explain why one selected subject did or did not produce work;
- no participant requires private-catalog access;
- no participant requires an internal UUID.

At least **three** of those users must additionally complete one operational task selected from:

- replace a rule safely;
- identify and recover failed work;
- scope a rule through a policy set;
- diagnose source or action drift.

At least **2 of 3** must complete the operational task using only published documentation.

A repeated misunderstanding that could cause incorrect production behavior is a release blocker even when the raw completion threshold passes.

---

## 38. Pilot qualification

Before `1.0.0`, pg-react MUST complete at least **two controlled pilot deployments** distinct from the maintainer's ordinary development database.

Together the pilots MUST exercise:

- real application tables;
- at least one command rule;
- rule replacement;
- action failure or injected failure;
- retry or recovery;
- backup and restore;
- extension upgrade;
- restart;
- `doctor`;
- ordinary monitoring.

At least one pilot MUST additionally exercise:

- policy-set scoping; or
- decisions.

At least one pilot MUST be operated substantially by someone who did not implement the relevant subsystem.

No pilot may depend on undocumented private-catalog repair.

Pilot findings that reveal data loss, duplicate successful work ownership, silent incorrect gating, unrecoverable drift, or an unsafe upgrade block `1.0.0`.

---

## 39. Release-severity policy

M32 MUST classify unresolved defects.

### P0: release blocker

Examples:

- data loss;
- security boundary bypass;
- duplicate authoritative ownership;
- action executes when fresh eligibility should reject it;
- upgrade corrupts durable state;
- restore cannot recover documented state;
- incorrect decision or policy truth.

No P0 may remain open.

### P1: release blocker

Examples:

- ordinary API performs a different operation from its documentation;
- common workflow requires private-catalog intervention;
- supported installation fails reproducibly;
- serious unexplained performance cliff;
- ordinary diagnostics give materially incorrect remediation;
- documented compatibility path is broken.

No known P1 may remain open.

### P2: normally fix before release

Examples:

- confusing but correct error;
- non-critical documentation gap;
- awkward advanced workflow;
- cosmetic inspection inconsistency.

A P2 may remain only when explicitly recorded in known limitations with a concrete post-v1 disposition.

---

## 40. Deprecation freeze

M32 MUST publish the complete list of pre-v1 surfaces that are:

- canonical in v1;
- supported advanced;
- compatibility-only;
- deprecated;
- internal.

A deprecated function MUST provide, where practical:

- a warning or discoverable classification;
- the replacement operation;
- migration documentation;
- the earliest release in which removal could occur.

No compatibility surface is removed in `1.0.0` merely to make the API inventory smaller.

The v1 release should be coherent without forcing unnecessary pre-v1 breakage.

---

## 41. M32 required artifacts

M32 is incomplete without:

1. `docs/v1-contract.md`
2. `docs/v1-compatibility.md`
3. `docs/v1-support-matrix.md`
4. `docs/v1-limits.md`
5. `docs/v1-security.md`
6. `docs/v1-upgrade.md`
7. `docs/v1-backup-restore.md`
8. `docs/v1-operations.md`
9. `docs/v1-troubleshooting.md`
10. `docs/v1-deprecations.md`
11. `docs/m32-evidence.md`
12. `docs/m32-readiness.md`
13. `docs/m32-pilot.md`
14. complete machine-readable v1 API inventory
15. stable finding-code registry
16. compatibility test suite
17. performance benchmark definitions and results
18. packaged-artifact qualification suite
19. populated `0.26.0 -> 1.0.0-rc.N` and final GA upgrade fixture
20. physical recovery fixture
21. logical restore fixture
22. standby promotion fixture where supported
23. security regression suite
24. documentation execution suite
25. final SBOM and provenance pipeline
26. final release checklist
27. qualification record for every published `1.0.0-rc.N` artifact

---

## 42. M32 exit gates

M32 may publish as `0.29.0` only when:

### 42.1 Feature-freeze gate

No unapproved semantic or ordinary API expansion remains.

### 42.2 Compatibility gate

The complete v1 ordinary API and compatibility policy are frozen.

### 42.3 Upgrade gate

All adjacent upgrades and the direct `0.26.0 -> 1.0.0-rc.N` and final GA rehearsals preserve the required populated state.

### 42.4 Recovery gate

Restart, physical restore, logical restoration policy, and supported failover behavior pass exact evidence.

### 42.5 Security gate

The complete public-surface security review has no unresolved blocker.

### 42.6 Performance gate

Published benchmark profiles pass or explicitly document every approved regression.

### 42.7 Resource gate

Every bounded subsystem has a published support limit and safe failure behavior.

### 42.8 Documentation gate

Every ordinary example executes against the packaged candidate.

### 42.9 Usability gate

Independent usability qualification meets the frozen thresholds.

### 42.10 Pilot gate

Two controlled pilots complete without unresolved P0 or P1 findings.

### 42.11 Operations gate

Every supported failure mode has a public diagnosis and recovery path.

### 42.12 Regression gate

Every M0 through M31 correctness, concurrency, security, recovery, execution, and compatibility gate passes against the exact M32 artifact.

### 42.13 Release-candidate readiness gate

The exact `0.29.0` artifact has enough green evidence to produce `1.0.0-rc.1`; it is not eligible for direct promotion to `1.0.0`.

---

# Part III: Final `1.0.0` Release-Candidate and GA Qualification

## 43. Relationship between M32 and `1.0.0`

`0.29.0` is the M32 qualification baseline, not the GA candidate.

The transition:

```text
0.29.0 -> 1.0.0-rc.1 -> ... -> 1.0.0
```

MUST include at least one numbered release-candidate cycle and MUST NOT introduce a new product capability.

Each exact `1.0.0-rc.N` packaged artifact MUST pass the complete applicable M32 suite, including fresh installation and a populated upgrade from `0.26.0`. Any change to extension code, SQL, packaging, compatibility behavior, or normative documentation requires a new numbered candidate and reruns the affected M32 evidence.

Permitted candidate changes are limited to:

- fixes required by qualification;
- packaging;
- version metadata;
- documentation;
- security corrections;
- compatibility corrections.

Any change that alters rule, policy, decision, reasoning, lifecycle, or execution semantics MUST rerun the complete affected M32 qualification and be explicitly recorded.

`1.0.0` may be published only by promoting a fully qualified candidate with no change other than final version metadata and mechanically corresponding checksums and provenance.

---

## 44. Final `1.0.0` release gates

The project may tag `1.0.0` only when all of the following are true.

### 44.1 M30 complete

Runtime truth is authoritative.

Policy-set gating actually controls effective truth and execution.

No ordinary façade operation is metadata-only or placeholder-backed.

### 44.2 M31 complete

The canonical PostgreSQL-native interface is implemented.

Typed authoring, names-first operation, relational inspection, actionable diagnostics, and task-first documentation are complete.

### 44.3 M32 complete

Compatibility, upgrade, security, recovery, performance, usability, packaging, and pilot evidence pass.

### 44.4 Zero unresolved P0/P1 defects

There are no known release-blocking correctness, security, compatibility, operational, or usability failures.

### 44.5 Exact release artifact passes

At least one exact numbered `1.0.0-rc.N` source archive, binary set, and container passes the complete qualification suite, including fresh installation and populated upgrade from `0.26.0`. The exact GA artifacts MUST differ only by the permitted final version metadata, checksums, and provenance.

A passing developer-tree test is insufficient.

### 44.6 Documentation matches artifact

Every documented ordinary example passes against the exact final artifact.

### 44.7 Direct upgrade passes

A populated `0.26.0` database reaches the exact final `1.0.0` artifact through the supported direct path.

### 44.8 Recovery passes after upgrade

The upgraded database survives the documented restart and recovery qualification.

### 44.9 Public API checksum freezes

The final ordinary function, type, view, finding-code, and declaration inventory is generated from the release artifact and committed as the v1 compatibility baseline.

### 44.10 Release statement is explicit

The release notes state exactly:

- what v1 guarantees;
- what remains advanced;
- what remains compatibility-only;
- what is unsupported;
- what external delivery guarantees do and do not mean;
- what PostgreSQL and pg_trickle versions are supported;
- what limits are enforced.

---

# Part IV: Work explicitly deferred until after v1

## 45. Post-v1 semantic roadmap

The following work moves after `1.0.0`:

### Deployment-impact simulation

Compare a proposed policy version with the deployed version over current facts and report exact would-be differences.

### Hypothetical fact simulation

Evaluate typed hypothetical inserts, updates, and deletes without changing production state.

### Historical replay

Evaluate a frozen policy over supplied historical inputs and explicit time/frontier progression.

### Comparative backtesting

Compare two policy versions over the same historical input.

### Why-changed comparison

Explain causal differences between versions, frontiers, or revisions.

These capabilities correspond closely to the simulation and replay sequence currently proposed after M29.

They become safer and easier to design after v1 because they can target one frozen production model instead of influencing that model while it is still converging.

---

## 46. Other explicit post-v1 non-goals

The v1 program also does not require:

- a custom rule DSL;
- visual rule editing;
- AI rule authoring;
- client-language SDKs;
- policy-as-code hosting;
- cloud control plane;
- nested policy sets;
- hierarchical policy inheritance;
- weighted decision scoring;
- optimization solvers;
- synchronous network actions;
- long-running human workflows;
- exactly-once external delivery;
- arbitrary SQL lineage;
- untrusted dynamic code execution;
- unstratified negation;
- recursive aggregation unless separately proven;
- distributed rule evaluation across databases.

None of these should block `1.0.0`.

---

# Part V: Implementation order

## 47. Recommended sequence

### M30: `0.27.0`

**Theme:** make runtime behavior truthful.

Primary work:

- authoritative policy-set gating;
- match versus subject identity;
- scope supports;
- work revalidation;
- relational eligibility;
- truthful façade delegation;
- authoritative removal;
- safe M29 migration.

### M31: `0.28.0`

**Theme:** make the truthful product easy.

Primary work:

- typed constructors;
- canonical schema;
- names-first workflow;
- final ordinary verbs;
- relational inspection;
- actionable diagnostics;
- canonical export;
- task-first documentation;
- usability testing.

### M32: `0.29.0`

**Theme:** prove the easy product is stable.

Primary work:

- feature freeze;
- v1 compatibility contract;
- direct upgrade;
- recovery qualification;
- security qualification;
- performance baselines;
- packaging;
- documentation execution;
- pilots;
- release evidence.

### `1.0.0-rc.N`

**Theme:** qualify the exact packaged v1 artifact.

At least one numbered candidate is required. Fresh installation, populated upgrade from `0.26.0`, recovery, security, role isolation, documentation, usability, pilots, and performance evidence MUST apply to the exact candidate. Any material fix produces another candidate.

### `1.0.0`

**Theme:** freeze and publish.

No new semantics.

No new ordinary concepts.

No new ordinary verbs.

No change from the qualified candidate except final version metadata and mechanically corresponding checksums and provenance.

---

# Part VI: Definition of v1 success

## 48. Author success criterion

A PostgreSQL developer can define a useful rule using concepts they already understand:

```text
table
→ view
→ typed function
→ rule
```

They can then use:

```text
preview
→ deploy
→ run
→ inspect
→ explain
```

without learning pg-react internals first.

---

## 49. Operator success criterion

An operator can determine:

```text
what is active
what is pending
what failed
why it failed
whether execution is safe
what action is required
```

through documented public SQL.

They never need to repair normal production state by editing internal tables.

---

## 50. Correctness success criterion

For every supported ordinary capability:

> **The state visible through PostgreSQL inspection, the state used to decide lifecycle transitions, and the state used immediately before executing work are the same authoritative truth at the documented frontier.**

---

## 51. Compatibility success criterion

A user who adopts the documented `1.0.0` ordinary API can reasonably expect a later `1.x` upgrade to preserve:

- their declarations;
- their SQL calls;
- their operational queries;
- their rule identities;
- their durable lifecycle history;
- their pending work;
- their documented semantics.

---

## 52. Product success criterion

The final v1 product should be describable without qualification as:

> **A PostgreSQL-native rule engine where SQL defines truth, typed PostgreSQL objects define behavior, pg-react durably remembers what changed, and every important decision and piece of work remains inspectable through PostgreSQL.**

That is the product boundary M30, M31, and M32 should optimize for.

---

# Part VII: Approval decision

## 53. Approval of this proposal authorizes

1. replacing the current M31 deployment-impact simulation milestone with **M31 PostgreSQL-Native Ergonomics**;
2. replacing the current M32 historical-replay milestone with **M32 V1 Hardening, Compatibility Freeze, and Release Qualification**;
3. moving simulation, replay, backtesting, and why-changed work after `1.0.0`;
4. targeting the sequence:

```text
M29 / 0.26.0
→ M30 / 0.27.0
→ M31 / 0.28.0
→ M32 / 0.29.0
→ 1.0.0-rc.1 / later RCs as required
→ 1.0.0
```

5. treating M30, M31, and M32 together as the formal pg-react v1 program;
6. prohibiting additional semantic scope once M32 begins.

---

## 54. First M31 implementation change

The first M31 implementation change SHOULD NOT be another convenience function.

It MUST be one executable golden-path fixture showing the desired final PostgreSQL experience:

```sql
CREATE VIEW ...;

CREATE FUNCTION ...;

SELECT pgreact.preview(
    pgreact.rule(...)
);

SELECT pgreact.deploy(
    pgreact.rule(...)
);

SELECT pgreact.run();

SELECT * FROM pgreact.matches ...;

SELECT pgreact.explain(...);
```

The expected transcript MUST be reviewed before implementing the convenience layer.

If that transcript is not significantly clearer than the current workflow, M31 has not yet found the correct v1 interface.

---

## 55. First M32 implementation change

The first M32 change MUST generate the proposed v1 public API inventory directly from the installed `0.28.0` extension.

Every function, overload, type, view, grant, finding code, declaration field, and compatibility alias must be classified.

The M32 freeze begins from observed installed reality, not from documentation assumptions.

---

## 56. Final approval criterion

This proposal should be accepted only if maintainers agree on one priority:

> **pg-react does not need more power before v1. It needs to make its existing power trustworthy, PostgreSQL-native, understandable, upgradeable, and boring to operate.**

M30 establishes trustworthy behavior.

M31 establishes the interface people should learn.

M32 proves that interface and behavior are ready to become a long-term compatibility commitment.

The numbered release-candidate cycle then proves the exact packaged artifact before the project publishes `1.0.0`.

# M54 / pg-react 0.43.0 — Adoption Hardening Implementation Plan

> **Status:** Proposed implementation plan
> **Release target:** extension `0.43.0`
> **Milestone:** M54 — Adoption hardening
> **Predecessor:** M53 / extension `0.42.0`
> **Primary goal:** make the capabilities already present in pg-react feel like one coherent, current, PostgreSQL-native product
> **Feature posture:** no new rule-language, temporal, reasoning, workflow, or distributed-system semantics
> **Compatibility posture:** additive by default; existing valid `0.42.0` calls remain compatible when M54 additions are unused

---

## 1. Outcome

M54 turns `0.42.0` from a technically deep release into a coherent adoption baseline.

A PostgreSQL user should be able to:

1. Install the actual current pg-react release without encountering obsolete `1.0.0-rc.1` or historical baseline instructions.
2. Define a rule or decision using the ordinary declaration constructors.
3. Use every documented ordinary constructor argument through the ordinary deployment facade.
4. Create **or replace** a rule or decision through the same names-first workflow:

   ```text
   construct -> validate -> compare -> preview -> deploy -> inspect
   ```

5. Review a deployment and pass that review into deployment without manually constructing nested precondition JSON or knowing whether a particular operation calls its digest `preview_digest` or `plan_digest`.
6. Diagnose and perform common rule recovery procedures without first looking up private or UUID-oriented identifiers.
7. Follow deterministic tutorials that advance pg-react explicitly instead of depending on `pg_sleep`.
8. Read one current API reference whose classification agrees with the actual installed extension.
9. Treat the `0.x` line as intentionally usable and compatibility-conscious even though `1.0.0` remains postponed indefinitely.
10. Trust that a release cannot publish while the canonical qualification lane for that exact tagged commit is red.

M54 is successful when pg-react no longer requires historical milestone knowledge to use its ordinary product surface.

---

# 2. Why M54 now

`0.42.0` closes an important semantic/product boundary: a complete policy change can now be represented as one immutable package with validation, comparison, dependency ordering, preview, atomic deployment, export/import, inspection, explanation, and removal.

The project therefore has more capability than it needs for another immediate semantic expansion.

The adoption blockers visible after M53 are primarily coherence problems:

- current documentation disagrees about the current release and support boundary;
- several canonical documents remain organized around a postponed `v1`;
- the ordinary rule constructor exposes arguments that the ordinary declaration adapter does not fully support;
- ordinary create and ordinary replacement are not symmetric;
- replacement of standalone rules still falls through to compatibility procedures;
- decision replacement lacks the equivalent ordinary cutover story;
- deployment review requires callers to know JSON field names and construct precondition objects;
- some recovery procedures still require UUID lookup despite stable-name public state being available;
- tutorials wait for scheduler timing instead of deliberately advancing the runtime;
- the human API reference trails the actual installed public surface;
- CI and release qualification currently have separate success states;
- release evidence packaging can synthesize placeholder directories for inherited evidence rather than recording an exact evidence reference;
- `ROADMAP.md` carries too much completed milestone archaeology alongside current product strategy.

These are not cosmetic issues. They affect whether an independent PostgreSQL user can infer the supported product correctly.

M54 addresses them before M45, M58, M59, or another capability milestone.

---

# 3. Release boundary

M54 / `0.43.0` is an adoption-hardening release.

It MAY:

- complete an already-declared ordinary facade;
- qualify already-existing runtime behavior through the ordinary API;
- add ergonomic overloads over existing authoritative operations;
- add a small review-token abstraction over the existing preview digest contract;
- reorganize documentation without changing runtime semantics;
- strengthen CI, qualification, release, evidence, and compatibility contracts;
- improve names-first resolution of already-supported administrative operations;
- fix current-release documentation and API classification;
- simplify the roadmap and historical-document navigation.

It MUST NOT add:

- a new rule kind;
- a new decision semantic;
- a new temporal semantic;
- rolling/hopping windows;
- business calendars;
- event sequences;
- absence-after-event rules;
- new recursion, negation, or aggregation semantics;
- a policy DSL;
- nested policy sets;
- cross-database deployment;
- automatic policy promotion;
- approval routing;
- rollback orchestration;
- a workflow engine;
- synchronous network consequences;
- exactly-once external delivery;
- arbitrary SQL lineage;
- AI or visual policy authoring;
- a client SDK;
- a second evaluator;
- a second source of truth;
- a new scheduler.

M54 should make the existing product smaller to understand, not larger to describe.

---

# 4. Release decision record

The M53 release notes say that the next milestone should be selected from an adoption blocker rather than from a fixed feature queue.

M54 records the following decision:

> The first post-M53 adoption blockers are product coherence, ordinary replacement, current documentation, operator identity ergonomics, and release/qualification coherence. These are selected ahead of another semantic capability milestone.

M45, M58, and M59 remain candidates after M54.

M55 schema-change safety or M56 rebuild/reconciliation safety still takes priority immediately if implementation or field use reveals an unsafe condition.

---

# 5. Success criteria

M54 is complete only when all of the following are true.

## 5.1 Current-product documentation

1. `README.md`, Getting Started, Installation, Authoring, Operations, API Reference, Support Matrix, Known Limitations, Upgrade, and Troubleshooting all describe `0.43.0` as the current release.
2. Ordinary documentation no longer instructs users to install or expect `1.0.0-rc.1`.
3. Ordinary documentation no longer uses `v1` as the product's current maturity boundary.
4. Historical RC and milestone documents remain accessible through History.
5. One machine-readable current-release manifest is checked against the extension, container, docs, and release workflow.
6. CI fails if ordinary current docs drift from that manifest.

## 5.2 Ordinary authoring

7. Every non-deprecated argument exposed by `pgreact.rule()` is accepted and propagated correctly by the generic ordinary declaration path.
8. In particular, non-null `change_columns` and `conflict_key_columns` work through ordinary validation, preview, deployment, status, replacement, export, import, and semantic difference where the installed runtime already defines them.
9. Existing specialized APIs remain compatible.

## 5.3 Ordinary replacement

10. An active ordinary rule can be replaced successfully using `pgreact.deploy()`.
11. An active ordinary decision can be replaced successfully using `pgreact.deploy()`.
12. Replacement uses the same stable name as creation and requires no private identifier.
13. Preview says exactly what will happen before replacement.
14. Command-rule replacement never guesses how old executable work should be handled.
15. A stale reviewed plan fails instead of silently recalculating and deploying a different plan.
16. Any failure leaves the complete old deployment in place.

## 5.4 Review ergonomics

17. A user can convert a successful preview result into a reviewed deployment token without manually knowing digest field paths.
18. A reviewed deployment token works uniformly for rule, decision, and complete policy-set deployment.
19. The old JSON-preconditions deployment signature remains compatible.
20. A review token is not an authorization credential and cannot bypass current-state, ownership, or source checks.

## 5.5 Operations

21. Common rule recovery procedures documented for ordinary operators require no UUID lookup.
22. Stable-name overloads delegate to the existing authoritative recovery implementations rather than reimplementing recovery logic.
23. Missing, ambiguous, changed, and unauthorized targets fail with bounded, non-leaking results.

## 5.6 Tutorials

24. Canonical runnable tutorials do not depend on `pg_sleep` for pg-react progress.
25. When deterministic progress is desired, tutorials invoke one deliberate coordinated cycle and then inspect state.
26. Documentation still explains that the normal production runtime is asynchronous PostgreSQL-managed polling.

## 5.7 API coherence

27. One current machine-readable public API inventory exists.
28. Every current public function/view is classified as one of:

   - ordinary;
   - advanced;
   - administrative;
   - compatibility;
   - internal/not public.

29. The human API reference is checked against that inventory.
30. New application code can determine which surface to choose without knowing milestone numbers.

## 5.8 Release engineering

31. The exact `v0.43.0` commit has one authoritative qualification result.
32. Release publication depends on that qualification result.
33. A successful release cannot coexist with a failed canonical qualification for the same commit.
34. Evidence packaging never fabricates placeholder qualification evidence.
35. Inherited evidence is either rerun or referenced by exact immutable release/artifact digest.

---

# 6. Product invariants

M54 must preserve these project invariants.

## 6.1 PostgreSQL remains authoritative

Application rows, source relations, functions, parameter rows, and PostgreSQL permissions remain authoritative.

M54 does not introduce:

- configuration files as policy truth;
- worker-local deployment state;
- external policy registries;
- another metadata database.

## 6.2 Existing evaluators remain authoritative

M54 wrappers delegate to the currently installed:

- declaration normalization;
- validation;
- preview;
- replacement planner;
- lifecycle;
- decision;
- work;
- retry/recovery;
- comparison;
- explanation;
- package planner.

M54 must not create a second implementation of any of these semantics.

## 6.3 Review remains advisory, deployment remains authoritative

A preview or review token says:

> this is the exact plan that was reviewed.

It does not say:

> deploy this regardless of what has changed since review.

Deployment must still re-check the current authoritative state and reject stale plans.

## 6.4 Names are public identity

Ordinary and names-first administrative operations use public stable identity.

Private UUIDs may remain internal implementation keys, but the ordinary documented task must not require the user to retrieve one merely to call the next public function.

## 6.5 Old compatibility calls remain installed

M54 does not remove:

- legacy rule creation/replacement functions;
- UUID-oriented recovery functions;
- `pg-reactd`;
- advanced authoring APIs;
- `1.0.0-rc.1` extension artifacts retained for history/compatibility.

They are simply no longer presented as the ordinary current product path.

---

# 7. Workstream A — Current-release documentation reset

## 7.1 Goal

Remove the postponed `v1` release from the normal documentation mental model.

Current docs should describe the current release.

Historical docs should describe history.

The same document should not attempt both jobs.

---

## 7.2 Add `docs/current-release.json`

Add one machine-readable source for current release identity:

```json
{
  "schema_version": 1,
  "milestone": "M54",
  "extension_version": "0.43.0",
  "previous_extension_version": "0.42.0",
  "adjacent_upgrade": "0.42.0 -> 0.43.0",
  "postgresql": "18.3",
  "pg_trickle": "0.81.0",
  "pgrx": "0.18.0",
  "rust": "1.89.0",
  "os": "Linux",
  "arch": "amd64",
  "isolation": "READ COMMITTED",
  "runtime": "PostgreSQL-managed",
  "v1_status": "postponed_indefinitely"
}
```

Build-tool versions remain build facts unless separately qualified.

The manifest does not automatically imply support merely because a value occurs in it. `docs/support-matrix.md` remains the human support contract.

---

## 7.3 Canonical neutral document names

Introduce neutral current-product document names:

| Current canonical path | Replaces current-product use of |
|---|---|
| `docs/product-contract.md` | `docs/v1-contract.md` |
| `docs/installation.md` | `docs/v1-installation.md` |
| `docs/authoring.md` | `docs/v1-authoring.md` |
| `docs/operations.md` | `docs/v1-operations.md` |
| `docs/api-reference.md` | `docs/v1-api-reference.md` |
| `docs/security.md` | `docs/v1-security.md` |
| `docs/backup-restore.md` | `docs/v1-backup-restore.md` |
| `docs/upgrade.md` | `docs/v1-upgrade.md` |
| `docs/troubleshooting.md` | `docs/v1-troubleshooting.md` |
| `docs/support-matrix.md` | `docs/v1-support-matrix.md` |
| `docs/known-limitations.md` | `docs/v1-known-limitations.md` |
| `docs/limits.md` | `docs/v1-limits.md` |
| `docs/compatibility.md` | `docs/v1-compatibility.md` |
| `docs/deprecations.md` | `docs/v1-deprecations.md` |

Existing `v1-*` URLs should not become dead links.

Each old current-product path becomes either:

1. a small compatibility document pointing to the new canonical path; or
2. an explicitly historical document where the content truly describes the prepared v1 candidate.

Do not maintain two independent current versions of the same guide.

---

## 7.4 Ordinary docs must not expose milestone archaeology

The main documentation home should be task-oriented:

```text
Start
  Getting Started
  Tutorial
  Concepts

Build
  Authoring
  Changing Policies Safely
  Explain an Outcome
  API Reference

Operate
  Installation
  Operations
  Security
  Backup and Restore
  Upgrade
  Troubleshooting

Reference
  Product Contract
  Limits
  Support Matrix
  Known Limitations
  Compatibility
  Deprecations

Project / History
  Roadmap
  Release history
  Milestone contracts
  Qualification evidence
```

`M35`, `M36`, `M37`, etc. may remain as historical/reference filenames, but a normal user should not need to understand the milestone numbering system to discover a capability.

Where a capability has become current supported behavior, the canonical docs should describe it by task rather than milestone.

---

## 7.5 Current-doc audit

Add:

```text
tests/current-docs.sh
```

or an equivalent deterministic audit.

The audit must verify at minimum:

- `Cargo.toml` version;
- `Cargo.lock` package version;
- `pg_react.control`;
- `src/managed.rs` current-version handling;
- Docker initialization version;
- `README.md`;
- docs home;
- Getting Started;
- Installation;
- Support Matrix;
- Known Limitations;
- API Reference;
- Operations;
- Upgrade;
- M54 release notes;
- adjacent migration;
- release workflow identity.

Historical/version-specific files are placed on an explicit allowlist.

The audit must fail if ordinary docs contain stale current-version assertions such as:

```text
Expect pg-react 1.0.0-rc.1
Use image ...:v0.31.0
Current artifact v0.38.0
```

Older versions remain valid where clearly labeled historical, migration, compatibility, or rollback information.

---

# 8. Workstream B — Finish the ordinary declaration facade

## 8.1 Goal

If an argument appears in the ordinary constructor signature and is documented as supported runtime behavior, the ordinary declaration adapter must carry it end to end.

The constructor must not advertise a field that users are then told to leave null because the generic adapter cannot accept it.

---

## 8.2 `change_columns`

The ordinary rule path must support:

```sql
pgreact.rule(
    ...,
    change_columns => ARRAY['amount', 'risk_level']::name[]
)
```

through:

```text
constructor
-> declaration normalization
-> validation
-> preview
-> deploy
-> stored normalized declaration
-> runtime binding
-> status/export
-> compare/semantic_diff where already modeled
-> replacement/import
```

### Required behavior

- columns must exist in the condition relation;
- semantic-key columns cannot be accepted as changed-value watch columns unless the installed underlying contract already explicitly permits that behavior;
- duplicates normalize or reject according to the existing specialized contract;
- ordering semantics match the existing declaration normalization model;
- an empty array and `NULL` retain their currently defined distinct meanings, if distinct;
- changing only an unwatched projected value does not create a change lifecycle event;
- changing a watched value does;
- existing default behavior continues to watch the currently defined default column set.

M54 must delegate to the installed watched-column implementation rather than create a second change detector.

---

## 8.3 `conflict_key_columns`

The ordinary path must likewise accept:

```sql
conflict_key_columns => ARRAY[...]::name[]
```

when the installed runtime already defines this behavior.

Validation and normalization must use the exact existing conflict-key rules.

M54 must not invent new agenda conflict semantics.

If the underlying specialized contract has an unresolved ambiguity that prevents safe ordinary exposure, M54 must either:

1. resolve and qualify it; or
2. remove the misleading ordinary documentation/signature claim.

Leaving a field visibly accepted by the constructor but unusable in the ordinary adapter is not an acceptable M54 outcome.

---

## 8.4 Compatibility

Existing valid declarations without these fields must return the same normalized semantic result as `0.42.0`.

Calls that were previously rejected only because the ordinary facade failed to carry an otherwise-supported field may become valid.

That widening must be documented as an intentional additive qualification.

---

# 9. Workstream C — Ordinary standalone replacement

## 9.1 Goal

Creation and replacement must use the same ordinary verbs.

This:

```text
rule -> validate -> preview -> deploy
```

must not unexpectedly turn into:

```text
rule -> compare -> pause_rule -> pgreact_api.replace_rule -> inspect UUID-oriented state
```

merely because the stable name already exists.

---

## 9.2 Required rule workflow

A changed active rule must support:

```sql
WITH proposal AS (
    SELECT pgreact.rule(...) AS value
),
review AS (
    SELECT value, pgreact.preview(value) AS preview
    FROM proposal
)
SELECT pgreact.deploy(
    value,
    pgreact.review_token(preview),
    jsonb_build_object(
        'old_work', 'DRAIN_OLD'
    )
)
FROM review;
```

Exact syntax is defined below, but the product behavior is fixed:

- same stable rule name;
- proposal validated normally;
- preview reports `REPLACE`;
- comparison remains optional but strongly recommended;
- deployment requires reviewed-plan evidence;
- command old-work policy is explicit where needed;
- replacement is atomic;
- old behavior remains intact after any failed replacement.

---

## 9.3 Required decision workflow

The same pattern must work for a changed active decision:

```text
construct
-> validate
-> compare
-> preview REPLACE
-> deploy reviewed replacement
-> inspect
```

A user must not need a separate decision-cutover API for an ordinary decision declaration.

M54 does not change decision winner semantics.

---

## 9.4 Replacement planning

The ordinary planner must distinguish:

```text
ADD
KEEP
REPLACE
```

for standalone rule and decision declarations.

`ADOPT` and package-owned `REMOVE` remain package concepts where currently applicable.

The replacement preview must expose:

- target public identity;
- currently deployed declaration digest;
- proposed declaration digest;
- source/function fingerprints needed by the existing safety contract;
- current relevant work state;
- replacement action;
- blockers;
- whether an old-work choice is required;
- reviewed-plan digest/token input.

---

## 9.5 Old work

For a command rule with old executable work, replacement must never infer intent.

Use one vocabulary consistently with package replacement:

```text
DRAIN_OLD
CANCEL_OLD
```

If neither is safe or currently supported for the standalone path, deployment must return a blocker rather than choosing one.

Preview must tell the caller exactly when the choice is required.

### `DRAIN_OLD`

The currently deployed version remains protected until its eligible old work reaches the exact existing drained condition.

Replacement then performs the qualified cutover.

M54 must not invent asynchronous deployment orchestration. If the currently installed planner only supports synchronous completion of this precondition, preserve that boundary and report what the operator must do first.

### `CANCEL_OLD`

Cancellation follows the existing durable work withdrawal/cancellation semantics.

Leased or currently executing work must follow the existing safe barrier rules.

M54 must not turn `CANCEL_OLD` into "pretend the work never existed."

---

## 9.6 Atomicity

Replacement of a standalone object must use one PostgreSQL transaction for the cutover state that currently requires atomicity.

Injected failure at every replacement phase must leave either:

- the complete old deployment; or
- the complete new deployment.

No test may observe a partially replaced active rule/decision.

---

## 9.7 Stale review

Any relevant change between preview and deploy invalidates the reviewed plan.

Relevant changes include at minimum the existing planner's:

- deployment state;
- source definition;
- function definition/binding;
- authorization;
- applicable work state;
- recovery barrier;
- extension state;
- declaration;
- package ownership where relevant.

M54 does not weaken existing stale-plan behavior merely to make the happy path shorter.

---

## 9.8 Compatibility APIs

Existing:

```text
pgreact.replace_rule(...)
pgreact_api.replace_rule(...)
```

or other installed compatibility replacements remain installed.

Current Operations documentation should describe the ordinary `deploy()` replacement as the preferred path once M54 qualification passes.

The compatibility function becomes a compatibility/recovery path rather than the normal authoring workflow.

---

# 10. Workstream D — Reviewed-plan token

## 10.1 Problem

Today callers may need to know whether a preview uses a path such as:

```text
summary.preview_digest
```

or:

```text
summary.plan_digest
```

and then construct a JSON precondition object by hand.

That is safe but unnecessarily leaks representation details into every example and application.

M54 adds one small abstraction over the existing reviewed-plan digest.

---

## 10.2 Public function

Add:

```sql
pgreact.review_token(preview_result jsonb)
RETURNS text
```

Properties:

- immutable/read-only;
- performs no catalog lookup;
- accepts only a recognized successful preview envelope;
- rejects malformed, unsupported, incomplete, or non-preview answers;
- extracts the exact authoritative review identity from the preview;
- returns a bounded versioned opaque string;
- callers are explicitly told not to parse the string.

Maximum token size:

```text
4096 bytes
```

---

## 10.3 Deploy overload

Add:

```sql
pgreact.deploy(
    declaration pgreact_api.declaration,
    review_token text,
    preconditions jsonb DEFAULT '{}'
)
RETURNS jsonb
```

The existing function remains:

```sql
pgreact.deploy(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'
)
RETURNS jsonb
```

No existing call becomes ambiguous.

---

## 10.4 Token semantics

A review token binds the review information needed to identify the exact previewed plan, including at minimum:

- token format version;
- operation;
- target kind;
- target name;
- relevant target version when applicable;
- proposed declaration digest;
- preview/plan digest;
- preview contract identity.

It must not contain:

- authorization credentials;
- secrets;
- source row data;
- private UUIDs unless an existing public plan digest already semantically depends on them and they remain opaque;
- transaction IDs;
- elapsed time;
- worker identity.

Deployment treats the token only as reviewed-plan evidence.

It still:

- validates the declaration;
- resolves the current target;
- checks permissions;
- verifies source/function state;
- verifies work state;
- verifies barriers;
- recomputes or validates the current plan according to the existing planner contract;
- rejects stale state.

A forged token therefore grants nothing.

---

## 10.5 Example

Creation:

```sql
WITH declaration AS (
    SELECT pgreact.rule(...) AS value
),
preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
)
SELECT pgreact.deploy(
    value,
    pgreact.review_token(result)
)
FROM preview;
```

Replacement with old work:

```sql
WITH declaration AS (
    SELECT pgreact.rule(...) AS value
),
preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
)
SELECT pgreact.deploy(
    value,
    pgreact.review_token(result),
    jsonb_build_object('old_work', 'DRAIN_OLD')
)
FROM preview;
```

Complete package deployment uses the same token workflow.

---

## 10.6 Finding codes

Add exact M54 findings for token-specific failures:

```text
M54_REVIEW_TOKEN_INVALID
M54_REVIEW_TOKEN_UNSUPPORTED
M54_REVIEW_TOKEN_MISMATCH
M54_REVIEW_TOKEN_STALE
M54_REVIEW_TOKEN_LIMIT
```

Where an inherited validation/stale-plan finding already exactly describes the error, reuse it instead of duplicating it.

The M54 codes exist only for failures introduced by the token abstraction itself.

---

# 11. Workstream E — Names-first operator recovery

## 11.1 Goal

Do not redesign recovery.

Make the existing recovery operations accept stable public identity where ordinary operators currently have to retrieve a UUID first.

---

## 11.2 Add text overloads

Add names-first overloads over existing rule recovery operations.

At minimum:

```sql
pgreact.reconcile_rule(
    rule_name text,
    mode text
)
```

delegates to the existing UUID-oriented reconciliation implementation.

Add:

```sql
pgreact.sweep_expired_leases(
    rule_name text
)
```

delegating to the existing lease sweep.

Add a stable-name work overload such as:

```sql
pgreact.requeue_episode(
    rule_name text,
    work_id text
)
```

delegating to the existing terminal rule-work retry implementation.

Exact return types remain the same as the authoritative existing operations unless an explicit JSON projection is required to preserve the names-first security contract.

---

## 11.3 Existing text operations

Where operations such as:

```text
pause_rule(text)
resume_rule(text)
```

already exist, use them directly in current documentation.

Do not create another generic `pause` implementation merely to rename a working names-first function.

---

## 11.4 Resolution rules

A name-first administrative overload must:

1. resolve only authorized public targets;
2. reject ambiguous names;
3. reject missing/inaccessible targets through the existing fail-closed boundary;
4. verify that the resolved target is of the supported kind;
5. delegate with the resolved internal identifier;
6. perform no recovery semantics itself.

No UUID should appear in the normal documented task.

---

## 11.5 Retry safety

Retry remains explicit.

It must not:

- retry non-terminal work;
- retry arbitrary decision work unless the existing runtime already proves that operation;
- ignore current drift/barriers;
- bypass idempotency requirements;
- imply exactly-once external effects.

Documentation must continue to warn that replay of an externally delivered effect can result in another delivery.

---

# 12. Workstream F — Deterministic Getting Started and tutorials

## 12.1 Replace scheduler sleeps

Remove canonical tutorial steps such as:

```sql
SELECT pg_sleep(2);
```

when they are used merely to hope that a managed cycle has occurred.

For deterministic documentation, use:

```sql
SELECT pgreact.run();
```

followed by state inspection.

---

## 12.2 Explain the distinction

Getting Started must say explicitly:

> Production normally uses the PostgreSQL-managed worker. The tutorial calls `pgreact.run()` deliberately so that the example has a deterministic point at which evaluation and eligible work have been processed.

Do not teach users to run an extra coordinator continuously.

Do not imply that application transactions should synchronously call `pgreact.run()`.

---

## 12.3 Runnable examples

Every canonical tutorial SQL file must run against the exact candidate image without arbitrary sleeps.

Where asynchronous behavior itself is being demonstrated, use bounded polling with an explicit condition rather than a fixed sleep.

---

# 13. Workstream G — Current API inventory and classification

## 13.1 Add canonical inventory

Add:

```text
docs/api-inventory.json
```

for `0.43.0`.

Example shape:

```json
{
  "schema_version": 1,
  "extension_version": "0.43.0",
  "surfaces": {
    "ordinary": {
      "functions": [],
      "views": []
    },
    "advanced": {
      "functions": [],
      "views": []
    },
    "administrative": {
      "functions": [],
      "views": []
    },
    "compatibility": {
      "functions": [],
      "views": []
    }
  }
}
```

Internal schemas do not appear as supported application API.

---

## 13.2 Installed-catalog audit

M54 qualification boots the candidate and queries PostgreSQL catalogs for public pg-react objects.

The result is normalized and compared with the checked-in inventory.

The audit must detect:

- an installed public function missing from classification;
- a documented signature not actually installed;
- a changed volatility/security-definer classification where tracked;
- an unexpected public grant;
- an ordinary view missing from the inventory.

The inventory becomes the machine authority for surface classification.

---

## 13.3 Human API reference

`docs/api-reference.md` is current-product documentation.

It must not begin with language such as:

> based on the 1.0.0-rc.1 / 0.31.0 baseline and intentionally non-exhaustive.

Instead:

> This reference describes the public API classification installed by pg-react 0.43.0.

Milestone-specific references remain linked where deeper contract history is useful.

---

# 14. Workstream H — 0.x compatibility and versioning policy

## 14.1 Goal

Postponing `1.0.0` indefinitely must not mean that users are expected to treat every `0.x` release as disposable.

Publish:

```text
docs/versioning.md
```

---

## 14.2 Ordinary API policy

Beginning with M54, the project policy is:

1. Valid ordinary calls are compatibility-preserving by default across adjacent `0.x` releases.
2. Existing ordinary output does not silently acquire incompatible meanings.
3. An incompatible ordinary change requires:
   - an explicit compatibility decision;
   - release-note prominence;
   - a migration path;
   - prior deprecation where reasonably possible.
4. Ordinary function removal requires a documented replacement and at least two published deprecation releases unless retention would preserve an unsafe behavior.
5. Compatibility/admin surfaces may have narrower guarantees, but their classification must be explicit.
6. Internal schemas remain outside compatibility promises.

This is a project policy stronger than the freedom nominally permitted by pre-1.0 semantic versioning.

---

## 14.3 JSON result compatibility

For result contracts already tested byte-for-byte:

- do not add default fields casually;
- add new optional behavior through a new operation, option, overload, or contract version;
- retain semantic fields and ordering rules defined by the originating contract.

M54 does not introduce a universal JSON envelope.

---

## 14.4 Runtime support

M54 itself does not remove currently accepted historical runtime versions merely to establish a support policy.

The documentation must distinguish:

```text
accepted by managed runtime
```

from:

```text
actively qualified current adoption boundary
```

Any future narrowing of the accepted managed-runtime window requires its own explicit release decision.

---

# 15. Workstream I — CI and release qualification coherence

## 15.1 Problem

The current repository can have:

- a successful release workflow;
- a failed separate CI workflow;

for the same tagged commit.

Even if the release-specific qualification is stronger, that state is confusing and weakens the meaning of a published tag.

M54 establishes one canonical qualification definition.

---

## 15.2 Reusable qualification workflow

Add a reusable workflow, for example:

```text
.github/workflows/qualification.yml
```

invoked through `workflow_call`.

The canonical qualification job owns:

- Rust formatting;
- Rust unit tests;
- dependency audit where required for release;
- pgrx/PostgreSQL skeleton check;
- current-doc audit;
- API inventory audit;
- candidate Docker build;
- inherited mandatory qualification;
- M54 fresh-install lane;
- `0.42.0 -> 0.43.0` populated upgrade;
- rollback-by-restore;
- M54 compatibility corpus;
- evidence artifact production.

PR/push CI may additionally have a fast lane, but the release workflow must call the same canonical full qualification definition rather than reproduce it independently.

---

## 15.3 Fix command-chain fragility

No CI step may rely on YAML folded-scalar behavior to separate shell commands.

Multi-command qualification uses:

```yaml
run: |
  command_one
  command_two
```

or explicit `&&`.

Add:

```text
actionlint
```

or an equivalent workflow syntax/static audit if practical in the pinned build environment.

At minimum, add a repository test that catches accidental concatenation of Docker build arguments and test commands.

---

## 15.4 Release dependency

Release publication is a job that depends on successful canonical qualification.

Conceptually:

```text
tag v0.43.0
    |
    v
canonical qualification
    |
    +-- failure -> no image push, no GitHub release
    |
    v
publish exact qualified artifact
    |
    v
attest
    |
    v
release
```

The image that is published must be the candidate image that passed qualification, not a separately rebuilt semantically equivalent image where avoidable.

---

# 16. Workstream J — Evidence provenance cleanup

## 16.1 No synthetic qualification placeholders

Do not create files whose only content is equivalent to:

```text
inherited qualification completed before packaging
```

and then package them as though they were qualification evidence for this release.

A missing evidence directory is not evidence.

---

## 16.2 Add evidence manifest

Every release evidence bundle contains:

```text
evidence-manifest.json
```

Each inherited milestone is represented as either:

### Executed in this release

```json
{
  "milestone": "M44",
  "mode": "executed",
  "workflow_run": "...",
  "artifact": "...",
  "sha256": "..."
}
```

or:

### Inherited by immutable reference

```json
{
  "milestone": "M44",
  "mode": "inherited",
  "release": "v0.41.0",
  "artifact": "pg-react-v0.41.0-evidence.tar.gz",
  "sha256": "..."
}
```

A consumer can therefore tell whether evidence was:

- rerun against the candidate; or
- inherited from an earlier qualified artifact.

Do not blur the distinction.

---

## 16.3 Candidate evidence

M54-specific evidence must include real output for:

- docs audit;
- API inventory;
- ordinary facade fields;
- standalone rule replacement;
- standalone decision replacement;
- review token;
- names-first recovery;
- fresh install;
- populated upgrade;
- rollback;
- release compatibility.

---

# 17. Workstream K — Roadmap and project-history simplification

## 17.1 Goal

`ROADMAP.md` should answer:

> Where is the project now, and what decisions come next?

It should not require scrolling through the complete implementation history to answer that question.

---

## 17.2 New `ROADMAP.md` shape

Keep:

1. product goal;
2. product principles;
3. current release;
4. current milestone;
5. current support/adoption priorities;
6. explicit non-goals;
7. milestone selection rules;
8. next candidate decision table.

Move completed stage detail into History.

Example current candidate table after M54:

| Candidate | Choose when |
|---|---|
| M59 — Supported-scale qualification | Capacity, WAL, storage, retention, or recovery uncertainty blocks adoption |
| M58 — Authorization alignment | Grants, security context, or RLS blocks a real supported workload |
| M45 — Rolling/hopping windows | Missing event-time windows block an otherwise suitable policy |
| M55 — Schema-change safety | Ordinary DDL cannot be shown safe |
| M56 — Rebuild/reconciliation safety | Recovery/rebuild behavior cannot be shown safe |

M55/M56 override product-expansion candidates when safety evidence requires them.

---

## 17.3 Historical roadmap

Move the completed detailed roadmap through M53 into something such as:

```text
docs/history/roadmap-through-m53.md
```

Do not delete historical evidence.

`docs/history.md` links to it.

Git history is not treated as the only record of historical contracts.

---

# 18. SQL implementation boundary

Prefer M54 as a catalog-light release.

The implementation should require no new durable catalog family.

Expected SQL changes belong in:

```text
sql/m54.sql
sql/pg_react--0.42.0--0.43.0.sql
sql/pg_react--0.43.0.sql
```

Target:

```text
pg_react--0.43.0.sql
=
pg_react--0.42.0.sql
+
m54.sql
```

unless a documented reason requires otherwise.

---

## 18.1 Expected SQL changes

`m54.sql` should primarily contain:

- replacements/fixes to ordinary declaration normalization/adaptation;
- replacement planning/deployment dispatch for standalone rules and decisions;
- `pgreact.review_token(jsonb)`;
- reviewed-token `pgreact.deploy(...)` overload;
- stable-name administrative overloads;
- grants/revokes for the new exact signatures;
- comments/documentation metadata if used by inventory.

Avoid new tables.

If implementation discovers that additional durable state is necessary for replacement correctness, stop and amend this plan before adding it.

---

# 19. Security requirements

## 19.1 Review token

A review token is not a capability token.

Possessing one does not grant:

- target visibility;
- deploy permission;
- source access;
- function execution;
- adoption rights;
- cancellation rights.

Every deploy call performs normal authorization.

---

## 19.2 Security-definer wrappers

Any M54 wrapper that requires `SECURITY DEFINER` must use:

```text
search_path = pg_catalog, pg_temp
```

and explicitly schema-qualify internal calls.

Do not trust caller-controlled `search_path`.

---

## 19.3 Names-first administrative resolution

Absent and inaccessible target behavior must follow the existing fail-closed contract.

An unauthorized user must not learn through the wrapper:

- that a target exists;
- its internal UUID;
- work counts;
- deployment version;
- source object;
- owner;
- recovery state.

---

## 19.4 Deployment race

Replacement must preserve existing DDL/function identity locking and verification rules.

M54 ergonomics must not shorten the critical safety checks.

---

# 20. Concurrency requirements

Exact tests must cover concurrent:

- preview vs source DDL;
- preview vs consequence DDL;
- preview vs deploy;
- two replacements of the same name;
- remove vs replace;
- worker claim vs replacement;
- old-work completion vs replacement;
- authorization change vs replacement;
- package ownership change vs standalone replacement;
- extension update vs managed worker;
- review-token deployment after state change.

For every race, the result must be:

- one valid old state;
- one valid new state;
- or an exact retry/stale/blocking finding.

No mixed deployment is acceptable.

No new deadlock may appear in the qualified lock-order fixture.

---

# 21. Compatibility requirements

## 21.1 Existing calls

Every valid `0.42.0` call must preserve its existing result when:

- the new overload is not selected;
- newly supported constructor fields remain null/default;
- standalone active replacement is not attempted.

The M54 compatibility corpus must compare exact outputs for representative:

- rule construction;
- decision construction;
- policy package;
- validate;
- preview;
- deploy create;
- status;
- compare;
- explain;
- why-not;
- trace;
- evidence;
- export/import;
- remove.

---

## 21.2 Existing views

M54 should not rename, reorder, or remove columns from an existing current public view.

If a new projection is required, add a new view.

Avoid appending columns to widely used ordinary views unless the compatibility audit explicitly proves that this is acceptable.

---

## 21.3 Historical extension artifacts

Do not rewrite historical `pg_react--X.sql` install artifacts.

Only the new adjacent migration and new full-install artifact are authored for M54.

---

# 22. Performance and resource requirements

M54 is not M59.

It makes no new broad scale claim.

It must, however, avoid obvious regression.

## 22.1 Review token

Token construction:

- operates only on the bounded preview result supplied by the caller;
- performs no source scan;
- performs no catalog scan;
- performs no deployment lookup;
- has the 4096-byte output bound.

## 22.2 Name resolution

New administrative stable-name overloads use bounded/indexable catalog lookup.

They must not scan unbounded work history to resolve the target.

## 22.3 Replacement

Ordinary replacement should delegate to existing planner/runtime work rather than perform a second full evaluation solely because it entered through `pgreact.deploy()`.

Record:

- preview latency;
- replacement latency;
- catalog changes;
- WAL;
- work-state handling;
- returned payload size.

Do not market these measurements as general capacity qualification.

## 22.4 Regression fixture

Representative M53 package and ordinary-rule workloads should remain within a documented regression envelope.

A large regression must be explained or fixed before release.

Avoid brittle wall-clock assertions in correctness tests.

---

# 23. Implementation sequence

M54 should be implemented in slices with independently executable gates.

---

## Phase 0 — Freeze the M54 contract

Deliver:

```text
docs/m54-implementation-plan.md
docs/m54-contract.md
```

Record:

- exact scope;
- exact public additions;
- compatibility rules;
- release boundary;
- non-goals.

Do not begin unrelated M45/M58/M59 implementation while the M54 release boundary is open.

---

## Phase 1 — Current-release manifest and docs audit

Implement:

```text
docs/current-release.json
tests/current-docs.sh
```

Update only enough docs initially to make the audit useful.

Gate:

```text
M54 current-release audit passed
```

---

## Phase 2 — Ordinary constructor facade

Implement `change_columns` and `conflict_key_columns` end-to-end.

Add exact tests for:

- normalized declaration;
- invalid columns;
- duplicates;
- default/null behavior;
- stored declaration;
- runtime behavior;
- export/import;
- semantic difference;
- populated upgrade.

Gate:

```text
M54 ordinary declaration facade passed
```

---

## Phase 3 — Standalone replacement

First implement rule replacement through generic deploy.

Then decision replacement.

Do not implement both in one undifferentiated test fixture.

Gates:

```text
M54 ordinary rule replacement passed
M54 ordinary decision replacement passed
```

---

## Phase 4 — Review token

Add token extractor and deploy overload after generic replacement semantics are working.

Gate:

```text
M54 reviewed deployment passed
```

---

## Phase 5 — Names-first recovery

Add stable-name overloads over authoritative administrative operations.

Gate:

```text
M54 names-first recovery passed
```

---

## Phase 6 — Documentation reset and API inventory

Add neutral current docs, compatibility stubs, current API inventory, and installed-catalog audit.

Gate:

```text
M54 current API and documentation passed
```

---

## Phase 7 — CI/evidence refactor

Introduce canonical reusable qualification and evidence manifest.

Before changing release publication, prove the reusable qualification on an untagged candidate.

Gate:

```text
M54 canonical qualification workflow passed
```

---

## Phase 8 — Adjacent upgrade and release qualification

Build exact `0.43.0` candidate.

Run:

- fresh install;
- populated `0.42.0 -> 0.43.0`;
- rollback-by-restore;
- inherited qualification;
- M54 complete lane;
- documentation/API audits;
- release artifact audit.

Only after all pass may `v0.43.0` be tagged/published.

---

# 24. Test plan

Add:

```text
tests/m54.sh
tests/m54.sql
```

Optional focused files are encouraged when they make failures clearer:

```text
tests/m54-docs.sh
tests/m54-replacement.sql
tests/m54-ergonomics.sql
tests/m54-upgrade-before.sql
tests/m54-upgrade-after.sql
```

The complete gate remains:

```sh
bash tests/m54.sh complete pg-react:m54-unreleased
```

---

# 25. Exact qualification matrix

| Area | Required cases |
|---|---|
| Current docs | all current-version assertions agree |
| Constructor facade | default, watched columns, conflict columns, invalid input |
| Rule create | ADD |
| Rule redeploy identical | KEEP |
| Rule replacement | REPLACE |
| Decision create | ADD |
| Decision redeploy identical | KEEP |
| Decision replacement | REPLACE |
| Command old work | none, pending, leased, completed, failed |
| Old-work policy | omitted, DRAIN_OLD, CANCEL_OLD, malformed |
| Review token | valid, malformed, oversized, wrong operation |
| Token binding | wrong target, wrong declaration, stale plan |
| Authorization | owner, author, operator, reader, unauthorized |
| DDL race | source and consequence |
| Concurrent deploy | same target and different target |
| Removal race | replace vs remove |
| Recovery wrappers | ready, missing, ambiguous, unauthorized |
| Tutorial | deterministic complete run |
| API inventory | installed == classified |
| Fresh install | exact 0.43.0 image |
| Upgrade | populated 0.42.0 -> 0.43.0 |
| Rollback | verified 0.42.0 restore |
| Compatibility | inherited valid output unchanged |
| Evidence | no placeholder qualification |
| Release | canonical qualification required |

---

# 26. Failure-injection requirements

For standalone replacement, inject failure after every meaningful phase, including:

- validation;
- target resolution;
- current declaration load;
- replacement planning;
- old-work check;
- source verification;
- consequence verification;
- generated object creation/replacement;
- binding/catalog update;
- active-version cutover;
- history/audit write;
- cleanup.

Each injected failure must leave the exact old deployment operational.

No orphan generated object may become active.

---

# 27. Documentation acceptance journeys

Qualification must execute—not merely display—the canonical documentation journeys.

## Journey A — First rule

```text
install
-> doctor
-> create authoritative table/view
-> create consequence
-> validate
-> preview
-> deploy with review token
-> mutate source
-> pgreact.run()
-> inspect work/result
-> explain
```

No sleep.

No UUID.

---

## Journey B — Safe replacement

```text
construct proposal
-> validate
-> compare
-> semantic_diff
-> preview
-> deploy reviewed replacement
-> pgreact.run()
-> inspect
```

No compatibility replacement API.

---

## Journey C — Failed work

```text
inspect pgreact.work
-> inspect attempts
-> explain/trace
-> repair cause
-> names-first requeue
-> pgreact.run()
-> verify
```

No UUID lookup.

---

## Journey D — Complete policy change

```text
construct package
-> validate
-> compare
-> preview
-> review_token
-> deploy
-> inspect contents/dependencies
-> export
```

The review workflow must look substantially the same as standalone deployment.

---

## Journey E — Recovery

```text
doctor
-> identify barrier
-> stop managed activity as documented
-> names-first recovery operation
-> verify
-> resume
```

The exact operation remains advanced/administrative where appropriate, but its ordinary documented use requires only public identity.

---

# 28. Documentation deliverables

M54 release requires:

```text
docs/m54-contract.md
docs/m54-api-reference.md
docs/m54-api-inventory.json
docs/m54-finding-codes.json
docs/m54-evidence.md
docs/m54-migration.md
docs/m54-known-limitations.md
docs/m54-release-notes.md
docs/m54-final-checklist.md
docs/current-release.json
docs/api-inventory.json
docs/versioning.md
```

Canonical current docs also updated:

```text
README.md
docs/index.md
docs/getting-started.md
docs/concepts.md
docs/installation.md
docs/authoring.md
docs/changing-policies.md
docs/operations.md
docs/api-reference.md
docs/security.md
docs/backup-restore.md
docs/upgrade.md
docs/troubleshooting.md
docs/support-matrix.md
docs/known-limitations.md
docs/limits.md
docs/compatibility.md
docs/deprecations.md
ROADMAP.md
docs/history.md
```

---

# 29. Release notes framing

The `0.43.0` release message should be about using what pg-react already has more naturally.

Suggested title:

```text
pg-react 0.43.0: one ordinary path from first rule to safe replacement
```

or:

```text
pg-react 0.43.0: make the current product the easy path
```

Release notes should lead with user outcomes:

- current installation instructions now describe the actual release;
- create and replace use the same ordinary deployment workflow;
- all ordinary rule constructor fields work through the facade;
- reviewed deployment no longer requires manual digest JSON;
- common recovery tasks no longer require UUID lookup;
- tutorials advance deterministically;
- public API classification matches the installed extension;
- release and qualification evidence now have one authoritative lane.

Do not lead with M54 terminology.

---

# 30. Migration contract

Supported adjacent update:

```text
0.42.0 -> 0.43.0
```

The extension update must not automatically:

- replace any active rule;
- replace any decision;
- redeploy a policy set;
- cancel work;
- retry work;
- reconcile state;
- change source rows;
- change parameter rows;
- change evidence;
- adopt standalone objects;
- alter application relations;
- remove compatibility APIs.

The upgrade installs the new facade/wrappers and fixes public dispatch.

Any changed deployment occurs only after an explicit later call.

---

# 31. Rollback

Rollback remains restore-based unless PostgreSQL extension downgrade is separately qualified.

Release instructions require:

1. verified `0.42.0` backup;
2. upgrade to `0.43.0`;
3. verification;
4. restore the verified `0.42.0` backup if rollback is required.

The M54 release lane proves this procedure.

---

# 32. Known limitations after M54

M54 does not claim to solve:

- PostgreSQL versions other than the qualified tuple;
- operating systems/architectures outside the qualified tuple;
- RLS-backed evaluated sources;
- broad comparison key-type parity unless separately implemented and qualified;
- unbounded comparison evidence;
- comparison continuation tokens;
- full measured fan-out/cascade/memory/temp-storage cost;
- global order;
- exactly-once external delivery;
- synchronous application write-path actions;
- cross-database policy deployment;
- general workflows;
- missing event-time capabilities selected for M45;
- broad supported-scale evidence selected for M59;
- authorization alignment selected for M58;
- schema-change planning selected for M55;
- rebuild/reconciliation expansion selected for M56.

These remain explicit rather than being quietly implied by the ergonomic cleanup.

---

# 33. Optional stretch item: comparable UUID/text rule keys

This item is **not required for M54 release** unless implementation review promotes it into the fixed contract before SQL work begins.

The current mismatch between advanced typed-key support and bigint-only ordinary rule comparison is a meaningful adoption issue.

If pursued in M54, constrain the expansion to:

```text
one non-null unique bigint, uuid, or text semantic key
```

with deterministic text collation requirements.

Do not add composite comparison in the same release.

Before promoting this stretch item, prove that widening the comparison key adapter does not silently alter:

- hypothetical comparison;
- replay;
- backtesting;
- why-changed;
- comparison result identity.

If the evaluator is shared and those surfaces cannot be independently bounded, move key parity to a dedicated later milestone instead.

M54 must not become a semantic-expansion release merely to include this item.

---

# 34. Explicit non-goals

M54 does not implement:

- M45 rolling/hopping windows;
- M46 business calendar windows;
- M47 finite event sequences;
- M48 absence-after-event;
- M49 temporal qualification;
- M55 schema migration planning;
- M56 new recovery semantics;
- M58 RLS/security-context alignment;
- M59 scale qualification;
- cross-package dependencies;
- nested packages;
- cross-database packages;
- automatic schema migrations;
- deployment approvals;
- GitOps controller behavior;
- client SDKs;
- a CLI authoring language;
- visual policy editing;
- AI policy generation;
- arbitrary SQL semantic analysis;
- a general workflow engine.

---

# 35. M54 final exit gates

M54 / `0.43.0` may ship only when all of these gates pass.

## Product coherence

- Current docs agree on `0.43.0`.
- No ordinary onboarding path refers to the postponed RC as current.
- Neutral current-product docs are canonical.
- Historical links remain reachable.
- Current API inventory matches the installed candidate.

## Ordinary authoring

- Every documented ordinary rule-constructor field works through the declaration facade.
- Existing default rule behavior is unchanged.
- Exact watched/conflict-column fixtures pass.

## Replacement

- Successful active rule replacement through `pgreact.deploy()` is qualified.
- Successful active decision replacement through `pgreact.deploy()` is qualified.
- KEEP remains no-op.
- stale review is rejected.
- old-work choices are explicit.
- failure injection observes no partial cutover.
- concurrency fixtures do not deadlock.

## Reviewed deployment

- `pgreact.review_token()` recognizes every supported ordinary preview kind.
- malformed/oversized/wrong/stale tokens fail exactly.
- existing JSON precondition calls remain compatible.
- tokens confer no authorization.

## Operations

- canonical failed-work and reconciliation runbooks use public names.
- no normal documented recovery journey requires UUID lookup.
- wrappers preserve fail-closed authorization.

## Tutorials

- Getting Started passes end to end without `pg_sleep`.
- package and replacement tutorials pass against the candidate image.

## Compatibility

- fresh `0.43.0` installation passes.
- populated `0.42.0 -> 0.43.0` passes.
- rollback-by-restore passes.
- representative valid `0.42.0` calls keep exact expected output when M54 additions are unused.
- compatibility functions remain installed.

## Release engineering

- canonical qualification is green for the exact release commit.
- the release job depends on that qualification.
- artifact image digest is the qualified digest.
- SBOM/checksums/attestations pass.
- evidence manifest contains no synthetic qualification claims.
- no P0 or P1 remains.

---

# 36. Final checklist

Create `docs/m54-final-checklist.md` with at least:

```markdown
# M54 final checklist

- [ ] Extension identity is `0.43.0`.
- [ ] Adjacent migration is `0.42.0 -> 0.43.0`.
- [ ] Current-release manifest matches code, image, docs, and release workflow.
- [ ] Current documentation no longer presents `1.0.0-rc.1` as current.
- [ ] Neutral current-product documentation paths are canonical.
- [ ] `change_columns` works through the ordinary declaration facade.
- [ ] `conflict_key_columns` works through the ordinary declaration facade.
- [ ] Ordinary active rule replacement is qualified.
- [ ] Ordinary active decision replacement is qualified.
- [ ] Review-token deployment is qualified.
- [ ] Existing JSON deployment calls remain compatible.
- [ ] Names-first recovery journeys require no UUID lookup.
- [ ] Getting Started is deterministic without `pg_sleep`.
- [ ] Installed public API matches the current API inventory.
- [ ] 0.x versioning/compatibility policy is published.
- [ ] Canonical CI/release qualification is unified.
- [ ] Release evidence contains no synthetic placeholder qualification.
- [ ] Fresh install passes.
- [ ] Populated `0.42.0 -> 0.43.0` upgrade passes.
- [ ] Rollback-by-restore passes.
- [ ] Inherited qualification passes or is referenced by exact immutable evidence.
- [ ] No P0 or P1 remains.
- [ ] Post-M54 adoption evidence selects M59, M58, M45, M55, M56, or another justified milestone.
```

---

# 37. Decision after M54

Do not automatically begin M45.

After `0.43.0`, collect adoption evidence against the hardened ordinary path.

Default decision order, absent stronger field evidence:

1. **M59 — Supported-scale qualification**
   Choose when users can express and deploy policies but cannot make an operating decision because throughput, WAL, catalog growth, storage, retention, recovery time, or bounded comparison cost is uncertain.

2. **M58 — Authorization alignment**
   Choose when otherwise-suitable PostgreSQL workloads are blocked by RLS, grants, or execution-context boundaries.

3. **M45 — Rolling and hopping windows**
   Choose when a real policy cannot be expressed because bounded event-time windows are missing.

4. **M55 — Schema-change safety**
   Takes priority immediately if normal PostgreSQL DDL creates an unsafe or insufficiently explainable deployment state.

5. **M56 — Rebuild/reconciliation safety**
   Takes priority immediately if restore, rebuild, failover, or reconciliation cannot be shown safe through the current public model.

The project should continue committing to one milestone at a time.

---

# 38. M54 definition of done

The shortest useful definition is:

> An independent PostgreSQL user can install current pg-react, author a rule or decision, safely replace it, inspect and explain it, repair a common failure, and follow the current documentation using stable public identities and the ordinary API—without knowing milestone history, without using stale RC instructions, without manually translating preview digest formats, and without dropping into a compatibility replacement API.

`0.43.0` does not make pg-react more powerful.

It makes the power already delivered through `0.42.0` substantially easier to adopt, review, operate, and trust.

# pg-react v1.0 Documentation Readiness Plan

> **Scope:** Prepare pg-react for a `1.0.0` release after M34 / `0.31.0`.
> **Explicitly excluded:** M35 hypothetical fact simulation and every later milestone.
> **Audience:** Maintainers, documentation owners, release managers, API owners, and reviewers preparing the v1 release candidate.
> **Status:** Proposed documentation work plan.

## 1. Purpose and release premise

This document defines the end-user documentation that should be created, rewritten, consolidated, tested, and qualified before pg-react releases `1.0.0` with M34 as the product boundary.

The v1 product promise should be stated consistently as:

> pg-react is a PostgreSQL-native rule and policy engine that lets users define, validate, deploy, operate, inspect, explain, and safely compare proposed policy changes against current authoritative PostgreSQL facts without mutating production state or executing effects.

That promise includes the M33 core and the M34 deployment-impact comparison capability. It does **not** include hypothetical inserts, updates, or deletes; historical replay; backtesting; or why-changed comparison.

The documentation goal is not to publish more milestone evidence. The repository already contains substantial milestone contracts, evidence records, readiness notes, and release artifacts. The goal now is to turn that material into one coherent, milestone-free product manual for PostgreSQL users.

A user should be able to arrive at the repository with no knowledge of M0–M34 and answer these questions:

1. What problem does pg-react solve?
2. Is my environment and use case supported?
3. How do I install it and create my first rule?
4. How do I inspect and operate it safely?
5. How do I compare a proposed policy change before deployment?
6. What guarantees, limits, and exclusions apply in v1?

## 2. Documentation principles for v1

The v1 documentation should follow the same product principles as the runtime.

### PostgreSQL-native

Examples should use ordinary SQL, typed PostgreSQL identities, views, functions, rows, and public relational result sets. The common path must not require private UUID discovery, private schemas, hand-written internal JSON, or direct catalog updates.

### Task-first

Users should encounter tasks before contracts. The primary navigation should lead to “Install,” “Create a rule,” “Compare a proposed change,” “Operate,” “Troubleshoot,” and “Upgrade,” not to milestone numbers or internal subsystem names.

### One canonical ordinary API

The README, authoring guide, examples, API reference, operations guide, and release notes must teach the same ordinary SQL surface. Older compatibility APIs may be documented in a migration or compatibility section, but they must not appear as the default path.

### Exact about guarantees

Documentation must clearly distinguish:

- current authoritative state from proposed comparison output;
- durable work from would-be work;
- exact results from bounded or partial evidence;
- transactional database effects from at-least-once external delivery;
- current-state comparison from hypothetical facts and historical replay;
- supported configurations from experimental or unqualified configurations.

### Executable

Every primary SQL example should run against the exact packaged release-candidate artifact. Intentional error examples should assert stable finding codes. Documentation must be part of release qualification, not a prose-only afterthought.

### Milestone-free for end users

M-numbers belong in roadmap and historical evidence pages. They should not be required to understand the product. End-user pages may mention that `0.31.0` introduced comparison in release-history context, but normal instructions should describe features by task and capability.

## 3. Current-state audit

The repository already has strong raw material, but it is not yet internally consistent enough for a v1 release.

### What is already useful

- `README.md` contains a modern, task-first rule workflow using `pgreact.rule()`, `pgreact.preview()`, `pgreact.deploy()`, `pgreact.run()`, public views, and `pgreact.explain()`.
- The M34 document set defines `pgreact.compare()` and `pgreact.compare_results()`, the current/proposed/delta model, bounded evidence, no-effect guarantees, supported declaration kinds, and comparison limits.
- `docs/v1-contract.md`, `docs/v1-support-matrix.md`, `docs/v1-security.md`, `docs/v1-limits.md`, `docs/v1-operations.md`, `docs/v1-backup-restore.md`, and related files already provide material for a normative v1 package.
- Generated API and finding inventories already exist and can become release-qualification inputs.
- Historical milestone evidence is extensive and should remain available for maintainers and auditors.

### Release-blocking inconsistencies

The following issues should be treated as documentation blockers for `1.0.0-rc.1`.

#### 3.1 The release boundary is contradictory

The README and M34 release notes currently say M35 must happen before the first numbered release candidate. That conflicts with the proposed decision to make M34 the v1 boundary.

Required action:

- Update the README, roadmap, release notes, readiness records, and any versioning notes so that the sequence becomes:

  ```text
  0.31.0 -> 1.0.0-rc.1 -> later RCs as required -> 1.0.0
  ```

- Move M35 to the post-v1 roadmap and describe it as a possible `1.1.0` capability or later compatible feature, subject to its own design and evidence.
- Remove every statement that makes M35 a prerequisite for v1.

#### 3.2 The authoring guide teaches an older API

`docs/v1-authoring.md` currently uses older functions such as `preview_rule()`, `validate_rule()`, and `create_rule()`, while the README and frozen ordinary contract use `pgreact.rule()`, `pgreact.validate()`, `pgreact.preview()`, and `pgreact.deploy()`.

It also describes a much narrower product boundary than the current runtime, including statements that derivations and other capabilities are post-GA.

Required action:

- Rewrite the guide around the frozen ordinary declaration API.
- Keep legacy functions only in a clearly labeled compatibility or migration appendix.
- Cover the v1 rule, decision, and policy-set declaration model at the correct level.
- Remove obsolete release-version references and claims that contradict the current v1 contract.

#### 3.3 Installation and runtime instructions describe different worker models

`docs/v1-installation.md` still centers the external `pg-reactd` polling path and an older preload/configuration model, while the README and support matrix describe the PostgreSQL-managed coordinator and worker with `pg_react` preloaded and configured databases/roles.

Required action:

- Make the PostgreSQL-managed runtime the only ordinary v1 installation path.
- Describe `pg-reactd` only as a compatibility or migration tool where it remains supported.
- Publish exact required settings, preload entries, database list configuration, role configuration, restart requirements, and `doctor()` checks.
- Ensure the installation guide, support matrix, container instructions, README, and operations guide use the same runtime model.

#### 3.4 The current `v1-release-notes.md` is not a v1 release note

The file named `docs/v1-release-notes.md` is an immutable historical record for the old `0.1.1` release. Its name is likely to mislead users and release tooling.

Required action:

- Create a new actual v1 release note, preferably `docs/1.0-release-notes.md` or `docs/releases/1.0.0.md`.
- Preserve the historical `0.1.1` record, but move or relabel it as historical M4 evidence when repository policy permits.
- If the old file cannot be moved, remove it from all end-user navigation and add an unmistakable pointer to the real `1.0.0` release note.

#### 3.5 Upgrade documentation contains obsolete target versions

`docs/v1-upgrade.md` describes candidate paths but still instructs users to update to `0.30.0`. Other files describe historical `0.1.1` upgrade behavior under a v1-looking name.

Required action:

- Publish exact supported paths into `1.0.0-rc.N` and `1.0.0`.
- Include `0.31.0 -> 1.0.0-rc.N -> 1.0.0` as the primary current path.
- Include every older direct or staged path only if it is exercised by release qualification.
- Remove commands that update to the wrong version.
- Separate current upgrade instructions from immutable historical upgrade records.

#### 3.6 M34 documentation is reference-oriented rather than task-oriented

The current M34 example is a short SQL fragment and points users to the test fixture for the complete workflow. That is useful evidence but insufficient as the flagship v1 safe-change guide.

Required action:

- Create a full “Changing a policy safely” guide.
- Demonstrate comparison, interpretation, evidence completeness, authorization, no-effect behavior, deployment, and post-deployment verification.
- Include complete examples for a rule, a decision, and a policy set.
- Keep M34 contracts and evidence as maintainer references, not the primary user journey.

#### 3.7 There is no obvious documentation home

The repository has many hundreds of milestone files but no single user-facing documentation index that distinguishes tutorials, how-to guides, reference material, operations, and historical evidence.

Required action:

- Create `docs/index.md` as the canonical documentation home.
- Link only the supported current product path from the main sections.
- Put milestone records behind a separate “Release and milestone history” entry.

#### 3.8 Core concepts are fragmented

The README explains parts of the lifecycle model, but users must currently infer how facts, conditions, semantic keys, matches, activations, revisions, decisions, policy sets, applicability, work, explanations, and comparisons fit together.

Required action:

- Create one concise but complete concepts guide.
- Use one consistent vocabulary across every document.
- Explicitly explain the difference between production evaluation and read-only comparison.

#### 3.9 The API reference is fragmented

The frozen ordinary API, generated inventories, compatibility functions, M34 comparison functions, finding codes, result envelopes, and public views are distributed across several files.

Required action:

- Create one human-readable v1 API reference generated or verified from installed reality.
- Retain machine-readable inventories as normative artifacts.
- Clearly label ordinary, advanced, compatibility, and administrative surfaces.

#### 3.10 Historical evidence dominates discoverability

Milestone records are valuable, but their naming and volume make it easy for users to land on obsolete instructions.

Required action:

- Do not delete historical evidence.
- Remove historical files from the main end-user navigation.
- Add a history index explaining that M-files are delivery evidence, not current user guides.
- Add strong historical banners to the most likely misleading pages, especially old files with `v1` in their names.

## 4. Proposed documentation architecture

The documentation should be organized into four layers.

### Layer 1: Product landing and onboarding

```text
README.md
└── docs/index.md
    ├── getting-started.md
    ├── concepts.md
    ├── v1-authoring.md
    └── changing-policies.md
```

These pages should be understandable without reading any contract or milestone file.

### Layer 2: Day-two operation and safety

```text
docs/v1-installation.md
docs/v1-operations.md
docs/v1-troubleshooting.md
docs/v1-security.md
docs/v1-backup-restore.md
docs/v1-upgrade.md
docs/v1-support-matrix.md
docs/v1-limits.md
docs/v1-known-limitations.md
```

These pages should be task-oriented but exact enough to serve operators.

### Layer 3: Normative and reference material

```text
docs/v1-contract.md
docs/v1-api-reference.md
docs/v1-api-inventory.json
docs/v1-finding-codes.json
docs/v1-compatibility.md
docs/v1-deprecations.md
docs/1.0-release-notes.md
```

These pages define the stable `1.x` contract and installed public surface.

### Layer 4: Historical evidence

```text
docs/history.md
docs/m0-*.md ... docs/m34-*.md
historical release and migration records
```

Historical pages remain available but are not part of the normal learning path.

## 5. New documents to create

### 5.1 `docs/index.md` — Documentation home

**Purpose:** Give users one obvious starting point and prevent accidental navigation into obsolete milestone material.

**Required content:**

- One-paragraph product description.
- Current stable/candidate version and support status.
- “Start here” links for installation and first rule.
- Task-based navigation:
  - install;
  - create a rule;
  - create a decision;
  - create a policy set;
  - compare a proposed change;
  - inspect and explain;
  - operate and troubleshoot;
  - upgrade and recover.
- Reference navigation:
  - API;
  - findings;
  - support matrix;
  - limits;
  - security;
  - compatibility and deprecations.
- Release-history link separated from user guidance.
- A clear statement that M35 hypothetical fact simulation is not part of v1.

**Acceptance criteria:**

- A new visitor can choose the correct next page in one click.
- No primary navigation item is named after a milestone.
- No primary link points to an obsolete API example.

### 5.2 `docs/getting-started.md` — End-to-end first rule

**Purpose:** Let a PostgreSQL developer complete a useful rule workflow against the supported package.

**Required workflow:**

1. Confirm the exact supported platform and package.
2. Install and configure pg-react and pg_trickle.
3. Run `pgreact.doctor()` and show expected healthy output.
4. Create a small authoritative application table fixture.
5. Create a condition view.
6. Create an optional typed PostgreSQL consequence.
7. Build a canonical declaration with `pgreact.rule()`.
8. Run `pgreact.validate()`.
9. Run `pgreact.preview()`.
10. Deploy with `pgreact.deploy()`.
11. Trigger a source change.
12. Run or observe the supported coordinator/worker path.
13. Query `pgreact.rules`, `pgreact.matches`, `pgreact.work`, and `pgreact.attempts` as appropriate.
14. Use `pgreact.explain()`.
15. Clean up using the public removal operation.

**Required qualities:**

- Copy/paste executable.
- No internal UUID discovery in the common path.
- No private schemas.
- Expected result snippets after important steps.
- Explicit note that external effects are at least once.
- Links to deeper authoring, security, and operations guides.

**Acceptance criteria:**

- The entire guide runs in CI against the exact packaged RC.
- An independent PostgreSQL user can finish without undocumented setup.

### 5.3 `docs/concepts.md` — Product mental model

**Purpose:** Explain pg-react as a system rather than as a list of functions.

**Required sections:**

- Authoritative facts.
- Condition views and incremental maintenance.
- Semantic keys and stable identity.
- Current matches.
- Activations, generations, and revisions.
- Constraint rules and command rules.
- Derived facts and support, at the actual v1 boundary.
- Decision candidates, winners, ambiguity, and result state.
- Policy sets and applicability.
- Durable work, attempts, leases, retries, and consequences.
- Database-local effects versus external outbox delivery.
- Explanations and bounded evidence.
- Deployment-impact comparison:
  - current;
  - proposed;
  - delta;
  - lifecycle;
  - would-be work;
  - no-effect boundary.
- Recovery and reconciliation.
- Clear v1 exclusions.

**Acceptance criteria:**

- Every major noun used by the API reference is defined here or linked to a definition.
- The guide does not require implementation-specific catalog knowledge.

### 5.4 `docs/changing-policies.md` — Flagship M34/v1 guide

**Purpose:** Teach the capability that makes M34 a compelling v1 boundary.

**Primary user question:**

> I have a deployed rule, decision, or policy set. How do I see the impact of a proposed replacement before I deploy it?

**Required sections:**

#### The safe-change workflow

```text
write proposal
  -> validate
  -> preview declaration
  -> compare with deployed target
  -> inspect complete/partial evidence
  -> review would-be lifecycle and work
  -> deploy intentionally
  -> verify production state
```

#### Building the comparison

- Creating a proposed canonical declaration.
- Selecting a deployed target with a stable typed identity.
- Choosing `evidence_limit`.
- Using `sampled_time` correctly.
- Required source visibility and authorization.

#### Reading the result

Explain every result set and field:

- `current`;
- `proposed`;
- `delta`;
- `lifecycle`;
- `work`;
- summary counts;
- declaration digest;
- source frontier;
- sampled time;
- applicability snapshot;
- cost evidence;
- before/after authoritative checksums;
- complete versus partial evidence.

Explain all delta states:

- `ADDED`;
- `REMOVED`;
- `CHANGED`;
- `UNCHANGED`.

#### Relational inspection

Show `pgreact.compare_results()` used with:

- filtering;
- joins to application tables;
- aggregation;
- ordering;
- reviewer-friendly reports.

#### Three complete examples

1. **Rule replacement:** threshold change that adds and removes matches.
2. **Decision change:** candidate priority or result change affecting winners and ambiguity.
3. **Policy-set change:** applicability or membership change affecting eligible subjects.

Each example should show:

- deployed declaration;
- proposed source/declaration;
- comparison call;
- expected result rows;
- evidence and cost interpretation;
- deployment call;
- post-deployment verification.

#### Safety and failure behavior

- Comparison is read-only.
- No deployment is created.
- No match, activation, work, attempt, delivery, or frontier state is mutated.
- No consequence runs.
- Unsupported kinds fail closed.
- Protected or unauthorized sources fail without leaking evidence.
- A changed authoritative checksum aborts instead of returning a stale answer.
- Partial evidence is never presented as complete.

#### What comparison does not do

State explicitly:

- no hypothetical fact inserts, updates, or deletes;
- no historical replay;
- no backtesting;
- no automatic approval or promotion;
- no effect execution;
- no exactly-once delivery prediction.

**Acceptance criteria:**

- The guide runs against the packaged RC.
- It demonstrates the no-mutation checksum.
- It covers rule, decision, and policy-set comparisons.
- A reviewer can determine whether output is complete.

### 5.5 `docs/v1-api-reference.md` — Human-readable public reference

**Purpose:** Provide one authoritative, searchable reference for the public v1 SQL surface.

**Required structure:**

- Ordinary API.
- Public views.
- Declaration types and fields.
- Result envelopes.
- Comparison API.
- Finding model and links to the machine-readable code inventory.
- Advanced/administrative API.
- Compatibility API.
- Role/privilege requirements.
- Transaction and volatility behavior where relevant.
- Errors, limits, and examples.

At minimum, document the ordinary functions frozen by the v1 contract:

```text
pgreact.rule
pgreact.decision
pgreact.policy_set
pgreact.validate
pgreact.preview
pgreact.deploy
pgreact.remove
pgreact.run
pgreact.status
pgreact.explain
pgreact.doctor
pgreact.compare
pgreact.compare_results
```

At minimum, document the required public views:

```text
pgreact.rules
pgreact.matches
pgreact.decisions
pgreact.policy_sets
pgreact.work
pgreact.attempts
pgreact.health
```

**Generation requirement:**

- Generate or verify signatures, argument names, defaults, types, result columns, and grants from the installed artifact.
- Fail CI when the hand-written reference and machine inventory disagree.

### 5.6 `docs/v1-known-limitations.md` — Honest product boundary

**Purpose:** Put all major user-visible limits in one place instead of scattering them across milestone notes.

**Required content:**

- Exact supported PostgreSQL/pg_trickle/pgrx/OS/architecture tuple.
- Supported maintenance and isolation mode.
- RLS restrictions.
- Key-type and declaration limits.
- Worker/coordinator limits.
- Evidence and result limits.
- Retention behavior.
- Recovery boundaries.
- At-least-once external delivery.
- No global ordering promise.
- No arbitrary untrusted dynamic code.
- No hypothetical facts in v1.
- No historical replay or backtesting in v1.
- No workflow/BPM/human-task platform claims.
- No general base-tuple lineage claim.

**Acceptance criteria:**

- Every material limitation mentioned in M33 or M34 user-facing notes appears here.
- Release notes and README link to this page.

### 5.7 `docs/1.0-release-notes.md` — Actual v1 release note

**Purpose:** Explain the v1 product to users and distinguish GA stability from milestone history.

**Required sections:**

- What pg-react 1.0 is.
- Why the project considers the contract stable.
- Headline capabilities.
- M34 deployment-impact comparison as the key safe-change capability.
- Supported environment.
- Upgrade paths.
- Compatibility commitment for `1.x`.
- Known limitations.
- Security and recovery posture.
- External delivery guarantee.
- Links to installation, getting started, changing policies, API reference, and upgrade instructions.

If `1.0.0` contains no runtime feature changes after `0.31.0`, say so directly:

> `1.0.0` promotes the qualified M34 feature set and frozen core contract; the RC cycle is for packaged-artifact, documentation, usability, upgrade, recovery, security, and performance qualification rather than new functionality.

### 5.8 `docs/history.md` — Milestone and historical documentation index

**Purpose:** Preserve transparency without making historical evidence look like current instructions.

**Required content:**

- Explain the difference between user docs, normative contract docs, and milestone evidence.
- Link M0–M34 evidence by milestone.
- Identify obsolete historical API guides.
- Warn users not to copy old SQL without checking the current API reference.
- Link historical release notes and upgrade records.

### 5.9 Executable example set

Create a small, curated example directory, such as:

```text
docs/examples/README.md
docs/examples/first-rule.sql
docs/examples/change-rule-safely.sql
docs/examples/decision-comparison.sql
docs/examples/policy-set-comparison.sql
docs/examples/operations-smoke.sql
```

Each example should:

- use only supported public APIs;
- include setup and cleanup;
- be idempotent or run in an isolated database;
- assert important expected outputs;
- run in CI against the packaged RC.

## 6. Existing documents to update

### 6.1 `README.md`

**Required changes:**

- Replace the statement that M35 is required before RC.
- Present `0.31.0` as the qualified input to the v1 RC cycle.
- Link to the new documentation index and getting-started guide.
- Add a visible “Compare before deploying” example or link.
- Keep the first-rule workflow short; move detailed explanations into guides.
- State the exact support boundary briefly and link to the support matrix.
- State that hypothetical fact simulation is not included in v1.
- Ensure worker/runtime language matches the installation guide.
- Remove or qualify stale tag/version statements.

### 6.2 `ROADMAP.md`

Although it is not a normal user guide, it controls release expectations and must not contradict the release.

**Required changes:**

- Amend M34 so its successful `0.31.0` release qualifies the project to begin `1.0.0-rc.1`.
- Move M35 into the post-v1 sequence.
- Change the required release sequence accordingly.
- Preserve M35 as a future capability without implying it is part of v1.
- Update the final RC cycle to require comparison no-effect qualification, not hypothetical-fact qualification.

### 6.3 `docs/v1-contract.md`

**Required changes:**

- State that the v1 contract consists of the M33 core plus the additive M34 comparison surface.
- Add `pgreact.compare` and `pgreact.compare_results` to the frozen ordinary API.
- Add comparison inputs, result sets, completeness metadata, and no-effect commitments.
- Change candidate/version statements from `0.30.0` to the M34/`0.31.0` boundary.
- Clarify which comparison fields are stable in `1.x`.
- State that hypothetical fact simulation is not part of the v1 contract.

### 6.4 `docs/v1-authoring.md`

This requires a substantial rewrite rather than patching isolated lines.

**Required changes:**

- Replace the legacy create/validate/preview functions with the ordinary declaration workflow.
- Explain `pgreact.rule()`, `pgreact.decision()`, and `pgreact.policy_set()`.
- Explain validation, preview, deployment, immutable versions, replacement, removal, and explanation.
- Use typed identities and stable names.
- Explain semantic keys and watched/change columns.
- Explain consequences and idempotency.
- Link safe replacement to `changing-policies.md`.
- Move old APIs to a compatibility appendix.
- Remove obsolete version and capability claims.

### 6.5 `docs/v1-installation.md`

**Required changes:**

- Rewrite for the PostgreSQL-managed coordinator and worker.
- Include exact `shared_preload_libraries` requirements.
- Include `pg_react.databases` and role configuration.
- State restart requirements.
- Document extension creation order.
- Document the supported OCI/package installation path by digest and checksum.
- Show `doctor()` and health verification.
- Explain the status of `pg-reactd` as a compatibility/migration tool only.
- Replace all M33/`0.30.0` expected-version text with RC/GA variables or exact release values.

### 6.6 `docs/v1-operations.md`

The current high-level table is a useful outline but not a sufficient production runbook.

**Required changes:**

- Add exact public SQL for each supported operational task.
- Document managed worker status and coordinator behavior.
- Cover backlog, attempts, retries, leases, pause/resume, replacement, drift, retention, recovery barriers, reconciliation, and removal.
- Add expected healthy/unhealthy outputs.
- Add escalation criteria: when to stop workers, when to preserve state, and when restore is required.
- Add a comparison-specific operational section covering cost limits, cancellation, partial evidence, and concurrent production activity.

### 6.7 `docs/v1-troubleshooting.md`

**Required changes:**

- Expand each common finding into symptom, likely cause, diagnostic query, safe remediation, and verification.
- Include stable finding codes.
- Cover unsupported environment, drift, blocked recovery, failed work, retry exhaustion, stale lease, applicability errors, comparison authorization failures, partial comparison output, stale-frontier/checksum aborts, and limit failures.
- Never recommend private catalog edits.

### 6.8 `docs/v1-security.md`

**Required changes:**

- Publish an exact role/privilege matrix for reader, author, deployer where distinct, operator, and worker.
- Include installation-time grant examples.
- Document comparison authorization and redaction behavior.
- Explain source ownership/readability requirements.
- Explain why RLS-protected evaluated sources are rejected.
- Document fixed search paths and exact typed function identity at a user-relevant level.
- Include a least-privilege verification checklist.

### 6.9 `docs/v1-support-matrix.md`

**Required changes:**

- Verify every version and configuration value against the packaged RC.
- Ensure preload and runtime rows match installation instructions.
- Include supported backup, PITR, standby promotion, logical restore, and container behavior.
- Distinguish supported, experimental, and unsupported clearly.
- Add comparison-specific boundaries where needed.

### 6.10 `docs/v1-limits.md`

**Required changes:**

- Replace qualitative statements with exact values or links to exact configuration defaults wherever possible.
- Explain what happens when each limit is reached.
- Include comparison evidence limits, supported maximum, partial behavior, temporary-storage behavior, and resource-cost reporting.
- Link every tunable limit to its public configuration or declaration field.

### 6.11 `docs/v1-backup-restore.md`

**Required changes:**

- Add exact preflight, restore, reconcile, and resume commands.
- Cover physical backup, PITR, restart, supported standby promotion, and logical restoration separately.
- State the external-effect boundary at every recovery type.
- Explain comparison behavior during recovery barriers and after promotion.
- Include a verification checklist covering rules, matches, decisions, policy sets, work, attempts, frontiers, and barriers.

### 6.12 `docs/v1-upgrade.md`

**Required changes:**

- Make `0.31.0 -> 1.0.0-rc.N -> 1.0.0` the primary path.
- List older paths only when release qualification actually exercises them.
- Correct the `ALTER EXTENSION` target version.
- Include package installation, checksum verification, worker stop/start, backup, health checks, reconciliation, and rollback-by-restore.
- State that upgrade must execute no business work.
- Add exact validation for the comparison API and unchanged authoritative checksums.

### 6.13 `docs/v1-compatibility.md` and `docs/v1-deprecations.md`

**Required changes:**

- Define the `1.x` compatibility policy in user-facing terms.
- State what may be added compatibly: nullable columns, optional overloads, detail fields, and new finding codes.
- State what requires a major release.
- Identify compatibility-only APIs and the earliest removal policy.
- Explain that ordinary calls and required view columns remain usable throughout `1.x`.

### 6.14 Machine-readable API and finding inventories

**Required changes:**

- Regenerate inventories from the exact RC artifact.
- Include M34 comparison functions, inputs, output result sets, stable fields, grants, and finding codes.
- Record an inventory checksum in release qualification.
- Fail the release if installed reality differs from the committed inventory.

### 6.15 M34 documents

The M34 documents should remain as release evidence, but their role should change.

**Required changes:**

- Mark them as milestone/release evidence where necessary.
- Link users from `m34-api-reference.md` and `m34-examples.md` to the new canonical comparison guide and v1 API reference.
- Remove the claim that M35 is required before RC from M34 release notes and readiness material.
- Preserve the M34 no-effect and correctness evidence.

### 6.16 Historical `v1-*` files

Files that are actually historical M4 records, such as the current `v1-release-notes.md` and `v1-upgrades.md`, need explicit handling.

Preferred approach:

1. Move the historical content under an unmistakable history path while preserving Git history.
2. Leave a short pointer at the old path if external links are likely.
3. Do not link historical files from the end-user documentation index.

Fallback approach when immutability rules prohibit movement:

- Keep the files unchanged.
- Add strong history labels where permitted.
- Exclude them from user navigation.
- Ensure the real v1 release notes and upgrade guide have unambiguous names.

## 7. M34 comparison documentation requirements in detail

Because M34 is the proposed v1 boundary, its documentation quality should be treated as a release-defining requirement rather than an optional feature note.

### 7.1 Use the term “comparison” in normal user guidance

“Deployment-impact simulation” is accurate roadmap language, but ordinary documentation should lead with the simpler task:

> Compare a proposed policy with the deployed policy before changing production.

Use “simulation” only when explaining the read-only execution boundary. This reduces confusion with M35 hypothetical fact simulation.

### 7.2 Show both envelope and relational interfaces

Document when to use:

- `pgreact.compare()` for one structured review envelope;
- `pgreact.compare_results()` for SQL filtering, joins, aggregation, reports, and review tooling.

### 7.3 Teach completeness, not just deltas

A user must be able to distinguish:

- complete comparison with exact counts;
- bounded evidence with explicit partial/truncated state;
- unsupported or unavailable evidence;
- an aborted comparison caused by stale or changed authoritative state.

Every example should show where completeness is reported.

### 7.4 Teach no-effect evidence

The comparison guide should show the before/after checksum or equivalent public evidence proving that comparison did not change authoritative state.

It should explicitly state that comparison creates none of the following:

- deployments;
- matches;
- activations;
- lifecycle history;
- durable work;
- attempts;
- consequence calls;
- outbox deliveries;
- frontier advancement.

### 7.5 Explain cost evidence

Document the public fields for:

- rows considered;
- affected subjects;
- dependency fan-out;
- reevaluation;
- cascade depth;
- would-be work;
- elapsed time;
- memory;
- temporary storage.

Explain that comparison cost is evidence about the comparison workload, not a promise of exact deployed execution cost.

### 7.6 Cover concurrency and snapshot identity

Explain:

- what source frontier was used;
- what sampled time was used;
- how applicability is fixed;
- what happens if production state changes during comparison;
- how deterministic repetition is defined.

### 7.7 Cover authorization and redaction

Show which roles may compare, what source permissions are required, and how protected evidence is denied or redacted. Failure examples should use stable finding codes and must not reveal protected subjects or values.

### 7.8 Avoid implying M35

Do not use examples such as “pretend this row was inserted” or “change an account balance only for the comparison.” In v1, comparison changes the declaration, not the facts.

Use this explicit distinction:

```text
v1 comparison:
  current facts + deployed declaration
  versus
  current facts + proposed declaration

not in v1:
  current facts
  versus
  hypothetical changed facts
```

## 8. Terminology and style guide

The documentation should adopt a small controlled vocabulary.

### Preferred terms

- **authoritative facts:** source data PostgreSQL currently owns;
- **condition:** a relational statement of what is true;
- **semantic key:** stable logical identity for a match or subject;
- **declaration:** typed proposed or deployed policy definition;
- **deployed target:** stable named production policy version selected for comparison;
- **current:** deployed behavior over the selected current snapshot;
- **proposed:** candidate behavior over that same snapshot;
- **delta:** added, removed, changed, or unchanged behavior;
- **would-be work:** work a deployment would request, but comparison does not create;
- **complete / partial:** whether bounded evidence covers the full result;
- **finding:** stable structured diagnostic;
- **authoritative frontier:** the committed source/evaluation point used by the operation.

### Terms to avoid in ordinary paths

- private catalog table names;
- internal UUIDs when a stable name is accepted;
- milestone numbers as feature names;
- “exactly once” for external delivery;
- “preview” as a synonym for `compare()` when the APIs have different purposes;
- “simulation” without specifying whether policy or facts are being varied;
- “workflow engine,” “BPM,” or “application framework.”

### Example conventions

- Schema-qualify objects.
- Use named function arguments in long declarations.
- Use deterministic ordering in result queries.
- Include setup and cleanup.
- Show expected rows or summarized output.
- Mark intentional failures clearly.
- Avoid ellipses in the primary runnable example.
- Use the same example domain across README, getting started, authoring, and comparison where practical.

## 9. Documentation testing and automation

Documentation qualification should be an explicit release gate.

### 9.1 Packaged-artifact execution

Run documentation examples against the exact `1.0.0-rc.N` package or OCI image, not a development checkout with uninstalled SQL.

### 9.2 SQL example tests

Add a test lane such as:

```text
tests/docs-v1.sh
tests/docs/getting-started.sql
tests/docs/changing-rule.sql
tests/docs/changing-decision.sql
tests/docs/changing-policy-set.sql
tests/docs/operations.sql
```

The tests should verify:

- successful outputs;
- stable finding codes for intentional failures;
- no private schema use;
- no undocumented prerequisite;
- authoritative checksum unchanged after comparison;
- exact or explicitly partial evidence as expected.

### 9.3 Link checking

CI should reject:

- broken relative links;
- links from current user docs to obsolete historical instructions without a history label;
- missing anchors in API/reference pages.

### 9.4 Version consistency lint

CI should scan current docs for stale release statements, including:

- `0.30.0` described as the current candidate;
- M35 described as a v1 prerequisite;
- `ALTER EXTENSION ... TO '0.30.0'` in current upgrade instructions;
- `pg-reactd` described as the ordinary v1 runtime;
- old API names presented as the preferred interface.

Historical directories or explicitly labeled files may be excluded from this lint.

### 9.5 API symbol lint

Compare code spans and SQL calls in current docs with the installed public API inventory. Fail on unknown or removed ordinary symbols unless the example is explicitly marked compatibility-only.

### 9.6 Private-surface lint

Reject ordinary examples that query or update private schemas. Allow private names only in statements explaining that they are unsupported.

### 9.7 Support-matrix consistency

Verify that the same PostgreSQL, pg_trickle, pgrx, operating-system, architecture, preload, isolation, maintenance, runtime, RLS, and recovery values appear in:

- README;
- installation guide;
- support matrix;
- contract;
- release notes;
- container/package metadata.

### 9.8 Documentation inventory

Publish a small machine-readable list of current end-user documents and their qualification status. This prevents an obsolete page from being accidentally promoted into primary navigation.

## 10. Usability qualification

Documentation should be tested with users who did not implement the feature.

### Required personas and tasks

#### PostgreSQL developer

- Identify whether the environment is supported.
- Install the package.
- Create and inspect the first rule.
- Explain one activation.

#### Policy author

- Create a proposed replacement.
- Validate and preview it.
- Compare it with the deployed target.
- Identify added, removed, and changed subjects.
- Determine whether evidence is complete.

#### Reviewer or auditor

- Use relational comparison output.
- Trace a reported delta to bounded evidence.
- Confirm no authoritative mutation occurred.
- Identify would-be work without mistaking it for executed work.

#### Operator

- Diagnose unhealthy state.
- Inspect backlog and failed attempts.
- Perform a documented repair or recovery step.
- Upgrade `0.31.0` to the RC without executing business work.

#### Security administrator

- Create least-privilege roles and grants.
- Verify `PUBLIC` has no unintended authority.
- Confirm an unauthorized comparison fails without leaking protected data.

### Completion criteria

- Tasks are completed using only README and current end-user docs.
- No participant needs a milestone contract, test script, private catalog, or undocumented maintainer help.
- Every confusion that indicates an API or semantic ambiguity is resolved before GA or recorded as a known limitation.

## 11. Work sequence

The documentation work should proceed in dependency order.

### Phase 1: Confirm the release contract

- Decide formally that M34 is the v1 boundary.
- Amend the roadmap and release sequence.
- Freeze exact API names, view columns, result fields, finding codes, support tuple, worker model, and upgrade paths.

Do not rewrite all guides before this is complete; otherwise documentation churn will conceal unresolved contract decisions.

### Phase 2: Remove contradictions

Update the README, v1 contract, authoring guide, installation guide, support matrix, upgrade guide, M34 release notes, and versioning language. This is the minimum consistency baseline.

### Phase 3: Create the user journey

Create the docs index, getting-started guide, concepts guide, changing-policies guide, real v1 release note, known-limitations page, and human-readable API reference.

### Phase 4: Complete operations and safety documentation

Expand security, operations, troubleshooting, limits, backup/restore, compatibility, deprecations, and migration guidance.

### Phase 5: Make documentation executable

Add SQL fixtures, link checking, version linting, API inventory checks, private-surface checks, and packaged-artifact execution.

### Phase 6: Run independent usability qualification

Test the author, reviewer, operator, and security tasks. Fix documentation and any API rough edges discovered before the first final candidate.

### Phase 7: Qualify the exact RC documentation set

Freeze the documentation commit with the packaged RC. Any change to normative docs, SQL examples, packaging instructions, support claims, or compatibility promises should trigger the affected qualification lanes and, where required, a new RC number.

## 12. Priority matrix

### P0 — Required before `1.0.0-rc.1`

- Formal roadmap change making M34 the v1 boundary.
- README release-boundary and navigation update.
- `docs/index.md`.
- `docs/getting-started.md`.
- Complete rewrite of `docs/v1-authoring.md`.
- Complete rewrite of `docs/v1-installation.md`.
- `docs/changing-policies.md`.
- Updated `docs/v1-contract.md` including M34.
- Updated `docs/v1-upgrade.md` with correct target versions.
- Human-readable `docs/v1-api-reference.md`.
- Regenerated API and finding inventories.
- `docs/v1-known-limitations.md`.
- Actual `docs/1.0-release-notes.md`.
- Removal of M35-as-RC-prerequisite statements.
- Executable first-rule and comparison documentation tests.
- Version/API/link consistency CI.

### P1 — Required before `1.0.0` GA

- `docs/concepts.md`.
- Expanded operations, troubleshooting, security, limits, backup/restore, compatibility, and deprecation guides.
- Rule, decision, and policy-set comparison examples.
- History index and de-emphasis of obsolete pages.
- Independent usability qualification for all required personas.
- Final support-matrix and upgrade-path verification against the exact GA candidate.
- Final known-limitations and release-note review.

### P2 — Valuable but not required to define v1

- A hosted documentation site with version switching.
- Translations.
- Client-language tutorials.
- Visual policy authoring guides.
- M35 hypothetical-fact tutorials.
- Historical replay or backtesting documentation.
- Extensive domain-specific cookbooks.

P2 work must not delay v1 unless it uncovers a correctness, security, or support-contract problem.

## 13. Release documentation gates

The v1 release should not promote until all of the following are true.

- [ ] README and roadmap agree that M34 is the v1 boundary.
- [ ] No current user guide says M35 is required for v1.
- [ ] No current ordinary example teaches a legacy API as the default.
- [ ] Installation, support matrix, and README describe the same managed runtime.
- [ ] The first-rule guide executes against the exact packaged candidate.
- [ ] Rule, decision, and policy-set comparison guides execute against the exact packaged candidate.
- [ ] Comparison examples prove authoritative state is unchanged.
- [ ] Partial evidence is shown and explained correctly.
- [ ] Unauthorized comparison examples fail without protected-data leakage.
- [ ] The human-readable API reference matches the installed API inventory.
- [ ] Stable finding codes in documentation match the installed finding inventory.
- [ ] Upgrade instructions target the actual RC/GA version.
- [ ] Qualified upgrade paths are exactly the paths documented as supported.
- [ ] All current documentation links resolve.
- [ ] Current user docs contain no private-catalog repair instructions.
- [ ] Support claims are identical across contract, installation, support matrix, and release notes.
- [ ] External effects are consistently described as at least once.
- [ ] Known limitations include the absence of hypothetical facts and historical replay.
- [ ] Independent users complete the required author, reviewer, operator, and security tasks.
- [ ] The exact RC documentation set is archived with the release artifact and checksums.

## 14. Definition of done

The documentation effort is complete when pg-react can be evaluated, installed, learned, changed safely, operated, and upgraded using one consistent set of current documents, without reading milestone evidence or guessing which API generation is current.

Concretely, a new PostgreSQL user must be able to follow this path:

```text
README
  -> documentation index
  -> supported environment
  -> installation
  -> first rule
  -> inspect and explain
  -> propose a policy change
  -> compare current vs proposed behavior
  -> assess complete/partial evidence and would-be work
  -> deploy intentionally
  -> verify production state
  -> operate, recover, and upgrade through public APIs
```

At the same time, an auditor or maintainer must still be able to trace the release to its M0–M34 contracts, evidence, inventories, checksums, and readiness records.

That combination—simple current guidance for users and preserved detailed evidence for maintainers—is the appropriate documentation standard for a credible pg-react `1.0.0` release after M34.

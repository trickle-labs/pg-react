# pg-react roadmap

> **Status:** Living delivery plan  
> **Last updated:** 2026-08-09\
> **Design authority:** [`DESIGN.md`](DESIGN.md) defines product semantics. This file defines delivery order, release scope, and evidence required to ship.

**Long-term direction:** `pg-react` is intended to evolve from a durable PostgreSQL-native production-rule runtime into a PostgreSQL-native rule and incremental reasoning engine. Later releases may add maintained logical derivation, provenance, monotone recursion, carefully bounded non-monotonic reasoning, and temporal semantics. Each new semantic capability must keep PostgreSQL authoritative and enter a numbered milestone only when it has a coherent correctness, recovery, security, and explanation contract.

`pg-react` should become the easiest safe way to turn changing PostgreSQL data into durable, inspectable decisions and work. The roadmap is therefore organized around two outcomes:

1. **Easy to use:** rules are authored with ordinary PostgreSQL views and typed functions, safe defaults handle the common case, errors explain how to recover, and normal operation never requires direct access to private catalogs.
2. **Solid:** lifecycle events are deterministic, work is durable, concurrency and retries are explicit, external effects are honest about their guarantees, and upgrades, crashes, restores, and rebuilds do not silently lose or duplicate business work.

The stages below are **evidence gates, not calendar promises**. Parallel work is encouraged, but a later release must not ship before the earlier correctness gates are satisfied. Calendar commitments should be made only after the feasibility stage establishes the required `pg_trickle` integration contract.

---

## Product success criteria

A successful v1 lets a PostgreSQL developer:

1. Define a condition with a normal view.
2. Define an optional consequence with a typed PostgreSQL function or registered transactional outbox sink.
3. Register the rule with one `pgreact.create_rule` call.
4. Inspect current matches, lifecycle state, pending work, attempts, drift, and health through documented SQL views and functions.
5. Pause, replace, reconcile, retry, and recover a rule without editing internal tables.

A successful v1 lets an operator trust that:

- within one immutable rule version, one semantic key that remains continuously present creates exactly one activation generation;
- physical refresh mechanics do not create false lifecycle events;
- match state, activation state, payloads, and agenda work commit atomically;
- two workers cannot own the same lease;
- stale or invalidated work cannot execute successfully;
- database-local consequences and transactional outbox-sink enqueue are atomic with episode completion;
- external delivery is at least once and uses deterministic idempotency keys;
- reconciliation is explicit and idempotent;
- source and function drift are visible and block unsafe execution;
- recovery and upgrade procedures are tested rather than inferred.

---

## v1 GA contract

The first release should support a deliberately narrow, dependable surface.

| In v1 | Deferred until the core is proven |
|---|---|
| PostgreSQL 18 and a pinned, tested `pgrx`/`pg_trickle` compatibility tuple | Broad PostgreSQL-version support |
| PostgreSQL views as the canonical condition contract | A custom rule language or server-side DSL |
| Explicit, non-null semantic key columns | Automatic fact-tuple identity |
| Constraint and command rules | General workflow orchestration |
| `ACTIVATE`, `CHANGE`, and `DEACTIVATE` lifecycle events | Strict synchronous firing loops |
| Scheduled `DIFFERENTIAL` maintenance as the default | Broad `IMMEDIATE`-mode support before its isolation contract is proven |
| Typed PostgreSQL consequence functions | Arbitrary remote calls inside PostgreSQL backends |
| Registered transactional outbox sink for external effects, with a `pg_tide` adapter | A second pg-react-owned relay or claims of global exactly-once delivery |
| One episode per transaction with a fresh eligibility check | General unchecked batching |
| Immutable rule versions, source snapshots, and drift detection | Mutable deployed rule definitions |
| PostgreSQL as the only authoritative state store | Worker-local durable offsets or a second truth store |

Any expansion of this contract requires its own compatibility, correctness, recovery, and performance evidence.

## Project fit boundary

**Good fit:** PostgreSQL holds the authoritative facts; conditions are relational; actions may occur asynchronously after commit; and durable, SQL-visible lifecycle state matters.

**Poor fit:** the source write must wait for the action; one global total order is required; several systems must commit atomically; the workload is warehouse-scale distributed processing; the primary abstraction is a long-running human workflow; or arbitrary untrusted code must execute dynamically. A future synchronous mode, if pursued, remains a narrowly restricted database-local fixed-point facility rather than a general workflow engine.

---

## Workstreams that run throughout

These are not late-stage cleanup tasks. Each release stage advances all of them.

| Workstream | Continuing responsibility |
|---|---|
| **Semantics and correctness** | Identity, transition planning, refraction, atomicity, reconciliation, concurrency, and property testing |
| **Developer experience** | Small SQL API, safe defaults, exact validation, actionable errors, examples, and explainability |
| **Operations** | Health checks, metrics, retention, backups, restore, failover, upgrades, and runbooks |
| **Security** | Ownership, privileges, execution roles, exact function identity, safe `SECURITY DEFINER` usage, and sensitive payload handling |
| **Performance** | Delta-proportional lifecycle work, catalog growth, agenda throughput, payload storage, and regression budgets |
| **Compatibility** | A single adapter around `pg_trickle`, isolated PostgreSQL-major-sensitive code, and a published support matrix |
| **Documentation** | One canonical end-to-end example, task-oriented guides, policy explanations, and troubleshooting procedures |

---

## Stage 0 — Feasibility and walking skeleton

**Outcome:** prove the architecture before committing to the full public API.

**Entry gate:** none. M0 is the only implementation work authorized by this roadmap until its exit and decision gates pass.

### Fixed M0 contract

- One reference command rule with one non-null `bigint` semantic key and one `ACTIVATE` consequence.
- Scheduled, explicitly selected `DIFFERENTIAL` maintenance under `READ COMMITTED` against one exact `pg_trickle` source revision; `AUTO`, `FULL`, `IMMEDIATE`, adaptive fallback, and other maintenance actions are rejected or claim-barriered.
- The trigger/deferred-finalizer path is a disposable experiment. It is not an alpha compatibility promise.
- One in-test executor calls the server-side execution function. M0 does not build `pg-reactd` or freeze a public worker protocol.
- Reconciliation is claim-barriered `STATE_ONLY`; bootstrap is `SEED_CURRENT` or `REQUIRE_EMPTY`. Neither path emits historical command work.
- Activation payloads are immutable rising-edge snapshots.
- No `CHANGE` events, `DEACTIVATE` consequences or episodes, automatic retry, outbox, raw-query authoring, live replacement, custom execution role, or RLS-protected source is in scope. M0 still records the state-closing `DEACTIVATE` ledger event required for correct reactivation generations.
- The in-test consequence runs as the rule owner through the same lease checks and binding-specific, fixed-search-path `SECURITY DEFINER` dispatcher intended for M1. A shared binding lock spans fingerprint verification and invocation; conflicting DDL takes the exclusive lock. The design never attempts `SET ROLE` inside a security-definer function.

The first implementation must be a narrow end-to-end path, not a collection of disconnected subsystems:

```text
source transaction
  -> pg_trickle refresh
  -> final semantic match delta
  -> activation transition
  -> durable lifecycle event
  -> durable agenda episode
  -> one typed PostgreSQL consequence
  -> inspectable completion history
```

### Deliverables

- Buildable Rust workspace with a `pgrx` extension skeleton and an in-test episode executor.
- Reproducible PostgreSQL 18 development and CI environment pinning the exact `pg_trickle` version and source revision, `pgrx` version, required GUCs, and isolation level.
- A documented, versioned `pg_trickle` integration boundary owned by one adapter module.
- A trigger-based experiment plus the proposed synchronous critical refresh-observer contract, both tested against final semantic state.
- A pure lifecycle transition planner for activation generations and coalescing of physical delete-plus-insert maintenance.
- Versioned canonical-key codec v1 for non-null `bigint`, using no local OIDs and retaining canonical bytes plus the complete digest.
- A minimal catalog containing immutable rule identity, current activation state, a permanent lifecycle-event uniqueness ledger, one agenda state path, and execution history.
- A pre-refresh durable `REFRESHING` barrier committed while an exclusive session-level rule lock blocks claims' shared transaction-level lock; success clears it only after lifecycle commit, while failure or disconnect leaves it in place.
- One reference rule using `ACTIVATE` and a typed database-local consequence.
- Seed-replayable property and integration harnesses with a simple reference-state oracle.

### Exit gates

- Rollback produces no committed activation or work.
- Restart preserves committed lifecycle and agenda state.
- Concurrent transactions changing opposite sides of a join do not silently miss or duplicate the semantic transition.
- A physical delete-plus-insert that leaves the same semantic key present does not create a false deactivation and reactivation.
- A true delete followed by reinsertion records the generation-1 deactivation, creates generation 2, and schedules a second `ACTIVATE` episode without creating a deactivation episode.
- A null or duplicate key introduced after registration aborts refresh without partial lifecycle work; claims remain barred until correction and successful repair.
- Claims cannot pass between pre-refresh barrier creation, refresh commit or rollback, and post-success barrier clearing; driver disconnect leaves the committed barrier in place. If the pinned integration cannot prove this ordering, M0 records a negative result.
- `STATE_ONLY` reconciliation runs behind a claim barrier, is idempotent, emits no command work, and reaches the same current activation state as equivalent differential maintenance.
- The typed consequence and episode completion commit atomically.
- Concurrent `CREATE OR REPLACE`, `ALTER`, or `DROP` cannot change the consequence or dispatcher between verification and invocation.
- Canonical key and activation-ID fixtures survive restart and logical dump/restore unchanged.
- The same deterministic property-test seed reproduces the same physical history and reference outcome.

### Decision gate

If `pg_trickle` cannot provide a sound observation boundary, the project must explicitly choose one of the following before continuing:

1. implement the required public observer API upstream;
2. restrict pg-react to a smaller, proven maintenance subset;
3. redesign the integration boundary; or
4. pause the command-rule implementation.

A trigger-only approximation must not silently become the production contract. M0 may complete with a documented negative result, but no further implementation milestone begins until this roadmap is explicitly amended or option 1, 2, or 3 yields a sound, tested final-state boundary.

### M0 decision record — 2026-08-09

M0 selects option 2: restrict command rules to the tested coordinator-owned subset. The coordinator commits `REFRESHING` while holding the exclusive session lock, invokes one explicit `DIFFERENTIAL` refresh under `READ COMMITTED`, lets the pinned deferred finalizer commit lifecycle and agenda state in that refresh transaction, commits barrier removal while still holding the lock, and only then releases it. `tests/m0.sh` proves rollback, final-state coalescing, key-invariant failure, refresh and reconciliation claim exclusion, consequence/DDL serialization, restart, and logical-restore fixtures against pg_trickle 0.81.0 at `ba41c9c2e2bbf2195917fcdcc89efa8ab3089dcb`.

This is the sound deliberately smaller boundary required to begin M1. It does not approve command refreshes initiated by pg_trickle's automatic scheduler, `AUTO`, `FULL`, `IMMEDIATE`, early `SET CONSTRAINTS`, or any uncoordinated caller. M1 must keep those paths claim-barriered or rejected and must put the proven protocol behind the first `pg-reactd`. A public critical observer can replace this restriction only after equivalent executable gates pass.

---

## Stage 1 — Developer alpha: a small useful rule engine

**Outcome:** deliver the smallest release that users can understand, install, and use for real PostgreSQL-local rules.

**Entry gate:** every M0 exit gate passes; the coordinator-owned command observation boundary in the M0 decision record is used; the exact compatibility tuple is pinned; and the alpha decisions listed below are closed in `DESIGN.md` and executable fixtures. Automatic pg_trickle scheduler command refresh remains out of scope until a critical observer passes the M0 boundary gates.

### User-visible scope

- `CREATE EXTENSION pg_react` with a documented compatible `pg_trickle` installation.
- View-backed constraint rules.
- Activate-only command rules through typed PostgreSQL functions.
- Internal deactivation state and ledger events close generations; deactivation consequences and episodes remain beta scope.
- `pgreact.create_rule`, pause, resume, drained replacement, and inspect operations. Alpha replacement requires a paused rule with no pending or leased work; live cutover arrives in beta.
- Explicit semantic keys with portable versioned codecs plus registration-time and runtime non-null/uniqueness enforcement.
- Immutable versions, source snapshots, row signatures, and source drift reporting.
- Built-in condition functions, operators, casts, types, and deterministic collations covered by the pinned suite; user-defined executable condition dependencies are deferred until their DDL race is solved.
- Generated current-match views and stable public inspection views.
- Deterministic activation IDs and one activation generation per continuous truth interval.
- `SEED_CURRENT`/`REQUIRE_EMPTY` bootstrap and claim-barriered `STATE_ONLY` reconciliation. `FIRE_CURRENT` and event-emitting reconciliation remain beta features.
- `pgreact.validate_rule` and `pgreact.preview_rule` before durable deployment.
- `pgreact.explain_rule`, `pgreact.explain_activation`, `pgreact.explain_episode`, and `pgreact.health_check` with practical remediation hints.
- A minimal worker that claims one episode, uses a finite lease and one durable attempt row, executes one episode per transaction, and performs a fresh pre-execution check. It has no automatic retry or heartbeat; expired work is swept back to pending and failures require an audited manual requeue.
- Alpha removal drains executable work before dropping generated match/payload artifacts and retains the compact lifecycle-event ledger and audit history. Automated pruning is deferred, so alpha is not approved for unbounded production retention.
- Scale smoke workloads for one rule with many matches, many rules with few matches, no-change refreshes, activation bursts, repeated replacement, and payload growth.

### Usability requirements

- The canonical example remains a three-step workflow: create a view, create a typed function, register the rule.
- The common command path requires only name, definition, semantic key, and activation consequence; advanced lifecycle and scheduling policy remains optional.
- Common configuration has safe defaults; policies that can create surprising work require an explicit choice.
- Preflight reports maintenance support, key-codec problems, consequence compatibility, expected refresh mode, dependencies, generated objects, and bootstrap warnings. Watched-column and external-effect diagnostics arrive with those features.
- Validation errors name the rule, object, invalid property, and corrective action.
- Users do not need to query or update `pgreact_internal`.
- The README example is executable in CI as documentation-as-test.

### Exit gates

- A new user can complete the reference example using only public documentation and public SQL APIs.
- Registration rejects non-view definitions, null or duplicate semantic keys, unsupported key codecs, incompatible typed signatures, unsafe roles, RLS-protected sources, and unsupported query capabilities before activation.
- A later null or duplicate semantic key aborts refresh, commits no partial lifecycle work, appears in health output, and blocks claims until corrected.
- Replacing or dropping a source view or consequence function produces visible drift or invalidation rather than ambiguous dispatch.
- Alpha security tests prove owner authorization, exact function dispatch, binding-lock serialization against DDL, fixed safe `search_path` for extension `SECURITY DEFINER` code, no ordinary access to private catalogs or payloads, and rejection of RLS-protected sources.
- Restart and worker-death tests prove lease recovery, atomic consequence completion, inspectable failure, and audited manual requeue without lost committed work.
- Property tests cover long insert, update, delete, delete-plus-insert, rebuild, and reconciliation histories.
- Scale smoke tests publish baselines and reveal architectural cliffs before storage and catalog layouts harden; final release budgets are not required yet.
- Constraint and activate-only command rules can be installed, explained, paused, resumed, replaced after draining, and removed cleanly.

---

## Stage 2 — Reliability beta: complete lifecycle and durable execution

**Outcome:** make command rules dependable under concurrency, retries, crashes, and changing source data.

**Entry gate:** every M1 exit gate passes and every pre-beta decision below is normative in the design and covered by planned tests.

### Deliverables

- Complete `ACTIVATE`, `CHANGE`, and `DEACTIVATE` lifecycle support.
- Activation generations and change revisions with deterministic event identities.
- Normative watched-column comparison using PostgreSQL equality semantics, with explicit schema-change behavior.
- Typed old/new event payloads and stable `pgreact.activation_context`.
- Durable agenda states, claims, leases, heartbeats, expiry, retry backoff, cancellation, withdrawal, skip, completion, and terminal failure.
- Salience, agenda groups, conflict keys, and deterministic claim ordering within the documented scope.
- Independent pre-execution eligibility, source-fingerprint, function-fingerprint, lease, and conflict checks.
- Blue/green replacement implementing the design's cutover matrix for active, pending, retrying, and leased work.
- Transactional outbox-sink contract with deterministic idempotency keys, a stable event envelope, replay behavior, a normative consumer contract, and a `pg_tide` adapter. Core pg-react owns no relay or duplicate delivery-state table.
- Execution-attempt and reconciliation-audit history plus operator APIs for retry, cancel, reconcile, and lease repair.
- Stateless, horizontally scalable `pg-reactd` with polling as the authority and `LISTEN/NOTIFY` only as a wake-up hint.
- Feedback-loop limits and diagnostics for rules whose consequences change their own source facts.

### Exit gates

- Two workers cannot successfully own or complete the same lease.
- A stale worker cannot complete work after lease reclamation.
- A worker may claim episodes A and B, execute A, have A invalidate B, and then skip or withdraw B during B's fresh recheck.
- Database consequence execution and episode completion are atomic.
- Outbox-sink enqueue and episode completion are atomic; duplicate delivery, replay, and out-of-order retry tests exercise the adapter and consumer contract.
- Crash injection covers refresh rollback, server restart, worker death around consequence commit, ambiguous disconnects, lease expiry races, and outbox-sink enqueue ambiguity.
- Replacement races prove that old work dispatches only through its exact old binding or is rejected according to the declared cutover policy.
- No committed work is silently lost in the supported failure scenarios.
- Reconciliation is idempotent, respects its configured event-emission policy, and records an audit result even for state-only repair.
- All documented isolation-level combinations have tests; unsafe combinations fail explicitly.

### M2 completion record — 2026-08-09

M2 completes on the existing coordinator-owned `DIFFERENTIAL` boundary. The beta adds deterministic change revisions; immutable old/new event payloads; bounded claims, conflict leases, heartbeats, expiry recovery, retry backoff, terminal failure, cancellation, withdrawal, and stale-worker rejection; registered transactional outbox sinks; blue/green old-work policies; reconciliation audit modes; and a stateless polling worker. `tests/m2.sh` is the executable beta gate, run with the M0/M1 suites and `cargo test --no-default-features` as recorded in `docs/m2-evidence.md`.

---

## Stage 3 — Operational release candidate

**Outcome:** make pg-react supportable in a controlled production environment.

**Entry gate:** every M2 exit gate passes and the supported platform, isolation, RLS, retention, fairness, and performance decisions are closed.

### Deliverables

- Published compatibility matrix for PostgreSQL, `pgrx`, `pg_trickle`, operating systems, architectures, maintenance modes, and isolation levels.
- Stable extension migrations and rebuild procedures for transient OID-based metadata.
- Tested PITR, physical failover, and rolling worker-upgrade procedures, plus
  explicit supported/unsupported decisions for logical migration and
  PostgreSQL-major upgrade.
- Source and function drift repair workflows with explicit claim barriers.
- Documented PostgreSQL roles for administration, authoring, operation, workers, and readers.
- Security review of ownership checks, exact binding-specific dispatch, `SECURITY DEFINER` functions, search paths, generated relations, and payload access.
- An explicit RLS and evaluation-role support decision; unsupported combinations are documented and rejected where necessary.
- Retention, cleanup, vacuum, and catalog-growth controls, including audited pruning and minimum history that survives payload cleanup.
- Fairness windows, starvation prevention, claim-size bounds, agenda-group and connection budgets, overload backpressure, lock ordering, and bounded deadlock retry behavior.
- Metrics, structured logs, health endpoints, and alerts for drift, invalid bindings, reconciliation, agenda depth and oldest age, hot conflict keys, claim saturation, per-rule backlog, latency, failures, lease expiry, and outbox-sink failures; delivery state remains observable through the sink.
- Reproducible packages or images for every supported platform.
- Benchmark suite covering no-change refreshes, activation bursts, high change-event volume, many rules, repeated replacement, payload retention, reconciliation, claims, and consequence execution.
- At least one real pilot use case operated through failure, sustained load, and recovery exercises.

### Exit gates

- Restore and upgrade tests preserve active state, pending work, typed payloads, history, and deterministic identities.
- Operators can detect and remediate every supported unhealthy state through public interfaces and documented runbooks.
- Security tests prove that authors manage only authorized objects and workers invoke only enabled, exact registered consequences.
- Sustained-load tests demonstrate bounded claims, backpressure, documented fairness, no indefinite starvation, and recoverable deadlock handling.
- Performance budgets and regression thresholds are published before release-candidate sign-off.
- Lifecycle overhead scales with changed semantic activations rather than requiring scans of unrelated historical work.
- The pilot validates both rule-author usability and day-two operations.

### M3 completion record — 2026-08-09

M3 completes as extension `0.1.1` on the same coordinator-owned compatibility subset. The RC adds an executable `0.1.0 -> 0.1.1` migration, transient-OID rebuild and recovery barriers, private-by-default public-schema access, documented role grants, audited payload retention, bounded fair claims, agenda-group budgets, atomic backlog backpressure, worker protocol compatibility, SQL health/metrics, an operational runbook, a pinned platform matrix, and a 128-activation internal pilot. `tests/m3.sh` and `tests/m3-upgrade.sh`, together with the M0–M2 suites and `cargo test --no-default-features`, are the executable RC gate recorded in `docs/m3-evidence.md`.

---

## Stage 4 — v1 general availability

**Outcome:** freeze and support the first dependable public contract.

**Entry gate:** every M3 exit gate and published performance budget passes on release artifacts, not development builds.

### GA requirements

- The v1 SQL API, worker protocol, catalog migration policy, compatibility policy, and external-delivery guarantees are documented and versioned.
- Installation, authoring, operations, security, backup/restore, upgrades, and troubleshooting each have task-oriented documentation.
- The end-to-end reference example is tested against every release artifact.
- No unresolved issue can cause silent missed lifecycle events, silent duplicate lifecycle events, lost committed work, unsafe function dispatch, or unrecoverable catalog state within the supported matrix.
- Release artifacts, checksums, upgrade notes, and known limitations are published together.
- A pilot user or internal production deployment has completed installation, normal operation, failure injection, restore, and upgrade exercises.

The first GA should prefer a small, explicit support matrix over broad best-effort compatibility.

### M4 completion record — 2026-08-09

M4 completes the repository implementation for extension `0.1.1`, worker protocol `1`, and outbox envelope `1` without widening the M3 compatibility boundary. The v1 contract freezes the public composite type, five views, 41 effective public function overloads, direct `0.1.0 -> 0.1.1` migration, external-delivery guarantee, and known limitations. The release-artifact gate builds one `linux/amd64` image and runs the complete M0–M3 suite, frozen API inventory, exact README workflow through the packaged worker, internal install/normal/failure/physical-restore/continued-operation pilot, retention checks, and direct upgrade. Task-oriented guides cover installation, authoring, operations, security, physical backup/restore, upgrades, and troubleshooting.

The recovery audit deliberately excludes logical `pg_dump`/`pg_restore` of live rules: pinned pg_trickle `0.81.0` cannot publicly rebuild restored source OIDs and differential change tracking, which could silently miss later work. Physical backup/PITR and physical failover are the supported v1 recovery mechanisms. [`docs/m4-evidence.md`](docs/m4-evidence.md) and [`docs/m4-pilot.md`](docs/m4-pilot.md) record the evidence; the exact `v0.1.1` tag runs the publication workflow for the tested OCI image, digest, archive checksum, release notes, and limitations.

---

## Stage 5 — Safe rule-set deployment

**Outcome:** let a team preview, apply, replace, and promote a related set of rules as one reviewed unit without partial deployment or direct access to private catalogs.

**Entry gate:** the validated `v0.1.1` release artifacts, checksums, and disclosures are published and verified; the reference multi-rule deployment and failure scenarios are agreed before the public contract is fixed.

### Deliverables

- A versioned rule-pack definition for grouping existing v1 constraint and command rules into one deployable unit.
- Public validation and preview that report additions, replacements, removals, dependencies, incompatible definitions, generated-object changes, and lifecycle risks without mutating durable state.
- Atomic pack deployment and replacement: catalog state, generated objects, and active-version changes either commit together or leave the prior deployment intact.
- Dependency inspection and rejection of missing, cyclic, or invalidly ordered dependencies before mutation.
- Apply-time revalidation so concurrent DDL or drift cannot make an earlier preview silently stale.
- A portable promotion path that does not copy internal OIDs or private catalog rows between environments.
- Public deployment history and diagnostics, plus one documented and executable development-to-production workflow.

### Explicit non-goals

- New execution modes, including `batch_safe`, `IMMEDIATE`, or synchronous firing.
- Automatic common-subplan sharing, catalog partitioning, or other speculative scaling work.
- Derivation rules, recursive evaluation, negation, temporal semantics, or fact-tuple identity.
- A custom rule language, client DSL, visual editor, AI authoring layer, or domain-package ecosystem.
- Expansion of the v1 compatibility, RLS, key-codec, recovery, or platform matrix without separate evidence.

### Decisions to close before the public API freezes

- Pack identity, versioning, ownership, and the portable definition format.
- The exact atomicity boundary across PostgreSQL and `pg_trickle` objects.
- Replacement behavior for active, pending, retrying, and leased work across several rules.
- Dependency kinds, cycle handling, and whether removal may be inferred or must be explicit.
- Environment-specific name and role mapping without weakening exact object identity or authorization.

### Exit gates

- Injected failure at every deployment phase leaves either the complete old pack or the complete new pack, with no mixed active versions or orphaned generated objects.
- Preview followed by apply produces the previewed plan, or apply rejects intervening drift and requires a new preview.
- Missing dependencies, cycles, incompatible bindings, unsafe ownership, and invalid removal order fail before durable mutation.
- Concurrent deployment, source DDL, and consequence DDL serialize or fail explicitly without ambiguous dispatch.
- Old work follows the declared replacement policy and can execute only through its exact immutable binding.
- The same pack definition can be validated and promoted in a second environment without copying internal identifiers.
- Existing single-rule APIs and v1 behavior remain backward compatible.
- A user can complete the reference workflow, inspect its history, and recover from a failed deployment using only public APIs and documentation.

### M5 completion record — 2026-08-09

The extension `0.2.0` repository candidate implements the pack definition, validation, preview digest, atomic deployment, explicit dependency/removal and old-work policies, portable object/role mapping, public history, diagnostics, direct `0.1.1 -> 0.2.0` upgrade, and documented development-to-production workflow. `tests/m5.sh` reruns every earlier compatibility/reference/recovery gate and adds exact-output failure-phase rollback, stale preview, invalid graph/binding/ownership/removal, immutable old-work, concurrent deployment/source/function DDL, history/diagnostics, upgrade, and two-environment promotion evidence recorded in [`docs/m5-evidence.md`](docs/m5-evidence.md).

The external entry gate is satisfied: [`v0.1.1`](https://github.com/trickle-labs/pg-react/releases/tag/v0.1.1) publishes the tested `31a2b4d85f6bb1cdd94a21337d94a98b40ee6b3d` bytes through successful [release run 31312006930](https://github.com/trickle-labs/pg-react/actions/runs/31312006930), with verified archive checksum, OCI digest, release notes, and limitations. The complete M5 gate was rerun against implementation commit `0d6d37a749fe25ad0a44c860af548720f081f85e`; all entry, deliverable, and exit requirements pass. [`docs/m5-readiness.md`](docs/m5-readiness.md) records the verification.

---

## Post-GA product directions

The directions below are intentional but are not implementation commitments and do not impose a fixed order. A direction becomes the next numbered milestone only when it has a demonstrated user or operational need, bounded prerequisites, explicit non-goals, a support matrix, and executable exit evidence. GitHub milestones represent only active or credible near-term implementation commitments.

A future direction may constrain a semantic decision, but it does not authorize speculative catalogs, APIs, or abstractions. PostgreSQL views, typed functions, explicit registration, immutable versions, and durable PostgreSQL state remain the canonical model.

### Product ergonomics

- Named reusable conditions where ordinary shared PostgreSQL views are insufficient.
- Schedule coordination, cost diagnostics, and targeted migration tooling driven by observed deployment friction.
- Compatibility, RLS, key-codec, recovery, and platform expansion one supported combination at a time.

### Execution and scale

- `batch_safe` execution only for measured consequence-throughput bottlenecks and proven commutative workloads.
- Selective `IMMEDIATE` mode only for demonstrated read-your-writes needs and combinations covered by a tested isolation and locking contract.
- Explicit shared conditions before automatic common-subplan discovery; automatic sharing only when repeated work and compatible security contexts are measured.
- Retention redesign, catalog partitioning, and other storage changes only after current limits are reproduced by benchmarks.

These capabilities are independent; none is a prerequisite for derived knowledge unless its promoted milestone demonstrates that dependency.

### Derived knowledge

The first reasoning milestone should be the smallest useful semantic slice: non-recursive derived facts with multiple logical supports, retraction, provenance, reconciliation, recovery, retention, and “why is this true?” explanation.

Positive recursive derivation and monotone fixed-point evaluation should be a later milestone after non-recursive support maintenance is proven. Stratified negation, deletion-sensitive reasoning, and recursive aggregation should remain separate later work and accept only programs with precise, testable semantics.

### Temporal reasoning

Temporal work may proceed independently where it does not require recursive or non-monotonic derivation. Any promoted milestone must define database time, event time, timers or scheduled reevaluation, durations, windows, lateness, corrections, retention, restart behavior, and interactions with any reasoning semantics it uses.

### Authoring and ecosystem

Raw-query convenience, client-side DSLs, visual tooling, AI-assisted authoring, LLM task patterns, and domain packages remain demand-driven layers. They must compile to, validate against, or inspect the canonical PostgreSQL-native model rather than define separate semantics.

---

## Non-negotiable release evidence

| Area | Required evidence |
|---|---|
| **Lifecycle correctness** | Property tests and end-to-end tests prove generation, revision, refraction, coalescing, and reconciliation invariants |
| **Concurrency** | Races involving joins, one semantic key, rule replacement, claims, conflicts, and lease expiry are tested under every supported isolation level |
| **Recovery** | Crash, restart, restore, PITR, failover, and upgrade tests preserve or explicitly reconcile every authoritative state transition |
| **Execution safety** | Exact function identity, role checks, fresh eligibility checks, and transactional completion are verified |
| **External effects** | At-least-once delivery, consumer deduplication, replay, and ordering limits are documented and exercised; no exactly-once claim is implied |
| **Explainability** | Rule, activation, and episode causality is queryable; the absence of general tuple-level lineage is explicit |
| **Usability** | Reference authoring and recovery tasks succeed through public APIs with actionable diagnostics |
| **Operations** | Health, metrics, retention, repair, fairness, backpressure, and runbooks cover each supported failure mode |
| **Performance** | Alpha smoke baselines expose cliffs; RC benchmarks publish regression budgets appropriate to the supported scale |

Feature count is never a substitute for this evidence. Each row becomes mandatory when its feature first enters scope; M0 and M1 are judged only by the narrower evidence named in their own exit gates, while every row is mandatory by GA.

---

## Decisions to close at each gate

### Before developer alpha

- Close during M0: the exact `pg_trickle` observation contract and pinned compatibility tuple.
- Close during M0: the M1 canonical-key codec support matrix and cross-restore fixtures. M0 itself is `bigint` only.
- Already fixed in the design: `SEED_CURRENT`/`REQUIRE_EMPTY`, `STATE_ONLY` reconciliation, immutable rising-edge payloads, warning-only compatible source drift, claim-blocking incompatible drift, and the versioned diagnostic envelope.
- Already fixed in the design: rule-owner evaluation/execution, rejection of RLS-protected sources, exact function dispatch, and the bounded one-item alpha worker/failure protocol.
- Deferred to beta with `CHANGE`: watched-column defaults, comparison support, and schema-change behavior.

### Before reliability beta

- Withdrawal and reactivation policy for every event kind.
- Conflict-key semantics and deterministic claim order.
- Retry classification, backoff, attempt limits, and terminal-failure behavior.
- The replacement policy matrix for pending, retrying, and leased work.
- The stable outbox envelope, consumer deduplication window, replay, and ordering contract.
- The reconciliation audit schema and event-emission policy.
- Feedback-loop limits and operator controls.

### Before release candidate

- Supported operating systems and architectures.
- Supported isolation and maintenance-mode matrix.
- RLS and evaluation-role support boundaries.
- Retention defaults, minimum surviving history, and upgrade compatibility windows.
- Fairness window, backpressure thresholds, claim bounds, lock ordering, and deadlock retry limits.
- Performance budgets and pilot workload.

Normative decisions belong in [`DESIGN.md`](DESIGN.md). Add an ADR only for a hard-to-reverse, surprising trade-off whose alternatives and consequences would otherwise be lost; link it from the implementing issue and pull request.

---

## GitHub milestone structure

| Milestone | Purpose |
|---|---|
| **M0 — Feasibility and walking skeleton** | Retire the refresh-observation and lifecycle-atomicity risks |
| **M1 — Developer alpha** | Deliver a small, understandable, useful rule engine |
| **M2 — Reliability beta** | Prove complete lifecycle and durable execution under failure |
| **M3 — Operational RC** | Establish production support, security, recovery, and performance evidence |
| **M4 — v1 GA** | Freeze and publish the supported contract |
| **M5 — Safe rule-set deployment** | Preview, atomically deploy, replace, and promote related rules |

Each implementation issue should belong to one milestone and one primary workstream label, for example `area/semantics`, `area/compiler`, `area/catalog`, `area/worker`, `area/security`, `area/operations`, `area/performance`, or `area/docs`.

Do not create GitHub milestones for the unnumbered post-GA directions. Promote only the next direction whose entry conditions and executable exit evidence are credible.

---

## Immediate next milestone

**M5 — Safe rule-set deployment** is complete. No M6 currently exists. The next planning action is to choose whether any unnumbered post-GA direction has enough demonstrated need, bounded prerequisites, non-goals, support matrix, and executable exit evidence to become a new milestone. Do not begin implementation or widen the maintenance, RLS, key-codec, backup, platform, or worker matrix before that promotion and its separate compatibility and regression evidence.

# pg-react roadmap

> **Status:** Living delivery plan  
> **Last updated:** 2026-08-27\
> **Contract authority:** [`docs/v1-contract.md`](docs/v1-contract.md), subject
> to installed behavior. [`DESIGN.md`](DESIGN.md) is historical M13
> architecture.

> [!IMPORTANT]
> The current release decision supersedes older sequencing retained below:
> `1.0.0` and its feature freeze are postponed indefinitely. M37 is complete;
> development continues one milestone at a time after M37, with M38 retained as
> a planning option rather than an implementation commitment. The project will
> begin a complete feature freeze and define a new `1.0.0` release-candidate
> sequence only after it has enough user traction and the maintainers explicitly
> decide it is ready.

**Product goal:** make `pg-react` the obvious rule engine for PostgreSQL users: powerful enough for serious rule logic, but simple, inspectable, and recognizably PostgreSQL.

`pg-react` should be the easiest safe way to turn changing PostgreSQL data into durable, inspectable decisions and work. It is a deep rule engine, not a broad application platform. The roadmap is therefore organized around three outcomes:

1. **PostgreSQL-native:** users reason in tables, rows, SQL, views, functions, types, transactions, constraints, and indexes; SQL remains the universal escape hatch and PostgreSQL remains authoritative.
2. **Understandable:** simple rules stay small, advanced capability is composed from a few explicit primitives, evaluation is deterministic and bounded, and every result and operational state is inspectable through public SQL.
3. **Safe to change:** users can validate, test, compare, deploy, observe, and explain rule behavior before and after production changes; performance costs and incomplete evidence are visible rather than hidden.

## Product principles and roadmap filter

The project follows five principles:

1. **PostgreSQL first.** Reuse PostgreSQL persistence, transactions, indexing, permissions, types, querying, backup, restore, and replication instead of building parallel machinery.
2. **Rules, not workflows.** Deepen rule expression, evaluation, explanation, testing, and safe evolution; do not grow into workflow orchestration, case management, approvals, human tasks, generic event processing, scheduling, BPM, or an application framework.
3. **Power without conceptual weight.** Prefer typed facts, rules, dependencies, applicability, explicit time, explanations, and simulation as composable primitives. Keep the common case small and avoid a proprietary rule language.
4. **Everything inspectable.** Public SQL must answer what is deployed, true, pending, failed, expensive, dependent, recently changed, and why. Explainability and visible operational state are parts of correctness.
5. **Safe change over clever features.** Favor deterministic behavior, explicit lifecycle and time semantics, bounded recursion and evidence, conservative negation, actionable ambiguity errors, stable identities, versioned semantics, and boring migrations.

Every proposed milestone must materially improve at least one of these outcomes: rules are easier to write; an important rule class becomes expressible; behavior becomes easier to understand; changes become safer; execution becomes faster or more reliable; or the product becomes more natural to PostgreSQL users. Otherwise it does not belong in `pg-react`.

The intended change workflow is `write -> validate -> test -> preview impact -> compare -> deploy -> observe -> explain`. Features must extend the authoritative runtime and relational inspection model rather than introduce a second evaluator, storage model, permission system, scheduler, or source of truth. Performance work must expose why evaluation is expensive, including fan-out, scans, cascade depth, repeated reevaluation, and generated work, not merely report that it is fast.

The stages below are **evidence gates, not calendar promises**. Parallel work is encouraged, but a later release must not ship before the earlier correctness gates are satisfied. Calendar commitments should be made only after the feasibility stage establishes the required `pg_trickle` integration contract.

---

## Product success criteria

A successful v1 lets a PostgreSQL developer:

1. Define a condition with a normal view.
2. Define an optional consequence with a typed PostgreSQL function or registered transactional outbox sink.
3. Declare, validate, preview, and deploy the rule through the ordinary `pgreact` SQL API.
4. Inspect current matches, lifecycle state, pending work, attempts, drift, health, dependencies, and explanations through documented SQL views and functions.
5. Compare a proposed policy with deployed behavior without mutating authoritative state or creating effects.
6. Replace, reconcile, retry, and recover a rule without editing internal tables.

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
| Deployment-impact comparison over current authoritative facts | Historical replay and comparative backtesting |
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

## Stage 4 — Initial GA baseline (historical v0.1.1)

**Outcome:** freeze and support the first dependable public contract.

This stage used “v1” as early project shorthand for the `0.1.1` contract. It
is historical and is not the final `1.0.0` release now gated after M34.

**Entry gate:** every M3 exit gate and published performance budget passes on release artifacts, not development builds.

### GA requirements

- The initial SQL API, worker protocol, catalog migration policy, compatibility policy, and external-delivery guarantees are documented and versioned.
- Installation, authoring, operations, security, backup/restore, upgrades, and troubleshooting each have task-oriented documentation.
- The end-to-end reference example is tested against every release artifact.
- No unresolved issue can cause silent missed lifecycle events, silent duplicate lifecycle events, lost committed work, unsafe function dispatch, or unrecoverable catalog state within the supported matrix.
- Release artifacts, checksums, upgrade notes, and known limitations are published together.
- A pilot user or internal production deployment has completed installation, normal operation, failure injection, restore, and upgrade exercises.

The first GA should prefer a small, explicit support matrix over broad best-effort compatibility.

### M4 completion record — 2026-08-09

M4 completes the repository implementation for extension `0.1.1`, worker protocol `1`, and outbox envelope `1` without widening the M3 compatibility boundary. The initial contract freezes the public composite type, five views, 41 effective public function overloads, direct `0.1.0 -> 0.1.1` migration, external-delivery guarantee, and known limitations. The release-artifact gate builds one `linux/amd64` image and runs the complete M0–M3 suite, frozen API inventory, exact README workflow through the packaged worker, internal install/normal/failure/physical-restore/continued-operation pilot, retention checks, and direct upgrade. Task-oriented guides cover installation, authoring, operations, security, physical backup/restore, upgrades, and troubleshooting.

The recovery audit deliberately excludes logical `pg_dump`/`pg_restore` of live rules: pinned pg_trickle `0.81.0` cannot publicly rebuild restored source OIDs and differential change tracking, which could silently miss later work. Physical backup/PITR and physical failover are the supported v1 recovery mechanisms. [`docs/m4-evidence.md`](docs/history/m4-evidence.md) and [`docs/m4-pilot.md`](docs/history/m4-pilot.md) record the evidence; the exact `v0.1.1` tag runs the publication workflow for the tested OCI image, digest, archive checksum, release notes, and limitations.

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

The extension `0.2.0` repository candidate implements the pack definition, validation, preview digest, atomic deployment, explicit dependency/removal and old-work policies, portable object/role mapping, public history, diagnostics, direct `0.1.1 -> 0.2.0` upgrade, and documented development-to-production workflow. `tests/m5.sh` reruns every earlier compatibility/reference/recovery gate and adds exact-output failure-phase rollback, stale preview, invalid graph/binding/ownership/removal, immutable old-work, concurrent deployment/source/function DDL, history/diagnostics, upgrade, and two-environment promotion evidence recorded in [`docs/m5-evidence.md`](docs/history/m5-evidence.md).

The external entry gate is satisfied: [`v0.1.1`](https://github.com/trickle-labs/pg-react/releases/tag/v0.1.1) publishes the tested `31a2b4d85f6bb1cdd94a21337d94a98b40ee6b3d` bytes through successful [release run 31312006930](https://github.com/trickle-labs/pg-react/actions/runs/31312006930), with verified archive checksum, OCI digest, release notes, and limitations. The complete M5 gate was rerun against implementation commit `0d6d37a749fe25ad0a44c860af548720f081f85e`; all entry, deliverable, and exit requirements pass. [`docs/m5-readiness.md`](docs/history/m5-readiness.md) records the verification.

---

## Stage 6 — Execution maturity

**Outcome:** increase command-consequence throughput for proven commutative workloads without weakening per-episode eligibility, lease, binding, conflict, recovery, or history guarantees, and without changing the default one-episode-per-transaction path.

**Entry gate:** the exact `v0.2.0` release artifacts, checksums, disclosures, and direct-upgrade path are published and verified. A reproducible workload must show that per-episode transaction and invocation overhead, rather than match maintenance or consequence work, is the material bottleneck; its unbatched baseline, representative batch-safe consequence, and failure scenarios are fixed before the public contract is frozen.

### Deliverables

- An immutable, explicit `batch_safe` declaration for typed database consequences; batching remains disabled by default.
- A separate bounded batch endpoint and worker opt-in that accept only episodes with the same immutable rule version, consequence binding, event kind, execution role, recheck policy, and compatible conflict scope.
- A documented transaction, eligibility, lease, retry, idempotency, ordering, and partial-failure contract for every episode in a batch.
- Invocation-time revalidation that rejects a structurally unsafe or stale batch before invoking its consequence.
- Public per-episode attempt history and batch diagnostics sufficient to explain selection, rejection, retry, and outcome without private-catalog access.
- A versioned extension and worker upgrade from `0.2.0`, plus a reproducible benchmark comparing the batch path with the unchanged default path.

### Supported boundary

- M6 inherits M5's `linux/amd64`, PostgreSQL 18.3, `pg_trickle` 0.81.0, `READ COMMITTED`, coordinator-owned scheduled `DIFFERENTIAL`, non-null `bigint` key, physical-recovery, and no-RLS boundary.
- Only `DATABASE_TYPED` consequences are batchable. Outbox, manual, no-op, immediate-maintenance, and synchronous execution remain on their existing paths or unsupported.
- The author asserts commutativity and cross-item independence. `pg-react` validates the structural compatibility it can prove and rejects every mismatch; it does not infer that arbitrary PostgreSQL code is safe to batch.
- Existing single-episode APIs, rule-pack definitions, worker protocol behavior, and one-episode-per-transaction execution remain supported and are the default.

### Explicit non-goals

- `IMMEDIATE` maintenance or strict synchronous consequence firing.
- Automatic batching, mixed-binding batches, or batching order-dependent consequences.
- Named shared conditions, automatic common-subplan discovery, catalog partitioning, or retention redesign.
- Expansion of the maintenance, isolation, RLS, key-codec, recovery, PostgreSQL, `pg_trickle`, OS, or architecture matrix.
- Derivation rules, logical support, recursion, negation, temporal semantics, or fact-tuple identity.

### Decisions to close before the public API freezes

- The typed batch signature, maximum batch size, claim shape, worker protocol version, and opt-in controls.
- Whether one item failure aborts the whole invocation or uses a narrower savepoint contract, and how every resulting state is represented.
- The exact recheck, conflict, lease-expiry, cancellation, pause, replacement, and concurrent-DDL behavior between claim and invocation.
- Retry and idempotency identity after rollback, worker death, or an ambiguous client disconnect, including whether any ordering promise exists.
- The benchmark workload, frozen throughput target, resource ceilings, observability fields, and regression budget for the default path.

### Exit gates

- For the fixed reference workload, normalized current activations, lifecycle events, agenda states, attempts, and consequence effects are exactly identical between eligible single-episode and batch execution.
- The endpoint rejects undeclared, mixed-version, mixed-binding, mixed-event, mixed-role, mixed-policy, incompatible-conflict, oversized, stale, and ineligible batches before consequence invocation with exact public diagnostics.
- Injected consequence errors, transaction aborts, worker death, lease expiry, and ambiguous disconnects produce the declared all-or-nothing or per-item outcome with no lost episode, duplicate committed database effect, or unusable lease.
- Concurrent source changes, pause, pack replacement, consequence DDL, dispatcher DDL, and recovery barriers serialize or reject explicitly without stale or ambiguous dispatch.
- The frozen reference benchmark meets its throughput and resource budgets while the default path stays within its regression budget.
- Direct `0.2.0 -> M6` upgrade, crash restart, supported physical restore, and continued operation preserve batch and single-episode state and history.
- The complete M0–M5 gates and exact default-worker outputs remain backward compatible.
- A user can declare, validate, run, inspect, retry, and disable batch execution using only public APIs and documentation.

---

## Stage 7 — Maintained derived knowledge

**Outcome:** maintain non-recursive derived facts as durable PostgreSQL state whose current truth, retraction, provenance, and recovery are explained by explicit logical supports rather than imperative consequence history.

**Entry gate:** the exact `v0.3.0` release artifacts, checksums, disclosures, and direct-upgrade path are published and verified. The [fixed reference model](docs/history/m7-entry.md) requires two independent derivations of one fact, removal of one and then the last support, downstream rule observation, reconciliation, and physical recovery; its expected public state and explanation output are frozen before the API contract is fixed.

### Deliverables

- A versioned derived-relation definition with a declared PostgreSQL row type, semantic key, ownership, and portable identity.
- A versioned derivation-rule kind whose current activation contributes exactly one logical support to one target fact and creates no agenda episode or imperative consequence.
- Durable support identity linking each support to its exact immutable rule version, activation generation, source binding, target relation, and fact identity.
- Truth maintenance in which equivalent supports collapse to one current fact, removing one of several supports preserves the fact, and removing the last support retracts it.
- Public current-fact, support-history, and explanation APIs that answer why a fact is true through active rule versions and source bindings without private-catalog access or a claim of general base-tuple lineage.
- Reconciliation, retention, backup/restore, and upgrade behavior that cannot retain an unsupported fact, retract a supported fact, or delete provenance required to explain current truth.
- Rule-pack validation, preview, deployment, replacement, and removal extended to derived relations, their producers, and downstream consumers without dangling or mixed-version dependencies.
- A versioned extension upgrade from `0.3.0` and one documented, executable workflow from definition through derivation, explanation, retraction, reconciliation, and recovery.

### Supported boundary

- M7 inherits M6's platform, maintenance, isolation, security, recovery, key-codec, and compatibility boundary.
- Derivation source views may read supported authoritative PostgreSQL relations. Existing constraint and command rules may read a public derived relation.
- A derivation rule may not read any derived relation. M7 therefore has no derivation chains, cycles, strata, or fixed-point evaluation.
- Derived relations are runtime-maintained state: users inspect them through public APIs and views but do not mutate them directly.

### Explicit non-goals

- Positive recursive derivation, acyclic derivation chains, fixed-point evaluation, stratified negation, recursive aggregation, or other non-monotonic reasoning over derived facts.
- Temporal facts, timers, windows, lateness, corrections, probabilistic truth, or confidence scoring.
- Automatic tuple-level lineage, counterfactual proof search beyond recorded supports, or a custom rule/query language.
- New consequence execution modes, shared-subplan discovery, catalog partitioning, or speculative retention scaling.
- Expansion of the inherited compatibility, RLS, key-codec, recovery, PostgreSQL, `pg_trickle`, OS, or architecture matrix.

### Decisions to close before the public API freezes

- Derived-relation naming, ownership, schema evolution, semantic-key encoding, and portable deployment identity.
- Whether fact identity includes the complete typed value or separates key from payload, and how conflicting payloads from simultaneous supports are rejected or represented.
- Exact support identity and history across activation `CHANGE`, deactivation/reactivation, rule replacement, pack replacement, and relation removal.
- The transaction and frontier boundary that orders source matches, supports, current facts, and downstream constraint or command lifecycle events.
- Authorization for defining, reading, explaining, reconciling, and dropping derived state, including behavior under concurrent source or consequence DDL.
- Provenance retention, tombstone, repair, and physical-recovery policy, including which explanation remains available after a fact retracts.

### Exit gates

- The fixed reference model produces one exact current fact from two independent supports; removing either support preserves the fact, removing the last retracts it, and restoring a support re-derives it with the declared identity and history.
- For every supported delta ordering in the reference model, incremental support and fact state exactly matches a clean full recomputation at the same source frontier.
- Support creation or invalidation and fact appearance or retraction commit atomically with no observable supported-absent or unsupported-present state; downstream lifecycle transitions follow the declared frontier and coalescing contract without silent loss or duplication.
- Preview/apply drift, injected deployment failures, replacement, removal, concurrent refresh, source DDL, relation DDL, and downstream-rule DDL leave one complete valid dependency graph and no orphaned support or fact state.
- Reconciliation repairs injected missing, extra, and stale support/fact state to the exact recomputed result and records every repair through public diagnostics.
- Crash restart, supported physical restore, and direct `0.3.0 -> M7` upgrade preserve or explicitly reconcile current facts, supports, retained provenance, dependencies, and downstream lifecycle state.
- Retention never removes a support or provenance record needed to justify a current fact; public explanation returns the exact active support set and source bindings for every current reference fact.
- The complete M0–M6 gates, v1 single-rule APIs, rule packs, both worker protocols, and default and batch execution outputs remain backward compatible.
- A user can define, validate, deploy, query, explain, retract, reconcile, replace, promote, and recover the reference derived relation using only public APIs and documentation.

### M7 completion record — 2026-08-09

M7 is released as `0.4.0`. The frozen two-support workload, opposite delta orderings, conflicting-payload rollback, non-recursion and mutation boundaries, atomic pack lifecycle, exact reconciliation, direct `0.3.0 -> 0.4.0` upgrade, crash restart, physical restore, and inherited M0–M6 gates are executable in `tests/m7.sh`. The public contract and evidence are recorded in `docs/m7-contract.md`, `docs/m7-evidence.md`, and `docs/m7-readiness.md`; immutable release evidence is recorded in `docs/m8-entry.md`.

---

## Stage 8 — Monotone recursive derivation

**Outcome:** maintain positive derivation chains and cycles as one durable least-fixed-point result, so every current derived fact has a finite proof grounded in authoritative input and recursive supports cannot keep an ungrounded cycle alive.

**Entry gate:** the exact `v0.4.0` release artifacts, checksums, disclosures, and direct-upgrade path are published and verified. A fixed reference program must include an acyclic chain, a positive recursive component, two paths to one fact, removal of one and then the last authoritative seed, downstream rule observation, reconciliation, pack replacement, and physical recovery; its exact current facts, supports, component frontiers, and finite explanations are frozen before the API contract is fixed.

### Deliverables

- A versioned derivation-program graph whose declared dependencies resolve every authoritative and derived input and classify acyclic and strongly connected components before deployment.
- A validated, range-restricted positive SQL subset for derived inputs that rejects negation, aggregation, unbounded value invention, and every unsupported or non-monotone dependency before catalog mutation.
- Least-fixed-point maintenance across affected components, with no fact retained solely by circular support and no partially converged component visible at a committed frontier.
- Durable component, iteration, support, and fact identity that preserves M7 relation and rule-version identity while making repeated evaluation idempotent.
- Finite public explanation of recursive facts through grounded proof paths, with cycles summarized without claiming general tuple-level lineage.
- Atomic validation, preview, deployment, replacement, and removal of complete recursive components through rule packs, including exact drift and dependency diagnostics.
- Reconciliation, retention, crash restart, physical restore, and resource-limit behavior that either reaches the exact least fixed point or leaves the previous committed frontier unchanged with an actionable failure.
- A versioned extension upgrade from `0.4.0` and one documented, executable workflow from program definition through convergence, explanation, seed retraction, reconciliation, replacement, and recovery.

### Supported boundary

- M8 inherits M7's platform, maintenance, isolation, security, recovery, key-codec, relation, support, provenance, and compatibility boundary.
- A derivation source may read authoritative PostgreSQL relations and public derived relations only through the supported positive, range-restricted subset; positive acyclic chains and cycles are allowed.
- Each program denotes the least fixed point over its finite active domain at one source frontier. A fact is current only when it has a finite derivation from authoritative input, even if its support graph also contains cycles.
- All affected components converge and commit before existing constraint or command rules observe the new derived frontier.

### Explicit non-goals

- Stratified negation, antijoins over derived inputs, deletion-sensitive non-monotone reasoning, recursive aggregation, or acceptance of arbitrary recursive SQL.
- Temporal facts, timers, windows, lateness, corrections, probabilistic truth, or confidence scoring.
- Automatic enumeration of every proof path, minimal-proof or counterfactual search, or general base-tuple lineage.
- New consequence execution modes, automatic common-subplan discovery, catalog partitioning, or speculative retention scaling.
- Expansion of the inherited compatibility, RLS, key-codec, recovery, PostgreSQL, `pg_trickle`, OS, or architecture matrix.

### Decisions to close before the public API freezes

- The exact positive SQL/operator subset, range-restriction rule, dependency discovery through nested views, and rejection diagnostics.
- Program and component identity, dependency ordering, frontier ownership, and atomicity across acyclic and strongly connected components.
- The convergence algorithm delegated to `pg_trickle`, iteration observability, resource bounds, and rollback behavior when convergence cannot be completed.
- Recursive support identity and invalidation across iterations, source deltas, rule replacement, pack replacement, and component merge or split.
- The finite explanation format for alternative paths and cycles, including which grounded proof remains available after retraction and retention.
- Reconciliation, locking, authorization, DDL serialization, recovery, and upgrade behavior for a dependency graph spanning multiple derived relations.

### Exit gates

- The fixed reference program converges to the exact declared least fixed point for its acyclic chain, positive cycle, and alternative paths; removing either path preserves shared facts, while removing the last authoritative seed retracts every fact supported only by the resulting cycle.
- Every supported ordering of equivalent source deltas, component scheduling, worker timing, crash/restart point, and incremental history produces byte-exact current facts, supports, component frontiers, and public explanations equal to a clean recomputation.
- An affected program commits atomically at one converged frontier; downstream rules never observe a partially evaluated component, and a resource-limit or evaluation failure preserves the prior complete state.
- Deployment rejects every frozen negative, aggregate, unbounded, unresolved, or otherwise unsupported program with exact diagnostics and no catalog or runtime change.
- Preview/apply drift, injected deployment failures, replacement, removal, concurrent refresh, source DDL, relation DDL, and component merge or split leave one complete valid dependency graph and no orphaned support or fact state.
- Reconciliation repairs injected missing, extra, stale, circular-only, and wrong-frontier support or fact state to the exact clean fixed point and records every repair through public diagnostics.
- Crash restart, supported physical restore, and direct `0.4.0 -> M8` upgrade preserve or explicitly reconcile programs, components, frontiers, facts, supports, provenance, dependencies, and downstream lifecycle state.
- Public explanation returns the exact finite grounded proof graph for every current reference fact, terminates on cycles, and never presents an ungrounded cycle as justification.
- The complete M0–M7 gates, v1 single-rule APIs, rule packs, both worker protocols, default and batch execution, and non-recursive derivation outputs remain backward compatible.
- A user can define, validate, deploy, converge, query, explain, retract, reconcile, replace, promote, and recover the reference recursive program using only public APIs and documentation.

### M8 completion record — 2026-08-09

M8 is implemented as the `0.5.0` repository candidate. The frozen acyclic and cyclic program, exact least-fixed-point stages, alternative grounded explanations, negative boundary, atomic component and pack lifecycle, resource rollback, reconciliation, direct `0.4.0 -> 0.5.0` upgrade, crash restart, physical restore, and inherited M0–M7 gates are executable in `tests/m8.sh`. The public contract and evidence are recorded in `docs/m8-contract.md`, `docs/m8-evidence.md`, and `docs/m8-readiness.md`.

---

## Stage 9 — Stratified negation

**Outcome:** maintain safe negative dependencies as one ordered derivation program whose visible state is the unique stratified result: each stratum reaches its positive least fixed point over stable lower strata, and lower-stratum presence or absence deterministically retracts or creates higher-stratum support.

**Entry gate:** the exact `v0.5.0` release artifacts, checksums, disclosures, and direct-upgrade path are published and verified. A fixed reference program must include positive recursion in a lower stratum, a keyed negative dependency into a higher stratum, a positive component above that dependency, insertion and removal that flip the negative match in both directions, downstream rule observation, exact negative-cycle rejection, reconciliation, pack replacement, and physical recovery; its exact facts, supports, stratum frontiers, and explanations are frozen before the API contract is fixed.

### Deliverables

- A versioned polarity-labeled dependency graph that classifies positive and negative edges, assigns stable strata, and rejects every cycle containing a negative edge before catalog mutation.
- A validated, range-restricted negation subset whose negative variables are bound by positive inputs and whose absence checks retain PostgreSQL's native equality and `NULL` semantics.
- Dependency-ordered evaluation that drives each stratum to its positive least fixed point over stable lower strata and commits all affected strata at one program frontier.
- Deletion-sensitive truth maintenance in which lower-stratum insertion can retract higher support and lower-stratum removal can create it without stale, duplicate, or self-justifying facts.
- Stable negative-dependency identity and public explanation evidence that names the checked relation, semantic key, and lower-stratum frontier without representing absence as a durable negative fact.
- Atomic validation, preview, deployment, replacement, and removal of complete stratified programs through rule packs, including exact drift and dependency diagnostics.
- Reconciliation, retention, crash restart, physical restore, and resource-limit behavior that reaches the exact stratified result or leaves the previous complete program frontier unchanged with an actionable failure.
- A versioned extension upgrade from `0.5.0` and one documented, executable workflow from program definition through negative derivation, invalidation, restoration, explanation, reconciliation, replacement, and recovery.

### Supported boundary

- M9 inherits M8's platform, maintenance, isolation, security, recovery, key-codec, program, support, provenance, resource-limit, and compatibility boundary.
- Positive dependencies may remain within one stratum, including M8 positive recursion. Every negative dependency must point to an authoritative input or a derived relation in a strictly lower stratum; no dependency cycle may contain a negative edge.
- Absence means no matching row in the declared input at the same program frontier. It does not assert open-world falsity or create a user-mutable negative fact.
- All affected lower and higher strata converge and commit before existing constraint or command rules observe the new derived frontier.

### Explicit non-goals

- Unstratified negation, cycles through negative dependencies, stable-model or well-founded search, defeasible reasoning, or arbitrary logic programs.
- Recursive aggregation, aggregate dependencies between strata, general antijoins, outer-join absence idioms, `EXCEPT`, or acceptance of arbitrary non-monotone SQL.
- Temporal absence, timers, windows, lateness, corrections, probabilistic truth, confidence scoring, or open-world reasoning.
- Automatic enumeration of every proof or refutation, minimal-proof or counterfactual search, or general base-tuple lineage.
- New consequence execution modes, automatic common-subplan discovery, catalog partitioning, or expansion of the inherited compatibility, RLS, key-codec, recovery, PostgreSQL, `pg_trickle`, OS, or architecture matrix.

### Decisions to close before the public API freezes

- The exact negative SQL/operator subset, range-restriction rule, PostgreSQL `NULL` behavior, nested-view dependency discovery, and rejection diagnostics.
- Positive and negative edge identity, deterministic stratum assignment, portable graph hashing, and behavior when replacement splits, merges, inserts, or removes strata.
- Frontier ownership, evaluation ordering, locking, and rollback across affected strata when lower-stratum presence invalidates higher-stratum support.
- Negative-dependency evidence identity and invalidation across source deltas, repeated evaluation, rule replacement, pack replacement, reconciliation, and retention.
- The finite explanation format for a satisfied negative condition, including checked relation, semantic key, lower frontier, and behavior after the condition stops matching.
- Authorization, DDL serialization, recovery, resource bounds, reconciliation, and upgrade behavior for negative dependencies spanning multiple strata.

### Serial implementation slices

Implement M9 in the order below. Each slice must leave the repository coherent,
rerun the exact gates from earlier slices, and verify complete public outputs
rather than internal row counts. Add only the catalog, API, runtime, and test
surface needed by the current slice; later slices must not be scaffolded early.

1. **Freeze the executable contract.** After the `v0.5.0` entry evidence is
   verified, freeze one reference program and its exact initial, blocked, and
   restored facts, supports, negative-dependency evidence, stratum frontiers,
   and explanations. Freeze exact rejection and `NULL` fixtures, close the
   decisions above in `docs/m9-contract.md`, and record the release evidence in
   `docs/m9-entry.md`. This slice changes no product behavior.
2. **Deploy and inspect one safe negative dependency.** Extend the public
   rule-pack path end to end for one range-restricted keyed absence check over a
   stable lower input: resolve edge polarity, assign deterministic strata,
   validate and preview the graph, deploy it, compute its initial result, and
   expose the graph, facts, supports, and stratum frontier through public APIs.
   Reject negative cycles, unbound variables, unsupported absence idioms,
   aggregate dependencies, and unresolved inputs before mutation with exact
   diagnostics while the frozen `NULL` cases retain PostgreSQL behavior.
3. **Maintain deletion-sensitive truth.** Make insertion of the blocking
   lower-stratum fact retract the exact higher support and fact, and make its
   removal restore them. Commit all affected strata at one program frontier,
   coalesce downstream lifecycle observation, and prove repeated refresh,
   equivalent delta order, and injected evaluation failure are idempotent and
   atomic.
4. **Compose negation with positive fixed points.** Add the frozen lower
   positive-recursive component and the positive component above the negative
   edge. Evaluate strata in dependency order while retaining M8 grounding,
   convergence, scheduling-order independence, and resource bounds; no lower
   ungrounded cycle or partially converged higher stratum may become visible.
5. **Change complete stratified programs safely.** Extend validation, preview,
   apply, replacement, removal, and promotion across stratum insertion,
   deletion, merge, and split. Prove stale preview, injected deployment
   failure, concurrent refresh, source or relation DDL, and dependency drift
   leave one complete polarity-labeled graph with no orphaned support,
   negative-dependency evidence, or fact state.
6. **Explain and repair the result.** Return the frozen finite grounded proof
   and satisfied negative checks without representing absence as a fact.
   Reconcile injected missing, extra, stale, wrong-stratum, and wrong-frontier
   state to the exact clean result, make the second repair a no-op, and retain
   every record required to explain current truth.
7. **Prove durability and prepare the release candidate.** Add direct
   `0.5.0 -> M9` upgrade, crash restart, physical restore, the complete public
   author workflow, and all inherited M0-M8 compatibility gates. Generate the
   fresh-install SQL mechanically from the `0.5.0` install plus the M9 upgrade,
   then add evidence, readiness, upgrade, and release documentation only after
   the executable gates pass.

### Exit gates

- The fixed reference program reaches the exact declared stratified result; adding the blocking lower-stratum fact retracts every dependent higher fact, removing it restores the exact supports and explanations, and a lower positive cycle never survives without authoritative grounding.
- Every supported ordering of equivalent source deltas, stratum scheduling, worker timing, crash/restart point, and incremental history produces byte-exact current facts, supports, stratum frontiers, and public explanations equal to a clean dependency-ordered recomputation.
- An affected program commits atomically at one completed frontier; downstream rules never observe a lower stratum without its corresponding higher-stratum invalidations, and a resource-limit or evaluation failure preserves the prior complete state.
- Deployment rejects every frozen negative cycle, unsafe or unbound negative predicate, aggregate dependency, unsupported absence idiom, and unresolved dependency with exact diagnostics and no catalog or runtime change; frozen `NULL` cases retain exact PostgreSQL behavior.
- Preview/apply drift, injected deployment failures, replacement, removal, concurrent refresh, source DDL, relation DDL, and stratum merge or split leave one complete valid polarity-labeled graph and no orphaned support, evidence, or fact state.
- Reconciliation repairs injected missing, extra, stale, wrong-stratum, and wrong-frontier support, evidence, or fact state to the exact clean stratified result and records every repair through public diagnostics.
- Crash restart, supported physical restore, and direct `0.5.0 -> M9` upgrade preserve or explicitly reconcile programs, strata, components, frontiers, facts, supports, negative-dependency evidence, provenance, and downstream lifecycle state.
- Public explanation returns the exact finite grounded proof graph and negative checks for every current reference fact without presenting absence as a source fact or an ungrounded cycle as justification.
- The complete M0–M8 gates, v1 single-rule APIs, legacy rule packs, both worker protocols, default and batch execution, and positive recursive derivation outputs remain backward compatible.
- A user can define, validate, deploy, converge, query, explain, invalidate, restore, reconcile, replace, promote, and recover the reference stratified program using only public APIs and documentation.

### M9 completion record — 2026-08-10

M9 is implemented as the `0.6.0` repository candidate. The frozen stratified program, exact deletion-sensitive stages, polarity graph, strata, negative evidence, explanations, atomic pack lifecycle, resource rollback, reconciliation, direct `0.5.0 -> 0.6.0` upgrade, non-superuser author workflow, crash restart, physical restore, and inherited M0-M8 gates are executable in `tests/m9.sh`. The public contract and evidence are recorded in `docs/m9-contract.md`, `docs/m9-evidence.md`, and `docs/m9-readiness.md`.

---

## Stage 10 — Stratified aggregation

**Outcome:** maintain keyed aggregate dependencies as one ordered derivation program whose visible state is the unique stratified result: each grouped `COUNT(*)` reads one stable lower stratum, and exact count changes deterministically create, update, or retract higher-stratum support without exposing an intermediate frontier.

**Entry gate:** the exact `v0.6.0` release artifacts, checksums, disclosures, and direct-upgrade path are published and verified. A fixed reference program must include positive recursion in a lower stratum, a positively bound group, one `COUNT(*)` threshold dependency into a higher stratum, count changes that cross the threshold in both directions and changes that remain on one side, group removal and restoration, downstream rule observation, exact aggregate-cycle and unsupported-aggregate rejection, reconciliation, pack replacement, and physical recovery; its exact facts, supports, aggregate evidence, stratum frontiers, and explanations are frozen before the current repository API contract is fixed.

### Deliverables

- A versioned dependency graph that distinguishes positive, negative, and aggregate edges, assigns stable strata, and rejects every cycle containing a negative or aggregate edge before catalog mutation.
- A validated, range-restricted aggregate subset consisting of grouped `COUNT(*)` over one declared authoritative or lower-stratum derived input, compared with one immutable non-negative `bigint` threshold using `=`, `<`, `<=`, `>`, or `>=`.
- Dependency-ordered evaluation that computes each count only after its lower stratum converges and commits every affected stratum at one program frontier.
- Deletion-sensitive aggregate maintenance in which lower-row insertion, update, or removal creates, updates, or retracts the exact higher support without stale groups, duplicate support, or spurious downstream truth transitions.
- Stable aggregate-dependency identity and public evidence that names the counted relation, group key, exact count, comparison, threshold, and lower-stratum frontier without representing the summary as an authoritative fact.
- Atomic validation, preview, deployment, replacement, and removal of complete aggregate programs through rule packs, including exact drift and dependency diagnostics.
- Reconciliation, retention, crash restart, physical restore, and resource-limit behavior that reaches the exact stratified aggregate result or leaves the previous complete program frontier unchanged with an actionable failure.
- A versioned extension upgrade from `0.6.0`, one documented, executable workflow from program definition through threshold maintenance, explanation, reconciliation, replacement, and recovery, and one brief idealized PostgreSQL-user workflow that may differ from the current repository API.

### Supported boundary

- M10 inherits M9's platform, maintenance, isolation, security, recovery, key-codec, program, stratum, support, provenance, resource-limit, and compatibility boundary.
- A rule may declare one aggregate dependency. Its group key must be bound by a positive input and equal the derived fact's semantic key; its counted input must be finite and in a strictly lower stratum.
- Positive dependencies may remain within one stratum, including M8 positive recursion, and M9 negative dependencies retain their existing boundary. No dependency cycle may contain a negative or aggregate edge.
- PostgreSQL `COUNT(*)`, `bigint`, comparison, and `NULL` behavior is authoritative. All affected strata commit before existing constraint or command rules observe the new derived frontier.

### Explicit non-goals

- Aggregate dependencies inside a recursive component, aggregate cycles, same-stratum aggregates, or arbitrary recursive aggregation.
- `COUNT(expression)`, `DISTINCT`, `FILTER`, multiple aggregates per rule, `SUM`, `AVG`, `MIN`, `MAX`, ordered-set or user-defined aggregates, windows, grouping sets, or arbitrary `HAVING` expressions.
- Unstratified negation, cycles through negative dependencies, stable-model or well-founded search, defeasible reasoning, or arbitrary logic programs.
- Temporal aggregation, timers, windows, lateness, corrections, probabilistic truth, confidence scoring, or open-world reasoning.
- Automatic enumeration of every counted binding or proof path, minimal-proof or counterfactual search, or general base-tuple lineage.
- New consequence execution modes, automatic common-subplan discovery, catalog partitioning, or expansion of the inherited compatibility, RLS, key-codec, recovery, PostgreSQL, `pg_trickle`, OS, or architecture matrix.

### Decisions to close for the current repository API

These choices prove M10 semantics; public names and call shapes remain provisional until the PostgreSQL-facing redesign becomes normative.

- The aggregate declaration shape, exact SQL recognition boundary, group-key range restriction, comparison syntax, threshold validation, nested-view dependency discovery, and rejection diagnostics.
- Positive, negative, and aggregate edge identity, deterministic stratum assignment, portable graph hashing, and behavior when replacement splits, merges, inserts, or removes strata.
- Aggregate evidence and support identity across count changes, repeated evaluation, rule replacement, pack replacement, reconciliation, and retention, including count changes that do not flip truth.
- Frontier ownership, evaluation ordering, locking, and rollback across affected strata when lower-row changes alter a count or threshold result.
- The finite explanation format for an aggregate condition, including group key, exact count, comparison, threshold, lower frontier, and the explicit absence of per-row proof enumeration.
- Authorization, DDL serialization, recovery, resource bounds, reconciliation, and upgrade behavior for aggregate dependencies spanning multiple strata.

### Exit gates

- The fixed reference program reaches the exact declared stratified result for every frozen count; crossing the threshold in either direction creates or retracts the exact higher facts, while a count change that does not flip the comparison updates evidence and explanation without a false downstream lifecycle transition.
- Every supported ordering of equivalent source deltas, stratum scheduling, worker timing, crash/restart point, and incremental history produces byte-exact current facts, supports, aggregate evidence, stratum frontiers, and public explanations equal to a clean dependency-ordered recomputation.
- An affected program commits atomically at one completed frontier; downstream rules never observe a lower count without its corresponding higher-stratum change, and a resource-limit or evaluation failure preserves the prior complete state.
- Deployment rejects every frozen aggregate cycle, same-stratum aggregate, unbound or mismatched group key, negative threshold, unsupported aggregate, multiple-aggregate rule, unresolved dependency, and unsupported expression with exact diagnostics and no catalog or runtime change.
- Preview/apply drift, injected deployment failures, replacement, removal, concurrent refresh, source DDL, relation DDL, and stratum merge or split leave one complete valid graph and no orphaned support, aggregate evidence, or fact state.
- Reconciliation repairs injected missing, extra, stale, wrong-count, wrong-group, wrong-stratum, and wrong-frontier support, evidence, or fact state to the exact clean result and records every repair through public diagnostics.
- Crash restart, supported physical restore, and direct `0.6.0 -> M10` upgrade preserve or explicitly reconcile programs, strata, components, frontiers, facts, supports, negative and aggregate evidence, provenance, and downstream lifecycle state.
- Public explanation returns the exact finite grounded proof graph, negative checks, and aggregate condition for every current reference fact without presenting a summary as an authoritative fact or enumerating every counted row.
- The complete M0–M9 semantic, operational, recovery, and documented-workflow gates, legacy rule-pack behavior, both worker protocols, default and batch execution, positive recursion, and stratified-negation outputs remain backward compatible. Current public SQL API names and call shapes remain provisional until the redesign is normative, so M10 requires no compatibility aliases solely to preserve them.
- A user can define, validate, deploy, converge, query, explain, cross and recross a threshold, reconcile, replace, promote, and recover the reference aggregate program using only public APIs and documentation.

---

## Stage 11 — PostgreSQL-facing API redesign

**Outcome:** replace the provisional repository interface with one coherent PostgreSQL-first public contract through which authors, operators, and workers can complete every M0–M10 workflow without routine knowledge of internal identifiers, scheduling structures, or private catalogs, while preserving the exact semantic, durable-state, security, recovery, and external-effect guarantees already proved.

**Entry gate:** the exact `v0.7.0` release artifacts, checksums, disclosures, and direct-upgrade path are published and verified. Before the replacement API is fixed, freeze a task suite that covers constraint and command rules, safe rule-set deployment, both worker protocols, non-recursive and recursive derivation, stratified negation, stratified aggregation, status, diagnostics, explanation, reconciliation, physical recovery, and upgrade from a populated `0.7.0` database; freeze its normalized durable state and complete user-visible results.

### Deliverables

- One canonical vocabulary and an allow-listed public inventory covering SQL schemas, types, views, functions, grants, rule-pack manifests, worker commands, configuration, diagnostics, and documentation.
- A small PostgreSQL-native authoring surface built around views or relations, explicit semantic keys, typed PostgreSQL functions or outbox actions, rules, derived relations, and derivation programs, with safe defaults and inference of rule kind, compatible action signature, dependency polarity, components, and strata where unambiguous.
- Name-first status, diagnostics, history, and explanation entry points that progressively disclose immutable versions, activations, episodes, supports, frontiers, strata, and aggregate evidence only when exact identity or advanced operation requires them.
- Complete operator and worker workflows for validation, preview, deployment, promotion, pause and recovery barriers, reconciliation, health, retention, consequence execution, and repair without private-catalog access.
- Explicit replacement and migration rules for every provisional `0.7.0` public surface, including which calls are removed, deliberately bridged, or made compatibility commitments, plus a versioned extension and worker upgrade from `0.7.0` that preserves durable state and pending work.
- Rewritten task-oriented installation, authoring, deployment, operation, explanation, security, backup/restore, upgrade, and troubleshooting documentation using only the replacement contract.
- Exact fresh-install, upgrade, API-inventory, privilege, workflow, failure, recovery, and documentation tests that distinguish presentation changes from inherited semantic regressions.

### Supported boundary

- M11 inherits M10's PostgreSQL, `pg_trickle`, pgrx, OS, architecture, maintenance, isolation, RLS, key-codec, physical-recovery, worker-protocol, semantic, resource-limit, and external-effect boundaries.
- PostgreSQL objects and SQL remain authoritative. Manifests and worker commands may package intent, but they do not define a second rule language or semantic model.
- Immutable internal identities and advanced evidence remain queryable where correctness, history, recovery, or support requires them; routine authoring and inspection are name-first.
- M11 is the deliberate compatibility reset for provisional surfaces. Its frozen allow-list states exactly which replacement surfaces begin the next compatibility commitment and from which release.

### Explicit non-goals

- New reasoning semantics, including richer or recursive aggregates, unstratified negation, temporal reasoning, probabilistic truth, confidence scoring, open-world reasoning, or general lineage.
- New execution modes, worker protocol 3, synchronous firing, automatic common-subplan discovery, catalog partitioning, or retention redesign.
- Expansion of the inherited compatibility, RLS, key-codec, logical-recovery, PostgreSQL, `pg_trickle`, OS, or architecture matrix.
- A custom rule language, client SDK, visual editor, AI authoring layer, domain-package ecosystem, or non-PostgreSQL control plane.
- Compatibility aliases for every provisional function, view, manifest field, command, argument, or term, or removal of the private engine model needed to preserve proven behavior.

### Decisions to close before the replacement contract freezes

- The canonical user vocabulary, public schema layout, function and view inventory, overload policy, privilege model, and boundary between author, operator, worker, and advanced inspection surfaces.
- The exact SQL declarations for conditions, actions, semantic keys, lifecycle policy, derived relations, and derivation programs, including safe defaults and the boundary between inference and explicit annotation.
- Stable name lookup, immutable-version access, deployment and promotion identity, and which internal identifiers may appear in routine versus advanced results.
- The versioned status, diagnostic, history, and explanation envelopes and how every M0–M10 evidence kind is represented without separate feature-specific entry points.
- The worker command, configuration, connection, protocol-selection, health, shutdown, and upgrade contract for both inherited protocols.
- The `0.7.0` replacement matrix, migration diagnostics, compatibility start point, and policy for intentionally removed provisional calls.

### Exit gates

- The frozen author task suite creates and operates constraint, command, pack, non-recursive derivation, positive recursion, stratified-negation, and stratified-aggregation examples through only the replacement surface and produces the exact expected complete results.
- The M10 reference program deployed through the replacement API produces byte-exact normalized facts, supports, dependency graph, strata, aggregate evidence, explanations, lifecycle state, and work equal to the `0.7.0` reference result.
- Fresh install exposes exactly the frozen public inventory and grants; no private object is accidentally reachable, and every rejected declaration or unauthorized operation returns the exact documented diagnostic without partial mutation.
- Direct upgrade from the populated `0.7.0` fixture preserves byte-exact normalized durable state, pending and leased work, immutable bindings, provenance, frontiers, and history; every old public surface follows its frozen remove, bridge, or retain rule.
- Crash, restart, supported physical restore, reconciliation, pack replacement, concurrent DDL, worker death, retry, outbox replay, and resource-limit fixtures retain their M0–M10 outcomes through the replacement surface.
- Every inherited M0–M10 semantic, operational, security, recovery, performance, and external-effect gate passes after presentation-only snapshots are intentionally replaced with the frozen M11 contract.
- A new user can complete the frozen author, operator, and worker tasks from the rewritten documentation without private-catalog access or manually supplying internal version, component, stratum, support, episode, or frontier identifiers.
- Release notes and the exact API inventory state which M11 surfaces are compatibility commitments, which `0.7.0` surfaces were removed or bridged, and the release from which compatibility begins.

---

## Stage 12 — Database-time deadlines

**Outcome:** make a constraint or command rule become true when PostgreSQL database time reaches one declared deadline, even when no business row changes, while preserving atomic lifecycle observation and the existing asynchronous consequence contract.

**Entry gate:** the exact `v0.8.0` release artifacts, checksums, disclosures, and populated direct-upgrade path are published and verified. Before the API contract is extended, freeze a reference workload covering a future deadline, equality at the deadline, an already-overdue row, deadline advancement and postponement, source deletion, coordinator downtime, a backward clock adjustment, a forward clock jump, crash/restart, physical recovery, and upgrade; freeze its exact lifecycle, agenda, clock-frontier, diagnostic, and explanation results.

### Deliverables

- One PostgreSQL-native declaration for a non-null `timestamptz` deadline column on a finite candidate relation, with one semantic key and the single predicate “due when the durable clock frontier is greater than or equal to the deadline.”
- A durable monotone clock frontier sampled once from PostgreSQL by the coordinator and advanced as `max(previous_frontier, sampled_time)`, so a backward wall-clock adjustment pauses time-driven progress and a forward jump performs one deterministic catch-up.
- Indexed durable due state that survives restart and lets the coordinator advance only affected rules and keys rather than polling every rule row.
- One coordinator-owned transaction that advances the clock frontier, evaluates due candidates through the supported explicit `DIFFERENTIAL` path, and commits match, lifecycle, and agenda changes behind the inherited claim barrier.
- Exact lifecycle behavior for insertion, deletion, deadline change, deployment, replacement, pause, resume, and removal, including no early activation and no duplicate activation when several scheduler passes observe the same frontier.
- Name-first status, diagnostics, history, and explanation that report the declared deadline, observed clock frontier, and resulting lifecycle event without exposing private timer identifiers.
- A versioned extension and worker upgrade from `0.8.0`, task documentation, and exact fresh-install, privilege, failure, recovery, and upgrade evidence.

### Supported boundary

- M12 inherits M11's PostgreSQL, `pg_trickle`, pgrx, OS, architecture, maintenance, isolation, RLS, key-codec, physical-recovery, worker-protocol, resource-limit, and external-effect boundaries.
- A temporal declaration belongs to one constraint or command rule, reads one non-null `timestamptz` deadline for each candidate semantic key, and uses PostgreSQL comparison and time-zone semantics. Equality is due.
- Time advances only when the supported coordinator commits a clock frontier. Coordinator downtime may delay observation; the first successful pass catches up every deadline now due exactly once under the inherited lifecycle rules.
- Consequences remain asynchronous and at-least-once. M12 promises neither exact wall-clock firing latency nor synchronous execution in the source transaction.

### Explicit non-goals

- Event time, watermarks, lateness, corrections, durations, expiration intervals, sliding or session windows, temporal joins, or temporal aggregation.
- Recurring schedules, cron or calendar expressions, time-zone calendars, per-row background jobs, or replay of every missed recurrence.
- Temporal predicates inside recursive, negative, or aggregate derivation programs; temporal support or provenance beyond the declared deadline and committed clock frontier.
- `IMMEDIATE` maintenance, synchronous consequences, worker protocol 3, the `pg_trickle` automatic scheduler, or expansion of the inherited support matrix.

### Decisions to close before the M12 contract freezes

- The public declaration shape, deadline-column validation, candidate-relation identity, replacement rules, and exact diagnostics for null, ambiguous, volatile, or unsupported time expressions.
- Clock sampling, monotone-frontier persistence, scheduler cadence, transaction ownership, lock order, and behavior after backward adjustment, forward jump, standby promotion, and physical restore.
- Due-state identity and indexing across insert, update, deletion, pause, replacement, reconciliation, retention, and upgrade without a second rule or timer language.
- Whether postponing an active deadline creates an ordinary deactivation followed by a later new activation generation, and the exact coalescing rule when source and clock changes arrive in one refresh transaction.
- Authorization, resource limits, health thresholds, lag diagnostics, and the versioned status, history, and explanation envelopes for scheduled evaluation.

### Exit gates

- The frozen reference workload produces the exact declared matches, generations, lifecycle events, agenda episodes, clock frontiers, status, and explanations at every stage; no deadline activates before equality and no due transition is duplicated.
- Every supported ordering of equivalent source changes, clock samples, scheduler retries, worker timing, and incremental history produces byte-exact current state and public evidence equal to a clean recomputation at the same durable clock frontier.
- Advancing a frontier commits atomically with all affected match and lifecycle changes; injected refresh, resource-limit, or catalog failures preserve the previous complete frontier and expose no claimable partial work.
- Postponement, advancement, deletion, deployment, replacement, pause, resume, and reconciliation leave the exact declared due state with no orphaned timer, match, lifecycle, or agenda rows.
- A backward clock adjustment never moves the durable frontier or retracts a due match; a forward jump, coordinator outage, crash, restart, supported physical restore, and standby promotion catch up all and only deadlines now due once.
- Deployment rejects every frozen null, volatile, ambiguous, recursive, negative, aggregate, recurring, windowed, unauthorized, or unsupported deadline declaration with exact diagnostics and no partial mutation.
- Direct upgrade from the populated `0.8.0` fixture preserves byte-exact M11 state and pending work, initializes the clock frontier without retroactive duplicates, and makes already-overdue M12 candidates due on the first successful pass.
- Every inherited M0–M11 semantic, operational, security, recovery, performance, compatibility, and external-effect gate passes unchanged.
- A new user can declare, validate, deploy, observe, postpone, pause, resume, explain, reconcile, replace, recover, and upgrade the reference deadline rule using only the public API and documentation.

---

## Stage 13 — Core PostgreSQL ergonomics

**Outcome:** complete the ordinary PostgreSQL rule workflow so an author can register a condition and typed action with short SQL, an operator can run it through one correct coordinator-owned path, action context is optional, routine language is application-facing, and author, operator, worker, and reader privileges are genuinely distinct.

**Entry gate:** the exact `v0.9.0` release artifacts, checksums, disclosures, and populated direct-upgrade path are published and verified. Before the API contract is extended, freeze ordinary constraint and command fixtures covering each supported action signature, ambiguous and unauthorized action lookup, context-free and context-aware execution, concurrent and repeated runs, source and clock changes in one run, all four application roles, failure rollback, crash/restart, physical recovery, and upgrade.

### Deliverables

- One canonical `run` operation that owns coordinator locking and advances every affected source refresh, program frontier, deadline frontier, lifecycle transition, and agenda insertion in dependency order before returning one exact result; no public shortcut may expose partial or stale coordinated state.
- Simple named-argument `author_rule` overloads for the common constraint, activation-only command, and lifecycle-command cases, while retaining one explicit advanced form for uncommon policy rather than requiring a JSON pack or positional rule-kind argument.
- Automatic, schema-safe action resolution from the condition row type and lifecycle event: accept exactly one compatible PostgreSQL function, reject missing, ambiguous, variadic, polymorphic, default-argument-dependent, or unauthorized candidates, and record the resolved immutable identity at deployment.
- Equivalent action contracts with either the typed condition row alone or the existing activation context followed by that row. Omitting context changes only the function signature, not durable identity, refraction, retry, or external-effect semantics.
- Routine vocabulary centered on condition, rule, action, match, run, job, and attempt; engine terms such as activation, episode, generation, component, stratum, support, and frontier remain available only where exact history or advanced operation needs them.
- An exact default-privilege and upgrade grant matrix in which authors can validate and author, operators can run and administer, workers can claim and execute, readers can inspect, and no role inherits every `pgreact_api` function merely through schema-wide execution grants.
- A versioned extension and worker upgrade from `0.9.0`, a compact task workflow using only the ergonomic surface, and exact fresh-install, API-inventory, overload, resolution, terminology, privilege, concurrency, failure, recovery, and upgrade evidence.

### Supported boundary

- M13 inherits M12's complete platform, semantic, maintenance, isolation, RLS, key-codec, recovery, worker-protocol, resource-limit, and external-effect boundary.
- Automatic resolution searches only the explicitly supported schemas and exact visible PostgreSQL function identities under the author and action-owner security contract. Deployment stores identity; later search-path or overload changes cannot retarget existing work.
- `run` coordinates database evaluation and durable agenda creation. Consequences remain asynchronous and at-least-once, and a successful run does not promise that every queued action has completed.
- Existing exact context-aware actions remain supported. Context-free actions are convenience overloads over the same durable execution model, not a weaker execution path.

### Explicit non-goals

- New reasoning semantics, broader key codecs, composite keys, RLS sources, isolation levels, worker protocols, synchronous consequences, or support-matrix expansion.
- Unified proof exploration, automatic dependency or stratum inference, new derived-relation authoring, or redesign of advanced evidence; those belong to M14.
- PostgreSQL-managed background-worker installation or replacement of the bundled worker process; that belongs to M15.
- A custom rule language, client SDK, visual builder, implicit action creation, search-path-dependent dispatch, or compatibility aliases for every M11/M12 presentation detail.

### Decisions to close before the M13 contract freezes

- The exact `author_rule` overload set, named defaults, lifecycle-action combinations, return types, and boundary between common and advanced authoring.
- Action-schema allow-listing, signature preference, ambiguity rules, authorization checks, immutable identity recording, and diagnostics for every rejected candidate.
- `run` target and result shape, coordinator ownership, lock order, dependency ordering, clock sampling, failure rollback, concurrency coalescing, and behavior for paused or unhealthy rules.
- The public vocabulary and compatibility mapping for renamed routine fields without erasing immutable historical terminology from advanced evidence.
- The author, operator, worker, and reader object-by-object grants, default privileges, ownership requirements, escalation tests, and upgrade repair behavior.

### Exit gates

- The frozen ordinary workflows author every supported constraint and command shape using only simple named arguments, with and without activation context, and produce exact rules, immutable action bindings, matches, lifecycle events, jobs, attempts, and results.
- Automatic action resolution selects the one exact compatible authorized function regardless of caller search path and rejects every missing, ambiguous, structurally incompatible, unauthorized, or subsequently drifted candidate with exact diagnostics and no partial catalog mutation.
- Every supported ordering of concurrent or repeated `run` calls, source changes, deadline samples, worker timing, and injected failure produces byte-exact state equal to one clean dependency-ordered coordinated run, with no stale frontier, missed transition, duplicate job, or claimable partial work.
- Context-free and context-aware actions for the same condition preserve identical lifecycle, refraction, retry, replacement, recovery, and at-least-once behavior; each receives the exact frozen argument value and produces the exact expected output.
- Fresh install and direct upgrade expose the exact public inventory and grant matrix: each role completes all and only its documented tasks, cross-role escalation attempts fail exactly, `PUBLIC` and private-schema access remain absent, and prior explicit grants are reconciled safely.
- Routine status, diagnostics, and task documentation use the frozen friendly vocabulary while exact history remains lossless and accessible through the documented advanced boundary.
- Crash/restart, supported physical restore, reconciliation, replacement, worker death, deadline catch-up, and direct upgrade from the populated `0.9.0` fixture preserve every inherited durable and external-effect guarantee.
- Every inherited M0–M12 semantic, operational, security, recovery, performance, compatibility, and external-effect gate passes unchanged.

### M13 completion record — 2026-08-12

The extension `0.10.0` repository candidate implements the named constraint,
activation, lifecycle, and deadline authoring surface; explicit-schema
immutable action resolution; context-free adapters; one dependency-ordered
coordinator run; friendly inspection vocabulary; exact four-role grants;
direct `0.9.0 -> 0.10.0` upgrade; and executable concurrency, failure, worker,
restart, and physical-recovery evidence in `tests/m13.sh`. The immutable
`v0.9.0` archive, checksum, OCI digest, and successful release workflow satisfy
the entry gate recorded in `docs/m13-entry.md`.

---

## Stage 14 — Explainability and reasoning UX

**Outcome:** make diagnosis, explanation, and derived reasoning PostgreSQL-native and name-first: one `doctor` identifies actionable installation or runtime problems, one `explain` traverses every supported rule and derivation evidence kind, and authors declare derived relations and programs without manually encoding inferable dependency graphs, components, or strata.

**Entry gate:** the exact `v0.10.0` release artifacts, checksums, disclosures, and populated direct-upgrade path are published and verified. Before the API contract is extended, freeze a reasoning task suite spanning ordinary rules, positive recursion, stratified negation, stratified aggregation, deadlines, multiple proof supports, absent and retracted facts, unhealthy installation and runtime states, ambiguous SQL dependencies, replacement, reconciliation, recovery, and upgrade; freeze its exact declarations, inferred graph, strata, diagnostics, explanations, and advanced evidence.

### Deliverables

- A read-only `doctor` entry point that checks extension and `pg_trickle` compatibility, required configuration and grants, source and action drift, coordinator and worker readiness, blocked or stale frontiers, failed jobs, reconciliation need, and upgrade state, returning ordered versioned diagnostics with concrete fixes.
- One overload-based, name-first `explain` family for rules, matches, jobs, derived facts, and programs that returns a common versioned envelope and the exact finite evidence already proved by M0–M13 without feature-specific routine names in ordinary workflows.
- PostgreSQL-native derived-relation and derivation-program authoring from schema-qualified relations, typed PostgreSQL row shapes, semantic keys, and SQL conditions, with validation and preview before atomic deployment or replacement.
- Deterministic inference of positive, negative, and aggregate dependencies, recursive components, and strata from the declared PostgreSQL relation graph wherever unambiguous; unresolved or unsupported structure is rejected with an exact diagnostic rather than silently guessed.
- Cleaner advanced inspection through an explicitly granted boundary with stable relational views or exact-identity overloads for immutable versions, activations, jobs, supports, components, frontiers, strata, and negative or aggregate evidence.
- One shared diagnostic and explanation vocabulary across ordinary rules and reasoning, plus exact compatibility rules for the M13 and older feature-specific explanation calls.
- A versioned extension and worker upgrade from `0.10.0`, task documentation from relation declaration through explanation and repair, and exact fresh-install, privilege, inference, ambiguity, failure, recovery, upgrade, and API-inventory evidence.

### Supported boundary

- M14 inherits M13's complete platform, execution, security, key-codec, recovery, worker-protocol, semantic, resource-limit, and external-effect boundary; it changes authoring and inspection, not truth semantics.
- Dependency inference is limited to the already supported positive, recursive, stratified-negative, and stratified-aggregate model. PostgreSQL object identity and validated relation structure remain authoritative.
- Explanations remain finite grounded evidence. They do not claim arbitrary base-tuple lineage, minimal proofs, counterfactual search, or justification for absent source facts.
- `doctor` observes and recommends through public state. It performs no repair, grant, configuration, deployment, retry, or destructive action.

### Explicit non-goals

- New aggregate functions, unstratified negation, recursive aggregation, temporal reasoning beyond M12 deadlines, probabilistic reasoning, confidence scores, or open-world semantics.
- Parsing arbitrary SQL into a second compiler, inferring dependencies through dynamic SQL or volatile functions, automatic common-subplan discovery, or a non-SQL rule DSL.
- Automatic remediation by `doctor`, unrestricted private-catalog access, full query-plan visualization, or unlimited proof enumeration.
- PostgreSQL-managed background workers, broader scalar key codecs, composite keys, or the complete README and usability qualification; those belong to M15.

### Decisions to close before the M14 contract freezes

- The exact `doctor` signature, diagnostic ordering and severity, redaction boundary, role visibility, readiness rules, and distinction between actionable failure and informational state.
- The `explain` overload set, target disambiguation, common envelope, depth and size bounds, absent-target behavior, and compatibility treatment of feature-specific explain calls.
- The derived-relation and program declaration shapes, preview/apply identity, replacement/removal policy, inferred-versus-explicit boundary, and exact use of PostgreSQL dependencies.
- Dependency-polarity recognition, component and stratum assignment, ambiguity rejection, graph hashing, DDL drift handling, and deterministic results across dump/restore and upgrade.
- The advanced inspection schema, immutable identifier access, role grants, retention visibility, redaction rules, and separation from routine name-first results.

### Exit gates

- `doctor` returns the exact ordered clean result on a healthy installation and exact actionable diagnostics for every frozen configuration, compatibility, privilege, drift, coordinator, worker, frontier, failure, reconciliation, and upgrade fault without changing database state.
- The unified `explain` calls return the exact complete envelope and finite grounded evidence for every frozen rule, match, job, recursive fact, negative check, aggregate condition, deadline, alternative support, retraction, and failure, equal to the inherited feature-specific evidence.
- A non-superuser author declares, validates, previews, deploys, replaces, removes, queries, and explains the frozen derived program using only PostgreSQL objects and the M14 public API, without supplying dependency polarity, component, stratum, support, or frontier identifiers.
- Inference produces the byte-exact frozen graph, components, strata, and portable identities across equivalent declaration order, replacement, dump/restore, and upgrade; every ambiguous, cyclic-invalid, unresolved, dynamic, volatile, or unsupported dependency fails exactly before mutation.
- Routine roles see only name-first diagnostics and explanations; the explicitly granted advanced reader can inspect the exact immutable evidence, and neither path exposes private catalogs or protected payloads outside its documented authority.
- Reconciliation, crash/restart, supported physical restore, concurrent DDL, program replacement, deadline catch-up, and direct upgrade from the populated `0.10.0` fixture preserve exact inferred structure, evidence, explanations, and inherited durable state.
- Every inherited M0–M13 semantic, operational, security, recovery, performance, compatibility, and external-effect gate passes unchanged.
- A new user can diagnose the frozen faults and complete the derived-reasoning workflow from task documentation using only `doctor`, unified `explain`, and PostgreSQL-native declarations.

---

## Stage 15 — Runtime and usability completion

**Outcome:** complete the PostgreSQL-facing redesign with a PostgreSQL-managed coordinator and worker in the normal public workflow, useful scalar and composite semantic keys, task-first README and examples, and executable usability qualification proving that a PostgreSQL user can install, author, run, explain, operate, recover, and upgrade pg-react without private knowledge or a separately supervised daemon.

**Entry gate:** the exact `v0.11.0` release artifacts, checksums, disclosures, and populated direct-upgrade path are published and verified. Before the runtime or key contract is fixed, freeze clean-install and populated-upgrade tasks covering managed-worker configuration, primary/standby and restart behavior, backpressure and failure, every proposed scalar codec, mixed-type composite keys, null and duplicate rejection, dump/restore portability, all four roles, the complete README workflow, troubleshooting, and rollback-by-restore; freeze exact durable state and user-visible results.

### Deliverables

- A PostgreSQL-managed background coordinator and worker path, configured through documented PostgreSQL settings and operated through the public API, that starts, stops, reports readiness, respects recovery and standby state, and preserves the inherited claim, lease, retry, batching, deadline, reconciliation, and at-least-once contracts.
- Public status, `doctor`, and runbook integration for managed-process configuration, protocol compatibility, database attachment, heartbeat, lag, backpressure, graceful shutdown, crash restart, promotion, and upgrade; routine operation requires no private catalog queries or direct worker-protocol calls.
- A frozen portable key-codec matrix broader than `bigint`, including at least scalar `uuid` and `text` plus ordered mixed-type composite keys over supported scalar codecs, with PostgreSQL typed equality, explicit column order, non-null components, deterministic identity, exact diagnostics, and physical backup/restore and dump/restore evidence.
- End-to-end propagation of every supported key through matching, activations, jobs, retries, derivation, recursion, negation, aggregation, deadlines, reconciliation, history, status, diagnostics, unified explanation, replacement, and recovery without lossy text coercion.
- A task-first README and compact examples that use only the final public vocabulary and API for installation, role setup, ordinary rules, lifecycle actions, derived programs, `run`, managed workers, `doctor`, `explain`, backup/restore, upgrade, and troubleshooting.
- A recorded usability qualification in which a PostgreSQL user follows the shipped documentation from a clean supported instance and completes the frozen author, operator, worker, reader, failure-diagnosis, recovery, and upgrade tasks with exact expected commands, outputs, and completion criteria.
- A versioned extension upgrade from `0.11.0`, managed-worker transition rules for existing bundled-worker deployments and pending work, and exact fresh-install, API-inventory, privilege, codec, concurrency, failure, recovery, documentation, and upgrade evidence.

### Supported boundary

- M15 inherits M14's reasoning, execution, security, maintenance, isolation, RLS, recovery, resource-limit, external-effect, and supported-platform boundary except for the explicitly frozen worker-management and key-codec expansions.
- Managed workers run only in explicitly configured databases on primaries, use the frozen worker protocol and public privilege boundary, and stop safely when compatibility, recovery, upgrade, or health checks prohibit claims.
- Semantic keys are ordered typed tuples from the frozen scalar allow-list. Every component is non-null; PostgreSQL equality is authoritative; schema or collation changes that would alter identity block work until explicit replacement or recovery.
- The bundled external worker may remain only where the frozen transition and compatibility matrix says so; one durable job can never be claimed by both execution paths outside the inherited lease protocol.

### Explicit non-goals

- General-purpose job scheduling, arbitrary background processes, cross-cluster coordination, exactly-once external effects, automatic high availability orchestration, or synchronous action completion inside `run`.
- Arbitrary user-defined key codecs, nullable key components, unordered key maps, mutable key types, general base-tuple lineage, RLS sources, or support for every PostgreSQL type and collation.
- New reasoning semantics, richer aggregates, event-time windows, immediate maintenance, shared-condition optimization, catalog partitioning, or retention redesign.
- A custom DSL, client SDK, web console, visual or AI authoring, or documentation of private engine catalogs as a normal operating path.

### Decisions to close before the M15 contract freezes

- Static versus dynamic background-worker registration, required preload settings, per-database configuration, process counts, restart policy, latch and signal handling, transaction ownership, resource bounds, and primary/standby promotion behavior.
- Managed and external worker coexistence, protocol negotiation, claim fencing, graceful drain, upgrade order, configuration reload, observability, and rollback-by-restore procedure.
- The exact scalar codec allow-list, composite arity and storage format, canonical binary identity, collation and domain handling, index strategy, diagnostic rendering, and portable upgrade or dump/restore encoding.
- The final public API and vocabulary inventory, compatibility treatment of superseded M11–M14 surfaces, role grants, example set, README information architecture, and removal of provisional documentation.
- The usability-task harness, supported user assumptions, exact outputs, completion thresholds, failure scenarios, evidence retention, and release-blocking policy.

### Exit gates

- On a clean supported primary, documented configuration starts the managed coordinator and worker, `doctor` reports the exact ready state, `run` and deadline evaluation create the exact jobs, actions complete with inherited lease and retry behavior, and clean shutdown or restart loses or duplicates no work.
- Managed processes make no claims on a standby or during incompatible recovery or upgrade state; crash, restart, backpressure, configuration reload, promotion, and worker replacement produce the exact frozen health, lag, claim, attempt, and recovery history.
- Every supported scalar and composite key fixture produces exact typed matches, deterministic identities, jobs, facts, supports, histories, and explanations across source changes, rule or program replacement, retry, reconciliation, physical restore, dump/restore, and direct upgrade; null, duplicate, unsupported, collated-unstable, or drifted keys fail exactly without partial mutation.
- Concurrent managed and permitted external workers obey one claim and lease contract, never execute one attempt twice without an inherited lease-expiry or at-least-once cause, and drain pending protocol-compatible work through the documented transition.
- Fresh install and direct upgrade expose exactly the final public inventory and author, operator, worker, reader, and advanced-reader grants; no routine task requires `pgreact_internal`, `pgreact_runtime`, raw protocol calls, or manually supplied engine identifiers.
- Every README and shipped example executes unchanged on a clean supported installation and returns the exact documented output; every linked installation, authoring, operation, reasoning, security, recovery, upgrade, and troubleshooting task uses only the final public contract.
- Independent task-level qualification completes every frozen workflow and fault-recovery task within its declared steps, with no undocumented command, privilege escalation, daemon supervisor, private-catalog query, or maintainer interpretation.
- Direct upgrade from the populated `0.11.0` fixture preserves byte-exact durable state and pending work while adding managed-worker and expanded-key metadata deterministically; rollback by restoring the documented backup remains valid.
- Every inherited M0–M14 semantic, operational, security, recovery, performance, compatibility, and external-effect gate passes unchanged. The PostgreSQL-facing redesign is substantially complete when all M13–M15 gates pass and the final inventory, grants, documentation, and usability evidence are published.

---

## Stage 16 — Richer stratified aggregation

**Outcome:** extend the proven stratified aggregate model from keyed `COUNT(*)` thresholds to one typed `COUNT(expression)`, `SUM`, `MIN`, or `MAX` dependency per rule, preserving exact PostgreSQL value semantics, deletion-sensitive truth transitions, finite evidence, atomic strata, and recovery.

**Entry gate:** the exact `v0.12.0` release artifacts, checksums, disclosures, OCI digest, and populated direct-upgrade path are published and verified. Before the aggregate contract is fixed, freeze a bounded reference program covering `COUNT(*)`, `COUNT(expression)`, `SUM`, `MIN`, and `MAX`; null and empty inputs; supported numeric, ordered, and collated types; overflow and rejected types; updates and retractions that do and do not cross comparisons; replacement, reconciliation, crash/restart, physical and logical recovery, and direct upgrade; freeze its exact declarations, graph, facts, supports, aggregate evidence, frontiers, diagnostics, and explanations.

### Deliverables

- A PostgreSQL-native aggregate declaration surface for `COUNT(expression)`, `SUM`, `MIN`, and `MAX` alongside inherited `COUNT(*)`, with one immutable typed value expression, one comparison, and one typed threshold per aggregate dependency.
- Deployment-time resolution and validation of expression dependencies, input and result types, casts, collation, volatility, authorization, and schema identity, with exact drift detection and no search-path-dependent retargeting.
- Dependency-ordered evaluation that uses PostgreSQL's aggregate, null, comparison, and overflow behavior after the strictly lower stratum converges and commits every affected result at one program frontier.
- Deletion-sensitive maintenance in which insertion, update, null transition, or removal produces the exact typed aggregate value and creates, updates, or retracts only the corresponding higher-stratum support.
- Stable public evidence and unified explanation that identify the aggregate function, value expression, input and result types, group key, exact current value, comparison, threshold, lower frontier, and truth result without enumerating every input row.
- Atomic validation, preview, deployment, replacement, removal, reconciliation, retention, and recovery through the final M15 public API and role boundary, including deterministic resource limits and actionable diagnostics.
- Extension `0.13.0`, worker compatibility and direct upgrade from `0.12.0`, compact author and operator tasks, and exact fresh-install, API-inventory, privilege, semantic, failure, recovery, logical-restore, and upgrade evidence.

### Supported boundary

- M16 inherits M15's platform, public API, managed-worker, typed-key, security, maintenance, isolation, recovery, resource-limit, external-effect, and usability boundary except for the explicitly frozen aggregate expansion.
- A rule still declares exactly one aggregate dependency and one aggregate function. Its group key is positively bound, equals the derived fact's semantic key, and reads one finite authoritative or derived relation in a strictly lower, non-recursive stratum.
- `COUNT(expression)` ignores null expression results; `SUM`, `MIN`, and `MAX` ignore null inputs and yield PostgreSQL's typed null result when no non-null input remains. PostgreSQL casting, collation, comparison, three-valued logic, and overflow behavior is authoritative within the frozen type allow-list.
- Positive recursion and stratified negation retain their inherited boundaries. No dependency cycle contains a negative or aggregate edge, and downstream lifecycle rules observe only complete aggregate frontiers.

### Explicit non-goals

- Same-stratum or recursive aggregation, aggregate cycles, multiple aggregate dependencies or functions per rule, or aggregate results that feed their own input.
- `DISTINCT`, `FILTER`, `AVG`, ordered-set or user-defined aggregates, grouping sets, arbitrary `HAVING` expressions, or unrestricted SQL expressions.
- Temporal aggregation, event-time or processing-time windows, watermarks, lateness, corrections, sliding windows, or session windows; the bounded event-time model belongs to M17.
- Immediate or synchronous consequences, automatic shared-condition discovery, catalog partitioning, or retention redesign; those remain later milestones.
- New key codecs, RLS source support, isolation levels, worker protocols, platform versions, general base-tuple lineage, or unbounded proof enumeration.

### Decisions to close before the M16 contract freezes

- The exact aggregate declaration and overload shapes, expression-recognition boundary, comparison operators, threshold coercion rules, preview format, and compatibility treatment of M10 declarations.
- The frozen input and result type allow-lists for each function, including domains, numeric widening, collation-sensitive order, timestamp order, special values, and exact overflow or unsupported-type diagnostics.
- Expression immutability, nullability, dependency identity, authorization, drift detection, canonical rendering, and rejection of ambiguous, volatile, set-returning, aggregate, or windowed expressions.
- Aggregate evidence and support identity across value changes, null transitions, repeated runs, replacement, reconciliation, retention, dump/restore, and upgrade, including changes that do not flip truth.
- Evaluation strategy, indexes, locking, work and memory bounds, failure rollback, and deterministic ordering when several lower-stratum changes affect one group or several strata in one run.

### Exit gates

- The frozen program returns the exact PostgreSQL result, comparison truth, facts, supports, evidence, frontiers, and explanations for every supported aggregate, type, null case, empty case, special value, and threshold transition.
- Every supported ordering of equivalent inserts, updates, deletions, null transitions, run scheduling, worker timing, and incremental history produces byte-exact current state equal to a clean dependency-ordered recomputation.
- Crossing a comparison in either direction creates or retracts the exact higher support; a value change that leaves comparison truth unchanged updates evidence without a false fact or downstream lifecycle transition.
- All affected strata commit at one complete frontier. Expression evaluation, overflow, resource-limit, catalog, or injected refresh failure preserves the previous complete state and exposes no partial result.
- Deployment rejects every frozen recursive, cyclic, same-stratum, multiple, unbound, volatile, ambiguous, unauthorized, drifted, unsupported-function, unsupported-type, unsupported-expression, or invalid-threshold declaration with exact diagnostics and no mutation.
- Replacement, removal, reconciliation, crash/restart, managed-worker restart, physical restore, dump/restore, and direct `0.12.0 -> 0.13.0` upgrade preserve or repair the exact graph, typed values, facts, supports, evidence, frontiers, diagnostics, and explanations.
- Every inherited M0–M15 semantic, operational, security, recovery, performance, compatibility, documentation, usability, and external-effect gate passes unchanged.
- A non-superuser author and operator can declare, validate, preview, deploy, run, query, explain, cross and recross comparisons, reconcile, replace, recover, and upgrade the reference aggregate program using only public APIs and documentation.

---

## Stage 17 — Event-time windows

**Outcome:** extend M16's stratified aggregate model with one fixed-duration event-time tumbling window per aggregate dependency, using explicit timestamps, durable monotone watermarks, bounded lateness, and deterministic corrections while preserving exact PostgreSQL value semantics, finite evidence, atomic strata, and recovery.

**Entry gate:** the exact `v0.13.0` release artifacts, checksums, disclosures, OCI digest, and populated direct-upgrade path are published and verified. Before the window contract is fixed, freeze a bounded reference program covering every supported aggregate; exact boundary timestamps; windows emptied by retraction; in-order and out-of-order timed-input inserts, updates, window moves, and deletes; replayed maintenance frontiers; repeated, backward, and jumping watermark targets; on-time, correctably late, and finalized-window inputs; replacement, reconciliation, crash/restart, physical and logical recovery, and direct upgrade; freeze its exact declarations, window assignments, aggregate values, facts, supports, correction history, frontiers, diagnostics, and explanations.

### Deliverables

- A PostgreSQL-native declaration surface that adds one direct finite non-null `timestamptz` event-time column, one fixed positive duration, and one finite allowed-lateness interval to an inherited M16 aggregate dependency.
- Stable UTC-epoch-aligned half-open `[start, end)` windows whose derived fact semantic key is the existing ordered composite-key encoding of the typed group key plus a signed `bigint` window ordinal, independent of session time zone, declaration order, physical row order, and restart.
- One monotone requested watermark and one durable complete watermark per declared input, advanced and inspected through the public API; the coordinator progresses toward the target in idempotent bounded batches and atomically finalizes every materialized window crossed before reporting the target complete.
- Dependency-ordered maintenance that accepts out-of-order timed input until finalization, folds each committed lower-frontier delta into one canonically ordered aggregate correction per affected window fact, and commits aggregate values, truth, supports, evidence, downstream lifecycle work, and frontiers atomically.
- Stable public evidence and unified explanation that identify the event-time column, window duration and fixed alignment, window start and end, requested and complete watermarks, allowed-lateness boundary, finalization state, aggregate value, correction identity and lower frontier, and truth result without enumerating every input row.
- Atomic validation, preview, deployment, replacement, removal, reconciliation, retention, and recovery through the inherited public API and role boundary, with actionable diagnostics for invalid declarations, invalid watermark movement, and input beyond the finalized boundary.
- Extension `0.14.0`, worker compatibility and direct upgrade from `0.13.0`, compact author and operator tasks, and exact fresh-install, API-inventory, privilege, semantic, concurrency, failure, recovery, logical-restore, and upgrade evidence.

### Supported boundary

- M17 inherits M16's platform, public API, managed-worker, typed-key, security, maintenance, isolation, recovery, resource-limit, external-effect, aggregate, and usability boundary except for the explicitly frozen event-time expansion.
- A rule still declares exactly one aggregate dependency and function over one finite authoritative or derived relation in a strictly lower, non-recursive stratum. The positively bound group key has at most three M15 scalar components; the derived fact key appends the UTC-epoch-relative `bigint` window ordinal within M15's four-component codec and does not relax any aggregate-cycle restriction.
- Timed-input timestamps use PostgreSQL `timestamptz` comparison semantics but must be direct, finite, non-null values. Windows are fixed-duration, UTC-epoch-aligned, and half-open; a timestamp exactly at a boundary belongs to the window beginning at that boundary.
- Only windows touched by timed input are materialized; deleting their last input retains an empty aggregate window through finalization, while untouched empty windows are never synthesized.
- A materialized window accepts corrections while the complete watermark is strictly before `window_end + allowed_lateness`. It becomes final when the watermark reaches that boundary, and later input follows the frozen too-late policy without exposing partial or silently divergent state.
- Consequences remain asynchronous and at-least-once. Watermark advancement determines logical completeness, not wall-clock execution latency or external-effect completion.

### Explicit non-goals

- Sliding, hopping, session, calendar, dynamically aligned, processing-time, ingest-time, or unbounded windows; temporal joins; recurrence; interval algebra; pattern matching; or general complex-event processing.
- Multiple windows or aggregate dependencies per rule, nested windows, windowed recursion, recursive aggregation, aggregate cycles, or cross-window feedback.
- Automatic watermark inference from clocks or observed maxima, cross-source watermark coordination, speculative results beyond the durable watermark, retraction of finality, or unbounded lateness.
- General row-level ingestion, source-table change capture, stream brokering, global timed-input ordering, exactly-once external effects, or synchronous consequence completion.
- New aggregate functions, key codecs, RLS source support, isolation levels, worker protocols, platform versions, general input-row lineage, or unbounded correction and proof enumeration.

### Decisions to close before the M17 contract freezes

- The exact declaration and overload shapes, duration and lateness bounds, canonical duration rendering, timestamp-type boundary, window-ordinal calculation and range, compatibility treatment of M16 declarations, composite-key rendering, and preview format.
- Watermark ownership, target signature, authorization, transactional scope, scheduling, persistence, idempotency, backward and concurrent target behavior, batch bound and continuation behavior, target-versus-complete reporting, and primary/standby rules.
- The exact admission and diagnostic policy for timed input at or beyond finality, claim barriers, and operator recovery after an authoritative late-data violation.
- Aggregate-correction identity and canonical ordering by window fact and committed lower frontier across inserts, updates, moves, deletes, replayed frontiers, replacement, reconciliation, and downstream lifecycle events, including changes that do not flip aggregate truth.
- Window, watermark, correction, and finalization evidence; retention and pruning constraints; resource limits; indexes; lock order; failure rollback; drift detection; and deterministic behavior across dump/restore and upgrade.

### Exit gates

- The frozen program returns the exact PostgreSQL window assignment, aggregate value, comparison truth, facts, supports, evidence, frontiers, and explanations for every supported function, type, boundary timestamp, window emptied by retraction, valid null aggregate expression, and threshold transition.
- Every supported ordering of equivalent timed-input inserts, updates, moves, deletes, refreshes, watermark targets, run scheduling, and worker timing produces byte-exact canonical current state equal to one clean event-time-ordered recomputation at the same complete watermark; each frozen arrival/frontier schedule also produces its exact correction history, and replaying a frontier adds none.
- Every correctably late lower-frontier delta updates every and only affected old and new window aggregate, support, explanation, and downstream lifecycle transition; changes that preserve truth update evidence without a false transition, and finalized-window input follows the exact frozen policy.
- Repeated completed watermark targets are no-ops, repeating an incomplete target resumes from the complete watermark, backward targets fail without mutation, and forward jumps progress in bounded batches that finalize every and only eligible materialized window once before reporting completion. Resource-limit, catalog, expression, or injected failure retains the last complete batch and remains safely resumable.
- Validation or refresh rejects every frozen null or infinite event-time value, computed, volatile, unauthorized, drifted, unsupported-type, invalid-duration, invalid-lateness, multiple-window, nested, recursive, cyclic, same-stratum, unbound, or incompatible declaration or input with exact diagnostics and no partial mutation.
- Replacement, removal, reconciliation, crash/restart, managed-worker restart, physical restore, dump/restore, and direct `0.13.0 -> 0.14.0` upgrade preserve or repair the exact declarations, watermarks, windows, aggregate values, facts, supports, corrections, frontiers, diagnostics, and explanations.
- Retention cannot prune input summaries, corrections, finalization evidence, or identities still required by an open window, pending work, reconciliation, replay, rollback, explanation, or the published recovery horizon; every permitted prune is audited exactly.
- Every inherited M0–M16 semantic, operational, security, recovery, performance, compatibility, documentation, usability, and external-effect gate passes unchanged.
- A non-superuser author and operator can declare, validate, preview, deploy, run, advance, inspect, explain, correct, finalize, reconcile, replace, recover, and upgrade the reference windowed program using only public APIs and documentation.

---

## Stage 18 — Production usability and hardening

**Outcome:** prove that the complete M0–M17 product is understandable, operable, measurable, diagnosable, recoverable, and upgradeable by a normal PostgreSQL developer through public APIs and documented procedures, without adding rule-engine semantics.

**Entry gate:** the exact `v0.14.0` release artifacts, checksums, disclosures, OCI digest, SBOM if already available, and populated direct-upgrade path are published and verified, and every M0–M17 gate passes unchanged. Before usability, diagnostic, benchmark, recovery, or release work begins, freeze the M18 entry fixture, its M17 semantic and state invariants, and its `0.14.0` reference results; freeze changed M18 public transcripts only after the usability and diagnostic contract closes.

### Frozen entry fixture

- One versioned manifest fixes the supported PostgreSQL and extension versions, toolchain, host and PostgreSQL configuration, random seed, wall-clock inputs, roles and grants, schemas, declarations, populated data, pending work, expected public transcripts, normalized state checksums, and artifact checksums.
- The fixture contains five canonical workloads: risk/fraud with a suspicious-transfer constraint and review command; inventory with stock derivation and reorder aggregate; SLA/deadline with overdue lifecycle and escalation command; derived knowledge with positive recursion and stratified absence; and event-time windows with tumbling aggregates, out-of-order input, corrections, and finalization.
- A small profile is the exact 10–15 minute authoring and documentation oracle. A populated profile freezes named, non-Cartesian benchmark cases drawn from `1`, `10`, `100`, and `1,000` deployed rules; `10^3`, `10^5`, and `10^6` authoritative plus derived facts; single-row, `100`-row, and `10,000`-row update batches; `1` and `4` workers; `10^3` and `10^5` materialized windows; and watermark advances finalizing `0`, `10^3`, and `10^5` windows. The manifest states every tested combination explicitly.
- The populated `0.14.0` image, physical backup, logical dump, and expected post-restore and post-upgrade checksums include active and inactive matches, pending and retryable work, derived and aggregate facts, open and finalized windows, late corrections, watermarks, and reconciliation evidence.
- Frozen faults cover incompatible configuration, missing privilege, source and action drift, a blocked frontier, worker loss during a lease, failed work, an interrupted watermark advance, injected repairable state drift, crash/restart, restore, and upgrade. Each fault has one exact public diagnosis, documented repair, and expected continued result.

### Deliverables

- One copy-and-run, public-API-only authoring path that a PostgreSQL developer can complete in 10–15 minutes and that creates, runs, inspects, and explains representative constraint, command, derivation, aggregate, and windowed rules with exact expected output.
- Production-quality, tested risk/fraud, inventory, SLA/deadline, derived-knowledge, and event-time-window examples, each with data model, declarations, normal operation, failure behavior, resource assumptions, cleanup, and the limits it does not solve.
- Integrated, backward-compatible coverage of the existing name-first `doctor`, `status`, `explain`, and diagnostic surfaces, filling only demonstrated gaps for installation, compatibility, configuration, grants, drift, worker health, leases and retries, queue and update lag, blocked programs, watermarks, failed work, reconciliation need, recovery, and upgrade, with concrete public remediation commands.
- Progressive disclosure that keeps supports, components, strata, frontiers, correction identities, immutable engine identifiers, and worker-protocol internals out of ordinary author and operator tasks; explicitly requested deep diagnosis may expose the minimum advanced evidence through its existing granted public boundary.
- A deterministic benchmark harness and published hardware-specific performance and resource envelope for deployed-rule count, authoritative and derived fact count, update throughput and latency, worker throughput and latency, materialized-window count, no-op and finalizing-watermark cost, database growth, peak memory, crash-restart and restore time, and every measured cliff.
- A checked-in benchmark baseline and machine-readable regression budget using three warmups and five measured runs on the pinned runner. Every named case fixes the per-run sample count used to compute median and p95 and one deterministic rerun policy for host noise: median update and worker throughput may fall by at most `10%`; p95 update, worker, watermark, and recovery latency may rise by at most `20%`; and peak memory and database size may rise by at most `15%`.
- Repeatable crash/restart, physical backup/restore, logical dump/restore, reconciliation, and direct `0.14.0 -> 0.15.0` upgrade drills over the populated fixture, with exact pre-failure and post-recovery state, queued-work, explanation, and continued-execution oracles and published recovery times.
- Pinned CI actions by full commit SHA, pinned Rust/PostgreSQL/pgrx and release toolchains, locked dependencies, least-privilege workflow permissions, dependency and advisory checks, release checksums, an SPDX or CycloneDX SBOM, provenance attestations, and artifact or OCI signing where the release platform supports them; every omission has a documented verification substitute and owner.
- One authoritative release-state and support statement, with stale milestone/readiness claims removed or linked to that statement, plus executable link, snippet, API-inventory, and release-claim checks across shipped documentation.
- One end-to-end day-2 operations fixture that starts with the populated workloads, diagnoses worker loss and injected state drift through public output, performs documented restart and reconciliation, has an administrator perform the direct extension upgrade, then has the frozen non-superuser roles resume queued work and watermark progress, apply new input, and verify exact continued results.
- Extension `0.15.0`, release notes, compatibility inventory, and a direct upgrade from `0.14.0` that change no M0–M17 truth, lifecycle, ordering, recovery, or external-effect contract.

### Supported boundary

- M18 inherits the complete M17 platform, public API, managed-worker, typed-key, security, maintenance, isolation, recovery, resource-limit, external-effect, aggregate, window, and usability boundaries unchanged.
- M18 may make backward-compatible improvements to diagnostic labels, summaries, remediation text, documentation, testability, instrumentation, packaging, and measured implementation performance. It does not rename or remove an existing public API or result field without the inherited compatibility and deprecation process. Existing public repair and reconciliation operations remain authoritative; diagnostic entry points do not silently mutate state.
- Ordinary workflows use stable public names and domain values. Advanced evidence is opt-in, role-checked, bounded, and needed only when a public diagnosis cannot identify the exact failure or repair target.
- Performance claims apply only to the published hardware, PostgreSQL configuration, dataset, concurrency, and measurement method. The supported envelope ends before a measured cliff; M18 does not imply a universal throughput or recovery SLA.

### Explicit non-goals

- Any new reasoning or runtime semantics, including selective immediate maintenance, shared maintained conditions, synchronous rule sets, new recursion or negation behavior, new aggregate or window kinds, richer provenance, automatic repair, or a new worker protocol. Selective immediate maintenance is M19 at the earliest.
- Changes to truth, support, lifecycle, frontier, watermark, correction, ordering, delivery, retry, retention, or recovery guarantees proved by M0–M17.
- A client DSL or SDK, visual or AI authoring, web console, hosted control plane, domain-package framework, or private-catalog runbook.
- Expansion of the supported PostgreSQL, `pg_trickle`, OS, architecture, isolation, RLS, key-codec, or deployment matrix without separate evidence and scope.
- Performance claims outside the frozen envelope, speculative performance rewrites, benchmark-only shortcuts, or hiding a cliff by reducing correctness checks or fixture realism.
- M19 implementation or preparatory abstractions for any later semantic milestone.

### Exit gates

All automatable M18 gates are release-blocking targets of one documented `tests/m18.sh` orchestrator. Its fast correctness profile runs in ordinary CI; its complete benchmark and recovery profile runs on the pinned release runner. Both start from a clean supported instance, select the frozen profile explicitly, record exact artifacts, and exit nonzero on any mismatch or applicable budget breach. Publication requires the checksummed complete-profile artifacts plus the separately recorded human usability evidence.

- The automated small-profile authoring target completes the documented constraint, command, derivation, aggregate, and windowed path in at most `15` minutes, using only public APIs and the documented non-superuser grants, and produces the exact frozen transcript and final state.
- Separately, an independently observed normal PostgreSQL developer completes the same path in at most `15` minutes. The release evidence records the environment, role, elapsed time, exact transcript and final state, and every deviation; this is a release-blocking evidence gate, not a shell-test assertion.
- Every canonical example installs and runs unchanged from its documentation on a clean instance and returns its exact complete expected rows, diagnostics, explanations, jobs, facts, aggregates, windows, and cleanup result; examples contain no private-catalog query or unexplained advanced term.
- The complete frozen fault matrix returns the exact ordered `doctor`, `status`, `explain`, and diagnostic output, names the affected public object and next public remediation command, leaks no unauthorized payload, and requires no private catalog. The healthy fixture returns the exact clean result.
- The release benchmark profile executes every named benchmark case and publishes update throughput, worker throughput, p50 and p95 latency, peak memory, database size, window and watermark cost, crash-restart time, physical-restore time, logical-restore time, and known cliffs. It fails under the frozen rerun policy if correctness differs, a cliff enters the published supported envelope, or any `10%` throughput, `20%` latency/recovery, or `15%` resource budget is exceeded. The fast profile runs only the frozen correctness sentinels.
- Crash at every frozen injection point, managed-worker restart, physical restore, logical restore, reconciliation of every injected drift, and direct upgrade converge to the exact frozen checksums, public explanations, watermarks, and queued-work state. Each measured recovery completes within its published envelope and no more than `20%` above its checked-in p95 baseline.
- The day-2 target diagnoses worker loss and drift and repairs them through documented public procedures; an administrator performs the direct extension upgrade, after which the frozen non-superuser roles resume pending work and an interrupted watermark, accept post-upgrade input, and reach the exact final transcript and state without private-catalog access or maintainer interpretation.
- The release audit fails on an unpinned CI action or toolchain, excessive workflow permission, undeclared release credential, lockfile drift, applicable unacknowledged advisory, checksum mismatch, or missing required SBOM, provenance, or signature. A platform exception is explicit, scoped, owned, and paired with the frozen substitute verification.
- The documentation audit executes every command and SQL snippet, verifies every internal link and public API name, and rejects duplicated or stale milestone, readiness, version, support, or upgrade claims that contradict the authoritative release-state statement.
- An administrator performs the fresh extension installation, required configuration, and direct extension upgrade, which expose exactly the documented public inventory and grants. Thereafter the frozen non-superuser roles can author, run, inspect, explain, benchmark, diagnose, repair, recover, and upgrade all representative application workloads using only public APIs and documented procedures, without private-catalog access.
- Every inherited M0–M17 semantic, operational, security, recovery, performance, compatibility, documentation, usability, and external-effect gate passes unchanged.

---

## Stage 19 — Selective immediate maintenance

**Outcome:** add an explicit, bounded read-your-writes path for eligible constraint rules and finite database-local derivations while keeping scheduled maintenance as the default and every arbitrary or external consequence asynchronous.

**Entry gate:** the exact `v0.15.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, including the independent M18 usability evidence, and every M0–M18 gate passes unchanged. Before the public contract freezes, capture the pinned `pg_trickle` immediate-maintenance capability matrix and a reference fixture covering eligible and rejected declarations; inserts, updates, deletes, multi-statement transactions, savepoints, rollback, and abort; one constraint and one finite acyclic derivation chain; concurrent writers; replacement, reconciliation, crash/restart, physical and logical recovery, and direct upgrade; freeze its exact public declarations, visible facts, matches, activations, supports, evidence, agenda state, diagnostics, explanations, lock outcomes, and final database state.

### Deliverables

- A PostgreSQL-native, per-version opt-in for immediate maintenance. Scheduled `DIFFERENTIAL` remains the default, and validation rejects an ineligible rule, program, dependency, query, source, DML shape, or platform tuple before creating or changing durable runtime state.
- One public compatibility contract tied to the pinned PostgreSQL and `pg_trickle` tuple that names every supported immediate query and DML shape, the required critical observer, the exact `READ COMMITTED` visibility point, lock scope and order, conflict behavior, and the fallback or rejection for every unsupported case.
- Same-transaction visibility after each supported source statement: the issuing transaction can read the final maintained match or derived relation and corresponding current pg-react truth through public APIs before commit. Match state, activations, supports, evidence, lifecycle changes, and durable agenda changes commit or roll back atomically with the source write.
- Dependency-ordered immediate maintenance for one validated finite acyclic positive derivation closure. Every member must opt in and pass the same capability checks; an edge into a scheduled rule or program is an explicit asynchronous boundary rather than a claim of transitive read-your-writes behavior.
- Deterministic transaction-local handling of repeated changes to one semantic key, including activate/change/deactivate oscillation, subtransactions, savepoints, statement failure, and full rollback, with no uncommitted episode visible to a worker and no consequence surviving an aborted source transaction.
- Public validation, preview, status, doctor, and explanation output that identifies the selected maintenance mode, eligibility, visibility boundary, blocking dependency or source shape, lock/conflict outcome, and the exact public remediation without requiring private-catalog inspection.
- Executable correctness, concurrency, failure, recovery, performance, compatibility, security, and direct-upgrade evidence for both immediate and inherited scheduled paths, plus extension `0.16.0`, release notes, compatibility inventory, compact author and operator tasks, and a direct upgrade from `0.15.0`.

### Supported boundary

- M19 inherits the complete M18 platform, public API, managed-worker, typed-key, security, maintenance, isolation, recovery, resource-limit, external-effect, aggregate, window, diagnostic, and usability boundaries except for this explicit immediate-maintenance expansion.
- Immediate maintenance is opt-in and limited to the frozen query, dependency, source, and DML capability matrix under `READ COMMITTED` on the pinned platform tuple. A declaration outside that matrix fails explicitly; it is never silently downgraded or partially maintained.
- The immediate derivation closure is finite, acyclic, positive, and database-local. Constraint matches and derived facts may become visible in the source transaction, but downstream scheduled rules cross the ordinary committed asynchronous frontier.
- Existing lifecycle and at-least-once delivery semantics remain authoritative. Immediate maintenance may create or withdraw durable agenda work atomically, but workers observe only committed work and arbitrary user or external code never runs in the source statement.
- Concurrency follows one published lock order and bounded wait/error policy. Every frozen conflicting schedule either produces the documented state equivalent to an allowed serialization or fails with an exact diagnostic and leaves no partial state.

### Explicit non-goals

- Synchronous command, outbox, manual, network, file, LLM, or other arbitrary consequence execution; rejecting a source write as a policy action; exactly-once external effects; or a general synchronous firing loop.
- Immediate recursion, stratified negation, aggregates, event-time windows, deadline clocks, corrections, watermark advancement, cyclic programs, or a scheduled member inside one claimed immediate closure; a scheduled downstream consumer remains outside that closure.
- Automatic immediate-mode selection, automatic common-subplan discovery, a second source-table trigger or CDC system, a new worker protocol, cross-database transactions, or global ordering across unrelated rules.
- New isolation levels, RLS sources, key codecs, PostgreSQL or `pg_trickle` versions, operating systems, architectures, or performance promises outside the frozen immediate envelope.
- Shared conditions, retention redesign, richer provenance, practical temporal primitives, effective-dated policy, or preparatory abstractions for M20 and later milestones.

### Decisions to close before the M19 contract freezes

- The exact declaration, preview, replacement, and upgrade shapes; eligible constraint and derivation forms; supported source, query, dependency, and DML matrix; observer capability detection; and whether unsupported existing declarations remain scheduled or require explicit replacement.
- The precise visibility point after each statement and at commit, including transaction-start versus statement-start truth, transition coalescing, stable activation and episode identity, repeated semantic-key changes, savepoints, subtransactions, statement failure, transaction abort, and interaction with public reads and explicit refresh commands.
- Lock identities, acquisition order, granularity, bounded wait and timeout behavior, deadlock prevention, concurrent DDL and replacement behavior, and the exact accepted or rejected schedules for overlapping writers and derivation closures.
- Atomic lifecycle and agenda behavior when immediate truth activates, changes, deactivates, or oscillates; committed history and explanation rendering; worker claim barriers; downstream scheduled invalidation; and deterministic ordering across several affected keys and dependencies.
- Resource limits, indexes, cost admission, transaction-latency envelope, drift detection, reconciliation, retention, failure injection, crash recovery, physical and logical restore, standby behavior, and downgrade or direct-upgrade treatment of immediate declarations and in-flight state.

### Exit gates

- After every supported insert, update, delete, and multi-statement sequence in the frozen fixture, the issuing transaction reads the exact expected match relation, derived relation, current facts, activations, supports, evidence, explanations, and agenda state before commit; a separate session sees none of it before commit and the exact same state after commit.
- Full rollback, statement failure, and rollback to every frozen savepoint restore the exact source, maintained, lifecycle, support, evidence, and agenda state, expose no worker-claimable episode, and leave no orphaned frontier, lock, or reconciliation barrier.
- Every equivalent supported DML ordering and every accepted concurrent schedule produces the exact canonical state and lifecycle history specified by the contract; every rejected conflict returns its exact diagnostic without partial mutation, missed truth, duplicate episode, or deadlock beyond the published bound.
- Validation rejects every frozen unsupported mode, query, source, DML, dependency, recursion, negation, aggregate, window, deadline, isolation, platform, privilege, drift, resource-limit, or mixed-closure case before durable mutation and names the exact incompatible object and remediation.
- The same reference rules in scheduled mode retain their M0–M18 results, ordering, recovery, performance, and asynchronous behavior; opting one eligible version into immediate mode changes only the frozen visibility and timing contract.
- Replacement, removal, reconciliation, crash/restart, managed-worker restart, physical restore, dump/restore, and direct `0.15.0 -> 0.16.0` upgrade preserve or repair the exact mode, declarations, generated objects, facts, activations, supports, evidence, agenda state, diagnostics, explanations, and continued immediate behavior.
- Every inherited M0–M18 semantic, operational, security, recovery, performance, compatibility, documentation, usability, and external-effect gate passes unchanged.
- A non-superuser author and operator can validate, preview, deploy, exercise, inspect, explain, diagnose, reconcile, replace, recover, and upgrade the reference immediate constraint and derivation program using only public APIs and documentation.

---

## Stage 20 — Shared conditions

**Outcome:** let authors define one business concept as an explicitly named, versioned, maintained SQL relation that compatible rules can consume through one governed truth boundary, without duplicating its meaning or introducing a second execution model.

**Entry gate:** the exact `v0.16.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, and every M0–M19 gate passes unchanged. Before the public contract freezes, capture a reference fixture with one typed shared condition consumed by constraint, command, and derivation rules; scheduled and eligible immediate maintenance; independent condition and consumer owners; named fan-out and resource profiles; compatible and incompatible replacement; removal, drift, reconciliation, concurrent source and deployment changes, crash/restart, physical and logical recovery, and direct upgrade; freeze its exact public declarations, dependency graph, condition rows, consumer truth, lifecycle state, jobs, supports, evidence, diagnostics, explanations, grants, costs, budgets, lock outcomes, and final database state.

### Deliverables

- A PostgreSQL-native public declaration for an explicit shared condition and its immutable version. SQL remains the definition; pg-react records its stable identity, typed semantic key and output schema, source and dependency fingerprints, owner and grants, maintenance mode, active version, and public relation.
- Explicit consumer dependencies from compatible rule and program versions to the condition's public relation. Validation rejects an incompatible schema, key, query, maintenance mode, dependency, privilege, or platform tuple before creating or changing durable runtime state.
- One dependency and maintenance model: shared conditions participate in the inherited program graph, strata, frontiers, invalidation, reconciliation, locking, and recovery machinery. They do not introduce another scheduler, worker protocol, lifecycle engine, or private relation that consumers may address.
- Atomic deployment, replacement, and removal semantics. A compatible replacement moves the condition and its selected consumers together through one declared deployment; an incompatible replacement fails before cutover, and removal is blocked while an active consumer remains unless the same atomic deployment removes or replaces that dependency.
- Public validation, preview, status, doctor, and explanation output that names the condition version, owner, maintenance state, consumers, dependency and frontier state, drift, fan-out cost, blocking incompatibility, and exact remediation. Ordinary explanation preserves the named condition boundary; authorized advanced output may expand only the inherited bounded evidence.
- Executable correctness, concurrency, failure, recovery, performance, compatibility, security, and direct-upgrade evidence for shared and unshared equivalents, plus extension `0.17.0`, release notes, compatibility inventory, compact author and operator tasks, and a direct upgrade from `0.16.0`.

### Supported boundary

- M20 inherits the complete M19 platform, public API, managed-worker, typed-key, security, maintenance, isolation, immediate-mode, recovery, resource-limit, external-effect, aggregate, window, diagnostic, and usability boundaries except for this explicit shared-condition expansion.
- Sharing is author-declared. Each logical condition has one active immutable version, one typed public relation, and explicit consumers. A condition may depend only on supported authoritative or pg-react public relations through the inherited finite dependency graph; cyclic condition dependencies are rejected.
- Scheduled consumers observe a condition through the inherited committed frontier. Immediate visibility is available only when the condition and complete consumer closure independently satisfy the frozen M19 immediate capability contract; otherwise the dependency is an explicit asynchronous boundary or is rejected when immediate closure was requested.
- A shared condition carries truth and evidence but has no activation, consequence, or external effect of its own. Consumer rules retain their existing lifecycle, refraction, ordering, delivery, and recovery semantics.
- Ownership, use, inspection, and advanced evidence are separately grantable and role-checked. A consumer never gains source-row or evidence visibility merely by depending on a condition, and no public operation requires private-catalog access.

### Explicit non-goals

- Automatic common-subplan or common-predicate discovery, implicit consumer rewrites, cost-based sharing, transparent deduplication of existing rule SQL, or automatic migration from duplicated conditions.
- Hidden condition lifecycle events, direct condition consequences, synchronous arbitrary code, policy rejection of source writes, a new worker protocol, or cross-database sharing.
- A general materialized-view service, unrestricted query composition, cyclic shared conditions, dynamic or mutable schemas, string templates, client DSLs, or visual or AI authoring.
- Retention redesign, richer provenance, practical temporal primitives, effective-dated policy, parameterized policy families, or preparatory abstractions for M21 and later milestones.

### Decisions to close before the M20 contract freezes

- The exact declaration, version, consumer-reference, validation, preview, deployment, replacement, removal, upgrade, and public-relation shapes, including name resolution, schema and key compatibility, allowed query and dependency forms, and supported scheduled or immediate combinations.
- Condition-owner, consumer-owner, deployer, reader, and advanced-reader privileges; grant and revoke behavior; security-definer boundaries; source and evidence visibility; RLS rejection; and ownership changes or dropped roles.
- Dependency identity, stratum and frontier placement, invalidation propagation, fan-out ordering, lock identities and acquisition order, bounded waits, concurrent source/deployment schedules, drift classification, and reconciliation authority.
- Atomic cutover for compatible consumers, rejection and rollback for incompatible consumers, active-version history, pack interaction, removal blocking, downgrade behavior, and recovery when a condition or consumer changes during maintenance.
- Resource admission, indexes, per-condition and per-consumer cost reporting, fan-out and catalog envelopes, retention requirements, failure injection, crash recovery, physical and logical restore, standby behavior, and direct-upgrade treatment of condition state and dependencies.

### Exit gates

- The frozen rules consume one public shared-condition version and produce the exact expected condition rows, matches, facts, activations, jobs, supports, evidence, diagnostics, explanations, and final state for every supported source insert, update, and delete; the equivalent unshared rules produce the same consumer truth and lifecycle results.
- One source transition maintains the condition once and propagates its canonical result to every consumer in dependency order. Scheduled consumers cross the exact committed frontier, while an eligible immediate closure has the exact M19 same-transaction visibility, rollback, savepoint, and worker-isolation behavior.
- Compatible replacement atomically exposes the new condition version and selected consumer versions with no mixed graph, partial frontier, duplicate lifecycle episode, or lost work. Every incompatible replacement or removal with a live consumer returns its exact public diagnostic before durable mutation.
- Every accepted concurrent source, replacement, reconciliation, and consumer-deployment schedule reaches the documented state equivalent to an allowed serialization; every rejected schedule fails within the published bound without partial condition, dependency, lifecycle, evidence, or agenda state.
- Validation rejects every frozen unsupported schema, key, query, dependency, cycle, maintenance-mode combination, privilege, RLS, drift, platform, or resource-limit case and identifies the exact condition, consumer, incompatibility, and remediation.
- Every frozen fan-out profile reports the exact per-condition and per-consumer cost, remains within its published latency, throughput, storage, memory, and catalog budgets, and fails admission before mutation outside the supported envelope.
- Status, doctor, preview, and explanation show the exact named condition and consumer boundary, remain bounded under the maximum supported fan-out, expose deeper evidence only to an authorized role, and reveal no source or condition value unavailable to the caller.
- Reconciliation, crash/restart, managed-worker restart, physical restore, dump/restore, and direct `0.16.0 -> 0.17.0` upgrade preserve or repair the exact condition versions, public relations, consumer graph, frontiers, lifecycle state, jobs, supports, evidence, grants, diagnostics, explanations, and continued maintenance behavior.
- Every inherited M0–M19 semantic, operational, security, recovery, performance, compatibility, documentation, usability, and external-effect gate passes unchanged.
- Non-superuser condition and rule owners can declare, validate, preview, deploy, consume, inspect, explain, diagnose, reconcile, replace, remove, recover, and upgrade the reference shared condition using only granted public APIs and documentation.

---

## Stage 21 — Retention and catalog scale

**Outcome:** keep long-lived pg-react installations within a measured storage and catalog envelope through explicit, dependency-aware, audited retention and evidence-driven physical-layout changes, without deleting current truth or state still required for replay, rollback, explanation, reconciliation, recovery, open windows, pending work, active supports, or corrections.

**Entry gate:** the exact `v0.17.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, and every M0–M20 gate passes unchanged. Before the contract freezes, extend the M18 complete profile into a long-lived fixture spanning repeated rule, program, pack, and shared-condition replacement; active and inactive matches and facts; pending, leased, retryable, terminal, and replayable work; lifecycle, execution, reconciliation, runtime, and retention history; recursive and aggregate supports; open and finalized windows, corrections, and watermarks; physical and logical recovery; and direct upgrade. Freeze every retention policy and horizon, protected-row reason, preview and apply result, audit record, public diagnostic and explanation, table and index size, maintenance latency, normalized public-query plan, and final checksum.

### Deliverables

- One operator-owned public retention policy covering the supported historical families with explicit full-detail, minimum-audit, replay, rollback, deduplication, explanation, reconciliation, and recovery horizons. Defaults preserve inherited behavior until an operator deliberately enables pruning.
- A read-only retention preview that resolves a requested cutoff against durable dependencies and returns exact eligible and protected row counts, bytes, effective cutoffs, blocking objects, lost capabilities, and remediation before mutation.
- One bounded, idempotent apply path that prunes only previewed eligible state in deterministic batches, records the policy, requested and effective cutoffs, batch identity, counts, bytes, actor, outcome, and protected reasons, and resumes safely after failure or restart.
- A frozen retention classification for every historical table and payload: current and executable state is never age-pruned; full detail may expire only after every declared horizon; the minimum immutable identity and outcome required by the audit contract survives for its declared lifetime; and public queries report when requested detail is no longer retained.
- Public status, doctor, metrics, and operations guidance for policy state, oldest retained detail, protected backlog, eligible bytes, batch progress, failed maintenance, table and index growth, vacuum and analyze state, and any supported partition boundary, without requiring private-catalog access for ordinary diagnosis.
- A benchmark-backed physical-layout decision for each catalog family that reaches the frozen scale envelope. Partitioning, index changes, or table rewrites ship only where the M18/M21 evidence proves the selected layout meets the published ingest, maintenance, inspection, upgrade, backup, and recovery budgets better than the inherited layout.
- Extension `0.18.0`, compact retention and recovery tasks, compatibility and loss-of-detail documentation, release notes, executable correctness, concurrency, failure, performance, security, recovery, and direct-upgrade evidence, and a direct upgrade from `0.17.0`.

### Supported boundary

- M21 inherits the complete M20 platform, public API, managed-worker, typed-key, security, maintenance, isolation, immediate-mode, shared-condition, recovery, resource-limit, external-effect, aggregate, window, diagnostic, and usability boundaries except for this retention and physical-layout expansion.
- Retention applies only to pg-react-owned historical state. It never deletes authoritative application rows, active definitions, current matches or facts, active supports, incomplete frontiers, open-window state, or work that is pending, leased, retryable, replayable, or inside the published deduplication, rollback, reconciliation, explanation, or recovery horizon.
- A policy may shorten available historical detail only prospectively and only after preview names the exact capability boundary. Pruned detail is not reconstructed or silently approximated; reads outside retained coverage return an exact bounded diagnostic.
- Pruning advances monotonically per historical family and commits in bounded batches. It does not promise immediate filesystem shrinkage; PostgreSQL vacuum, analyze, backup, restore, and replication behavior remains explicit in the operations contract.
- Any partitioning is confined to private pg-react catalogs and remains invisible through stable public APIs. Unpartitioned tables remain valid where measured evidence does not justify migration.

### Explicit non-goals

- New truth, lifecycle, reasoning, provenance, temporal, or policy semantics; richer support provenance begins with M22.
- Deleting or compacting authoritative source data, serving as a CDC archive, reconstructing arbitrary past database state, unlimited time travel, or preserving every detailed explanation forever.
- External object-store archival, automatic storage-tier migration, cross-database retention coordination, a new maintenance daemon or worker protocol, or a hosted retention service.
- Blanket partitioning, speculative sharding, zero-downtime or zero-bloat claims outside the frozen envelope, or physical rewrites without a measured advantage and tested direct-upgrade path.
- Ad hoc legal-hold workflows, user-defined pruning SQL, private-catalog mutation, or preparatory abstractions for M22 and later milestones.

### Decisions to close before the M21 contract freezes

- The exact policy declaration and versioning shape, historical families, defaults, minimum and maximum horizons, clock and cutoff semantics, enable, preview, apply, pause, resume, replacement, removal, and direct-upgrade behavior.
- The complete retention dependency graph and precedence among current truth, active supports, work states, replay and deduplication, rollback, explanation, reconciliation, windows and corrections, backup and recovery, and each minimum surviving audit identity.
- Batch identity, size bounds, ordering, transaction boundaries, lock order, concurrency with evaluation, claims, replacement, reconciliation, watermark advancement, backup, and upgrade, plus failure rollback, retry, cancellation, and crash recovery.
- Audit schema, count and byte accounting, role visibility, redaction, policy-drift diagnostics, audit-history retention, and exact public behavior when requested evidence predates retained coverage.
- Candidate partition or index keys, admission thresholds, migration and rollback-by-restore procedure, constraint and foreign-key behavior, vacuum and analyze policy, standby and logical-restore treatment, and the benchmark budgets that justify each layout change.

### Exit gates

- For every frozen policy and cutoff, preview returns the exact eligible and protected rows, bytes, effective horizons, dependency reasons, lost capabilities, and remediation; apply removes exactly those eligible rows and records the exact audit result, while a repeated apply is a no-op.
- Every current definition, match, fact, activation, shared-condition row, active support, incomplete frontier, open window, correction still inside its horizon, and pending, leased, retryable, replayable, or deduplicated work survives every applicable prune with exact row values.
- Replay, rollback, explanation, reconciliation, recovery, window correction, worker execution, and idempotent external delivery return the exact frozen public results and durable logical state inside their published horizons after pruning. The same request outside retained coverage fails with its frozen diagnostic and never returns partial evidence as complete.
- Every supported ordering of evaluation, immediate source changes, claims, completion, replacement, reconciliation, watermark advancement, preview, and apply reaches the documented state equivalent to an allowed serialization; every rejected conflict fails within the published bound without partial pruning or stale eligibility.
- Failure before and after every batch commit, coordinator or worker restart, PostgreSQL crash/restart, and maintenance-session termination leaves the last complete audit and data boundary exact, exposes no partially pruned batch, and resumes without deleting newly protected state.
- Unauthorized preview, policy change, apply, audit inspection, or detailed-history access fails exactly. Authorized ordinary output reveals counts and remediation without leaking payloads or evidence the caller could not otherwise inspect.
- Each shipped layout decision is reproducible from the frozen benchmark: the selected design stays within its row-count, database-size, ingest, pruning, inspection, vacuum, backup, restore, and upgrade budgets, and no inherited supported query exceeds its declared regression budget.
- Physical backup/restore, standby promotion, logical export/restore, reconciliation, and direct `0.17.0 -> 0.18.0` upgrade preserve the exact policies, horizons, retained state, audit history, public object inventory, grants, and continued pruning behavior; rollback follows the documented verified-backup boundary.
- Every inherited M0–M20 semantic, operational, security, recovery, performance, compatibility, documentation, usability, and external-effect gate passes unchanged.
- A non-superuser operator can inspect growth, preview loss, enable and apply a policy, diagnose protected state, verify the audit, recover from an interrupted batch, and prove continued application behavior using only granted public APIs and documentation.

---

## Stage 22 — Bounded support provenance

**Outcome:** make current and retained derived truth explainable in stable business terms by recording the canonically ordered, typed bindings that actually sustain each logical support and exposing a finite, role-checked proof through public APIs, without promising arbitrary SQL lineage, proof minimization, or unbounded traversal.

**Entry gate:** the exact `v0.18.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, and every M0–M21 gate passes unchanged. Before the contract freezes, extend the M21 complete profile with authoritative and derived inputs using every supported key type; a multi-input join; shared conditions; alternative and changing supports; positive recursion containing both a cycle and a grounded path; negative, aggregate, finalized-window, and corrected-window evidence; scheduled and eligible immediate maintenance; replacement, reconciliation, retention, physical and logical recovery, and direct upgrade. Freeze every public declaration and result, typed binding, proof node and edge, canonical order, count, bound, cycle and truncation marker, continuation outcome, authorization result, retained-detail diagnostic, normalized query plan, storage cost, and final checksum.

### Deliverables

- One immutable support-provenance record for each supported positive input that actually contributes to a logical support. It identifies the exact source or derived relation version, binding name, PostgreSQL type, canonical value, and stable business or semantic key; physical tuple identity, display text, search path, and row order are never identity inputs.
- Atomic provenance maintenance through the inherited scheduled and immediate paths. Support creation, revision, withdrawal, reactivation, replacement, reconciliation, rollback, correction, and recovery update truth and its provenance at the same frontier, with no orphaned binding, stale edge, or provenance-only truth transition.
- A versioned public explanation shape with canonical node and support ordering, published per-node and whole-proof count, depth, and payload bounds, exact total or omitted counts, stable grounded, cycle, truncated, unavailable, and not-retained markers, and advanced-reader continuation that cannot silently skip or duplicate evidence.
- Typed positive bindings and derived-support edges, plus the inherited bounded summaries for absence, aggregate, and window evidence. Negative evidence identifies the tested relation and complete lower frontier; aggregate and window evidence identifies the group, value, comparison, bounds, completeness or finality, and correction frontier rather than enumerating every input row.
- Role-checked explanation at every traversal step. Ordinary readers receive only authorized business bindings and bounded summaries; advanced readers receive the documented deeper view; neither role gains source-row, shared-condition, payload, or private-catalog visibility it did not already hold.
- Public validation, preview, status, doctor, and explanation output for provenance eligibility, binding types, proof coverage, bounds, truncation, cycles, grounding, retained coverage, drift, storage, and exact remediation, without requiring private-catalog inspection.
- Extension `0.19.0`, compact author, auditor, and operator tasks, compatibility and retention guidance, release notes, executable correctness, concurrency, failure, performance, security, recovery, and direct-upgrade evidence, and a direct upgrade from `0.18.0`.

### Supported boundary

- M22 inherits the complete M21 platform, public API, managed-worker, typed-key, security, maintenance, isolation, immediate-mode, shared-condition, retention, recovery, resource-limit, external-effect, aggregate, window, diagnostic, and usability boundaries except for this support-provenance expansion.
- Provenance answers why a current or retained derived fact is true and why its actual support changed. Existing activation, episode, job, shared-condition, aggregate, window, and reconciliation explanations may reference that proof through their inherited stable identities; they do not acquire new truth or lifecycle semantics.
- Positive provenance covers only bindings available from the frozen, validated derivation shapes and normalized dependency graph. Authoritative inputs end at a versioned relation and typed business key; derived inputs follow the exact logical support graph; absence, aggregates, and windows remain finite summaries.
- Every ordinary proof is finite by published construction. Recursive expansion terminates at authoritative bindings, bounded summaries, explicit cycle markers, retained-detail markers, or a declared limit; advanced continuation remains subject to the same authorization, snapshot, count, depth, and payload ceilings.
- Active provenance needed to justify current truth is protected from retention. Historical detail follows the operator's declared explanation and recovery horizons, and an unavailable or pruned node is reported exactly rather than reconstructed, approximated, or omitted as though the proof were complete.

### Explicit non-goals

- General tuple, query, expression, execution-plan, or cross-database lineage; automatic provenance for arbitrary PostgreSQL views; physical-row tracking with `ctid`; or a second change-capture system.
- Why-not reasoning, counterfactual search, minimal-proof or best-proof selection, proof equivalence, enumeration of every valid derivation, or inference of business meaning from column names or values.
- Enumerating every row behind absence, aggregates, or windows; unbounded proof trees, recursive expansion without cycle markers, unstratified negation, recursive aggregation, or new reasoning semantics.
- Revealing redacted values, hidden row existence, private identifiers, or catalog structure through counts, ordering, tokens, diagnostics, timing, or error differences; provenance never bypasses inherited ownership and role boundaries.
- Practical temporal primitives, effective-dated policy, parameterized policy families, decision tables, or preparatory abstractions for M23 and later milestones.

### Decisions to close before the M22 contract freezes

- The exact binding declaration or derivation shape, supported relation and key identities, type matrix, canonical encoding and JSON rendering, null and collation behavior, duplicate binding treatment, schema drift response, and compatibility rules for replacement and direct upgrade.
- What constitutes an actual contributor for each supported join, shared-condition, recursive, negative, aggregate, and window form; proof-node and edge identity; grounding rules; and lifecycle across support revision, withdrawal, reactivation, correction, replacement, and reconciliation.
- Default and maximum support, binding, depth, node, byte, and execution-time limits; canonical traversal order; total and omitted counts; cycle and truncation markers; continuation-token snapshot, expiry, invalidation, replay, and concurrency semantics.
- Reader and advanced-reader authority at every hop, value-level redaction, count and existence leakage policy, security-definer boundaries, ownership or grant changes, audit requirements, and exact unauthorized, unavailable, and not-retained results.
- Storage layout, indexes, capture and traversal budgets, retention classification and horizons, backup and restore behavior, crash recovery, standby and logical-restore treatment, drift detection, reconciliation authority, and direct-upgrade migration of existing opaque support bindings.

### Exit gates

- Every fact in the frozen fixture returns its exact typed, canonically ordered public proof: authoritative bindings, derived edges, actual alternative supports, negative checks, aggregate and window summaries, rule and relation versions, frontiers, cycle markers, grounding state, and retained-coverage state all match the contract.
- Equivalent source, evaluation, support-discovery, correction, and reconciliation orderings produce the same public proof. Duplicate physical join paths do not create duplicate logical bindings, while distinct actual supports remain distinct and appear in canonical order.
- Support creation, revision, withdrawal, reactivation, and replacement atomically produce the exact truth, lifecycle, provenance, and history transitions in scheduled and eligible immediate modes. Statement failure, savepoint rollback, and transaction abort leave no visible or worker-observable partial proof.
- Every grounded recursive fact exposes at least one finite path to authoritative bindings or a supported bounded summary. Circular-only state is rejected or diagnosed exactly, and a cycle never causes nontermination, duplicate expansion, or a false claim of grounding.
- At and beyond every published count, depth, byte, and execution bound, ordinary and advanced explanation return the exact totals, page contents, truncation and cycle markers, and continuation outcome within budget. A continued stable snapshot has no gaps or duplicates; changed or expired state returns its documented result.
- Every reader, advanced-reader, owner, operator, worker, unrelated role, and `PUBLIC` case returns the exact authorized or denied result at every proof depth, including after grant, revoke, ownership change, replacement, retention, and restore, without leaking protected values or existence through metadata.
- Retention preview and apply protect provenance required by current truth and report the exact eligible, protected, and lost-detail results. Explanation inside each horizon remains exact; explanation outside retained coverage returns the frozen not-retained structure and never presents a partial proof as complete.
- Replacement, reconciliation, crash/restart, managed-worker restart, physical restore, dump/restore, standby promotion, and direct `0.18.0 -> 0.19.0` upgrade preserve or repair the exact bindings, proof graph, frontiers, history, grants, diagnostics, explanations, and continued truth-maintenance behavior.
- The maximum frozen support fan-out, proof depth, recursion, and retained-history profiles stay within their published capture latency, evaluation regression, explanation latency, memory, storage, backup, restore, and upgrade budgets, and fail admission or truncate exactly outside the supported envelope.
- Every inherited M0–M21 semantic, operational, security, recovery, performance, compatibility, documentation, usability, retention, and external-effect gate passes unchanged.
- Non-superuser authors, readers, advanced readers, auditors, and operators can create the reference support graph, change it, inspect why it is true and changed, continue a bounded proof, diagnose truncation or lost detail, reconcile it, retain it, recover it, and upgrade it using only granted public APIs and documentation.

---

## Stage 23 — Practical temporal conditions

**Outcome:** make ordinary time-based policy durable and explainable through bounded database-time primitives for continuous duration, absence at a deadline, cooldown, and explicit arm/recovery hysteresis, without introducing a general complex-event-processing language, a second timer service, or ambiguous clock semantics.

**Entry gate:** the exact `v0.19.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, and every M0–M22 gate passes unchanged. Before the contract freezes, extend the M22 complete profile with keyed conditions that become true, remain true through a duration boundary, retract before it, and recur; trigger and satisfaction facts arriving before, exactly at, and after a deadline; source changes and consequence outcomes during cooldown; enter and recovery conditions that alternate around a hysteresis boundary; open, finalized, and corrected M17 window inputs; scheduled and eligible immediate maintenance; pause, resume, replacement, reconciliation, retention, physical and logical recovery, and direct upgrade. Freeze every public declaration and result, temporal-state and deadline identity, interval encoding, clock and frontier, boundary ordering, lifecycle transition, diagnostic and explanation, normalized public-query plan, storage cost, and final checksum.

### Deliverables

- One versioned public temporal-condition declaration over supported authoritative or pg-react public relations. It identifies exactly one primitive, one inherited typed semantic key, its input and any satisfaction or recovery relation, a finite direct deadline or positive fixed duration, the database-time clock authority, owner and grants, active version, maintenance mode, and public result relation.
- Durable, indexed, per-key temporal state maintained through the inherited M12 coordinator, dependency graph, lifecycle, locking, reconciliation, and recovery paths. Clock advancement, due-state change, support, provenance, activation, agenda, and public evidence commit at one frontier; retry, restart, restore, or a forward clock jump catches up without duplicate or partial transitions.
- Continuous-duration semantics: a key becomes temporally true only if its input remains true through the declared duration boundary. Retraction before the boundary cancels the pending deadline, and later truth starts a new interval with a new stable identity.
- Absence-by-deadline semantics: one trigger establishes a key and finite deadline, and one lower-stratum positive relation satisfies it. The absence condition becomes true only when the durable frontier reaches the deadline without a qualifying satisfaction; equality and concurrent trigger, satisfaction, source-refresh, and clock-pass cases follow one frozen ordering contract.
- Cooldown and hysteresis semantics integrated with the inherited generation and refraction model. Cooldown makes a key ineligible until one durable deadline after its declared lifecycle anchor, with exact handling of changes during the interval; hysteresis uses separate enter and recovery conditions to preserve state across an intermediate band and re-arm only after recovery, without adding a numeric-expression language.
- Public validation, preview, status, doctor, history, and explanation output that names the primitive, version, key, clock domain, current frontier, pending or crossed deadline, continuous-since or cooldown boundary, arm and recovery state, M17 input finality when applicable, provenance coverage, drift, truncation, and exact remediation without private-catalog access.
- Extension `0.20.0`, compact author and operator tasks, temporal and clock guidance, compatibility and retention documentation, release notes, executable correctness, concurrency, failure, performance, security, recovery, and direct-upgrade evidence, and a direct upgrade from `0.19.0`.

### Supported boundary

- M23 inherits the complete M22 platform, public API, managed-worker, typed-key, security, maintenance, isolation, immediate-mode, shared-condition, retention, recovery, resource-limit, external-effect, aggregate, window, provenance, diagnostic, and usability boundaries except for this practical temporal expansion.
- M23 adds only continuous duration, absence by a direct deadline, cooldown, and arm/recovery hysteresis. Each declaration has one explicit database-time authority and bounded per-key state; fixed durations are positive integral microseconds, direct deadlines are finite non-null `timestamptz` values, and equality is due.
- M17 event-time window results may participate only through their inherited committed relation, watermark, correction, and finality contracts. Database-time frontier, event-time watermark, source commit time, and consequence wall-clock latency remain distinct and are named wherever more than one appears.
- Temporal inputs follow the inherited finite, stratified program graph and supported key, query, ownership, privilege, RLS, maintenance-mode, and immediate-closure rules. Volatile clock expressions, hidden polling queries, and private-catalog dependencies are rejected before durable mutation.
- Consequences remain asynchronous and at-least-once. A temporal boundary promises deterministic logical eligibility and catch-up at a committed frontier, not exact wall-clock firing latency or rollback of the source transaction.

### Explicit non-goals

- A general CEP or pattern language; arbitrary event sequences; partial-match automata; rolling, hopping, session, calendar, recurring, or cron windows; temporal joins; event-time duration or absence; or unbounded temporal history.
- User-defined timer callbacks, sleep-based workers, a second scheduler, a general background-job service, synchronous arbitrary code, source-write rejection, or an exactly-once or exact-wall-clock delivery claim.
- Implicit inference of deadlines, recovery predicates, lifecycle anchors, time zones, calendars, or clock domains from SQL text, column names, display values, execution order, or worker time.
- Unstratified temporal negation, recursive temporal aggregation, cycles through temporal conditions, unrestricted composition of temporal primitives, or a custom numerical threshold and hysteresis expression language.
- Effective-dated policy versions, parameterized policy families, decision tables, policy-set analysis or gating, client DSLs, visual or AI authoring, domain packages, or preparatory abstractions for M24 and later milestones.

### Decisions to close before the M23 contract freezes

- The exact declaration, validation, preview, authoring, replacement, removal, and public-relation shapes; primitive and version identity; supported key and relation forms; direct deadline and fixed-duration encodings; interval bounds; clock sampling; and compatibility rules.
- The exact continuous-since, pending, due, active, cooldown, armed, and recovered states; lifecycle anchors; equality semantics; trigger multiplicity and deadline replacement; satisfaction-key cardinality; generation and refraction interaction; changes during cooldown; overlapping enter and recovery truth; and pause, resume, replace, remove, and reconcile behavior.
- The total order for concurrent trigger, satisfaction, input retraction, recovery, source refresh, immediate maintenance, clock advancement, consequence completion, replacement, and reconciliation, including lock identities, acquisition order, bounded waits, rollback, and retry.
- Dependency and stratum placement, M17 open and finalized input treatment, scheduled and immediate eligibility, provenance and explanation shape, authorization and redaction at each hop, retention protection, drift classification, and exact unsupported mixed-clock diagnostics.
- State and index layout, per-condition and per-key admission limits, deadline-batch and catch-up bounds, clock-lag thresholds, storage and latency budgets, coordinator ownership, standby and promotion behavior, failure injection, physical and logical restore, and direct-upgrade migration.

### Exit gates

- Every key in the frozen fixture returns the exact temporal declaration, input truth, primitive state, continuous-since value, pending or crossed deadline, cooldown boundary, arm and recovery state, clock frontier, support, provenance, activation, agenda, diagnostic, explanation, and final public result at every frozen step.
- A continuous-duration condition activates exactly at the first committed frontier at or beyond its boundary only when input truth was uninterrupted; every pre-boundary retraction cancels it, and every later interval receives the exact documented generation and identity without stale state.
- At the first committed frontier equal to or beyond a deadline, absence is true exactly when the qualifying satisfaction is absent under the frozen snapshot and ordering contract. Every before-, equal-, after-, and concurrent trigger, satisfaction, source-refresh, and clock-pass case reaches its documented serial result without a false absence episode.
- Cooldown suppresses, coalesces, or reevaluates every in-interval change exactly as frozen and becomes eligible once at its boundary. Hysteresis preserves active state across the intermediate band, recovers and re-arms only through its declared relation, and never chatters or invents an episode under the frozen oscillation schedule.
- Scheduled and eligible immediate source changes expose the exact inherited transaction, savepoint, rollback, and worker-isolation behavior. Every temporal boundary remains database-time driven, while every M17 input retains its exact watermark, correction, finality, and late-input result without mixing clock authority.
- Every supported interleaving of evaluation, clock advancement, claim, completion, pause, resume, replacement, reconciliation, retention, and recovery reaches a state equivalent to an allowed serialization; every rejected interleaving fails within its published bound without partial temporal, lifecycle, provenance, or agenda state.
- Coordinator failure before and after every frozen commit, managed-worker restart, PostgreSQL crash/restart, forward clock adjustment, standby promotion, and overdue catch-up preserves the last complete frontier and produces each due logical lifecycle transition at most once with the exact lag and recovery evidence. Backward adjustment pauses temporal progress without retracting due state; consequence attempts retain the inherited at-least-once contract.
- Validation rejects every frozen unsupported key, query, interval, timestamp, clock, relation, dependency, cycle, maintenance-mode, privilege, RLS, drift, platform, and resource-limit case before durable mutation and identifies the exact condition and remediation.
- The maximum frozen active-key, pending-deadline, expiry-density, catch-up, dependency-fan-out, and retained-history profiles remain within their published evaluation, clock-pass, explanation, memory, storage, backup, restore, and upgrade budgets and fail admission before exceeding the supported envelope.
- Retention, replacement, reconciliation, physical restore, dump/restore, and direct `0.19.0 -> 0.20.0` upgrade preserve or repair the exact declarations, versions, temporal state, deadlines, frontiers, lifecycle identities, work, supports, provenance, grants, diagnostics, explanations, and continued coordinator behavior.
- Every inherited M0–M22 semantic, operational, security, recovery, performance, compatibility, documentation, usability, retention, provenance, and external-effect gate passes unchanged.
- Non-superuser authors, readers, operators, and workers can declare, validate, preview, deploy, exercise, pause, resume, inspect, explain, diagnose, reconcile, replace, remove, recover, and upgrade the reference temporal conditions using only granted public APIs and documentation.

---

## Stage 24 — Effective-dated policy versions

**Outcome:** make business-effective policy changes durable, deterministic, and explainable by giving rule and program versions canonical `[valid_from, valid_to)` intervals, separating deployment time from business-effective time, and switching authority at one committed logical-time boundary without duplicate, missing, or prematurely executable policy state.

**Entry gate:** the exact `v0.20.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, and every M0–M23 gate passes unchanged. Before the contract freezes, extend the M23 complete profile with active, future, expired, adjacent, overlapping, open-ended, rejected empty, and retrospectively proposed intervals; multiple versions deployed in and out of effective order; boundaries before, exactly at, and after the database-time frontier; source changes, temporal deadlines, derived truth, decision-independent rule matches, and consequence outcomes spanning a version transition; scheduled and eligible immediate maintenance; pause, resume, replacement, reconciliation, retention, physical and logical recovery, standby promotion, and direct upgrade. Freeze every public declaration and result, policy and version identity, interval encoding, clock and frontier, authority-selection rule, overlap and gap result, lifecycle transition, work disposition, diagnostic and explanation, normalized public-query plan, storage cost, and final checksum.

### Deliverables

- One versioned public effective-policy declaration for supported rule and program versions. It records a stable policy identity, immutable version identity, finite non-null `valid_from`, optional finite `valid_to`, canonical half-open `[valid_from, valid_to)` semantics, database-time clock authority, owner and grants, deployment state, effective state, maintenance mode, and public result relation.
- Deterministic authority selection at one committed database-time frontier. A validated future version may be deployed while dormant, becomes authoritative exactly when its interval contains the frontier, and ceases authority at its exclusive upper bound; deployment time, validation time, effective time, source commit time, event-time watermark, and consequence latency remain distinct.
- Atomic version transitions through the inherited coordinator, dependency graph, lifecycle, locking, temporal, provenance, agenda, reconciliation, and recovery paths. Old-version withdrawal, new-version authority, resulting match and derived-truth changes, lifecycle state, provenance, agenda work, and public evidence commit at one frontier without an observable mixed-version state.
- A frozen overlap and gap policy for every supported declaration shape. Validation either proves unique authority for the declared policy population or rejects the declaration before durable mutation; adjacency at one shared boundary is supported without an authority gap or overlap.
- Explicit disposition of pending, retrying, leased, completed, and future work across an effective transition. Every episode retains the immutable policy and rule version that created it, while fresh eligibility and authority checks prevent a stale version from beginning work outside its documented execution boundary.
- Public validation, preview, deployment, scheduling, status, doctor, history, and explanation output that names policy and version identity, deployment and effective state, validity interval, current frontier, predecessor and successor, overlap or gap, next transition, affected dependencies, work disposition, provenance coverage, drift, retention state, and exact remediation without private-catalog access.
- Extension `0.21.0`, compact author, reviewer, auditor, and operator tasks, effective-time and transition guidance, compatibility and retention documentation, release notes, executable correctness, concurrency, failure, performance, security, recovery, and direct-upgrade evidence, and a direct upgrade from `0.20.0`.

### Supported boundary

- M24 inherits the complete M23 platform, public API, managed-worker, typed-key, security, maintenance, isolation, immediate-mode, shared-condition, retention, recovery, resource-limit, external-effect, aggregate, window, provenance, temporal, diagnostic, and usability boundaries except for this effective-policy expansion.
- Validity intervals use one explicit database-time authority and canonical `[valid_from, valid_to)` semantics. `valid_from` is finite and non-null; `valid_to` is finite and greater than `valid_from` when present, while null means an unbounded future endpoint. Equality belongs to the version beginning at that boundary, not the version ending there.
- Effective dating applies only to immutable versions in one supported policy or program identity and its validated dependency closure. It changes which deployed version is authoritative; it does not reinterpret historical source facts, event-time windows, temporal deadlines, completed consequences, or retained audit records.
- Future versions may be validated and deployed before they become effective. They remain non-authoritative and cannot expose active matches, derived truth, lifecycle transitions, or executable work before their boundary, except through explicitly labeled preview and diagnostic interfaces.
- Scheduled and eligible immediate maintenance preserve their inherited transaction and isolation contracts. A boundary transition is coordinator-owned and database-time driven; no backend-local timer, worker wall clock, source transaction timestamp, or event-time watermark may independently activate a policy version.
- Existing policy history remains append-only and attributable to the exact immutable version and effective interval that governed each transition. Retention may remove eligible detail only through the inherited audited policy and must preserve current authority, scheduled successors, protected work, and the evidence required by the configured audit and recovery horizons.

### Explicit non-goals

- Bitemporal databases, arbitrary valid-time or transaction-time query rewriting, retroactive recomputation of historical truth, automatic correction of previously executed consequences, or a general temporal SQL layer.
- Overlapping authoritative versions resolved by implicit priority, deployment order, row order, object OID, wall clock, or last writer wins; ambiguous authority is rejected rather than guessed.
- Per-row, per-tenant, per-jurisdiction, or per-segment parameter selection inside one effective-policy declaration; parameterized policy families and policy-set gating remain later milestones.
- Decision candidates, winner selection, decision tables, conflict or coverage analysis, hypothetical facts, policy impact simulation, replay, or backtesting.
- Cron schedules, recurring calendar rules, local-business-calendar semantics, time-zone inference, event-time effective dating, user-defined timer callbacks, sleeping workers, or a second scheduler.
- Mutable deployed rule definitions, in-place interval edits that rewrite retained authority history, automatic SQL generation, template languages, client DSLs, visual or AI authoring, or preparatory abstractions for M25 and later milestones.

### Decisions to close before the M24 contract freezes

- The exact policy, program, and version declaration shapes; stable identity and naming rules; supported rule and dependency forms; interval type and canonical encoding; infinity and null treatment; precision; equality; clock sampling; deployment states; replacement rules; and direct-upgrade representation.
- Whether declarations require complete contiguous coverage or permit explicit no-authority gaps; the exact overlap test across current, future, expired, paused, removed, and retained versions; adjacency semantics; maximum scheduled-version count and horizon; and validation behavior under concurrent declaration.
- The total order for deployment, boundary advancement, source refresh, immediate maintenance, temporal deadline processing, pause, resume, replacement, removal, reconciliation, retention, consequence claim and completion, and recovery, including lock identities, acquisition order, bounded waits, rollback, and retry.
- The exact match, derivation, support, provenance, activation, generation, revision, refraction, agenda, and explanation transitions when authority changes while equivalent or different truth exists on each side of the boundary.
- The disposition and fresh checks for pending, retrying, leased, expired, cancelled, completed, and outbox-backed work created by the ending version; whether any bounded grace behavior is supported; and how every outcome identifies the creating and currently authoritative versions.
- Authorization for authors, deployers, approvers, operators, readers, workers, and auditors; ownership and grant changes; value and existence redaction; audit requirements; drift classification; and exact unauthorized, unavailable, conflicted, and not-retained results.
- State and index layout, transition lookup and catch-up bounds, active and future version admission limits, storage and latency budgets, coordinator ownership, standby and promotion behavior, failure injection, retention protection, physical and logical restore, and direct-upgrade migration of existing M23 rules into an initial effective interval.

### Exit gates

- Every version in the frozen fixture returns the exact policy identity, immutable version identity, interval, deployment state, effective state, current frontier, predecessor, successor, overlap or gap result, next transition, dependency state, matches, derived truth, lifecycle, work, support, provenance, diagnostic, explanation, and retained-history result at every frozen step.
- Before `valid_from`, a future version remains non-authoritative and creates no active match, derived fact, lifecycle transition, or executable work. At the first committed frontier equal to or beyond `valid_from`, it becomes authoritative exactly once when its interval contains that frontier.
- At `valid_to`, the ending version is no longer authoritative. An adjacent successor beginning at the same boundary takes authority without a gap, overlap, duplicate transition, mixed-version result, or interval in which both versions may begin executable work.
- Every empty, inverted, non-finite, out-of-range, duplicate, or forbidden overlapping interval is rejected before durable mutation. Every supported explicit gap returns the frozen no-authority state and diagnostic rather than silently retaining the expired version.
- Deploying equivalent versions in different transaction and declaration orders produces the same authority sequence, lifecycle state, provenance, agenda outcome, history, and public explanation. Deployment time and physical row order never affect winner identity.
- Source changes, temporal deadlines, clock advancement, scheduled refresh, and eligible immediate maintenance concurrent with an effective boundary reach a state equivalent to one documented serialization and never evaluate one logical transition under a mixed dependency closure.
- Pending, retrying, leased, expired, completed, cancelled, and outbox-backed work spanning a boundary receives exactly the frozen disposition. No stale version begins consequence execution after failing its required fresh authority check, and no completed attempt loses attribution to its creating version.
- Pause, resume, replace, remove, reconcile, and retain operations before, at, and after a boundary preserve the frozen authority and history semantics. Reconciliation is idempotent and cannot manufacture historical activations or consequences for a previously dormant interval.
- Coordinator failure before and after every frozen transition commit, managed-worker restart, PostgreSQL crash/restart, forward clock adjustment, backward clock adjustment, standby promotion, and overdue catch-up preserve the last complete frontier and produce each effective transition at most once with exact lag and recovery evidence.
- Every reader, author, deployer, operator, worker, auditor, unrelated role, and `PUBLIC` case returns the exact authorized or denied declaration, preview, deployment, status, history, and explanation result after grant, revoke, ownership change, replacement, retention, restore, and upgrade without leaking protected policy existence or values.
- The maximum frozen active-policy, scheduled-version, dependency-fan-out, simultaneous-boundary, catch-up, pending-work, and retained-history profiles remain within their published transition latency, evaluation regression, explanation latency, memory, storage, backup, restore, and upgrade budgets and fail admission before exceeding the supported envelope.
- Retention, replacement, reconciliation, physical restore, dump/restore, and direct `0.20.0 -> 0.21.0` upgrade preserve or repair the exact declarations, intervals, authority sequence, frontiers, lifecycle identities, work, supports, provenance, grants, diagnostics, explanations, and continued coordinator behavior.
- Every inherited M0–M23 semantic, operational, security, recovery, performance, compatibility, documentation, usability, retention, provenance, temporal, and external-effect gate passes unchanged.
- Non-superuser authors, deployers, readers, auditors, operators, and workers can declare, validate, preview, deploy, schedule, exercise, pause, resume, inspect, explain, diagnose, reconcile, replace, remove, recover, and upgrade the reference effective policies using only granted public APIs and documentation.

---

## Stage 25 — Parameterized policy families

**Outcome:** make policy variation across tenants, segments, and populations manageable by letting one typed rule or program definition consume a versioned, ordinary PostgreSQL parameter relation as family-scoped facts, without templating, string substitution, or generated per-instance rule copies.

**Entry gate:** the exact `v0.21.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, and every M0–M24 gate passes unchanged. Before the contract freezes, extend the M24 complete profile with one or more typed parameter relations declared under a family; parameter rows added, changed, and removed independently of rule-definition changes; matches that activate and deactivate as a parameter value crosses a match boundary; multiple rule or program versions, including M24 effective-dated versions, consuming the same or different parameter states; concurrent parameter change and version transition; scheduled and eligible immediate maintenance; pause, resume, replacement, reconciliation, retention, physical and logical recovery, standby promotion, and direct upgrade. Freeze every public declaration and result, family and consuming-version identity, parameter key and value shape, clock and frontier, activation and deactivation transition, lifecycle transition, work disposition, diagnostic and explanation, normalized public-query plan, storage cost, and final checksum.

### Deliverables

- One versioned public parameter-family declaration for supported rule and program definitions. It records a stable family identity, the consumed parameter relation, its semantic key and required value columns and types, owner and grants, the rule or program versions allowed to consume it, maintenance mode, and public result relation.
- Deterministic parameter-driven maintenance through the inherited coordinator, dependency graph, lifecycle, locking, and recovery paths. A parameter insert, update, or delete activates or deactivates exactly the matches it changes through the same relational maintenance used for any other input change; pg-react never compiles, templates, or otherwise mutates rule logic in place.
- Validation enforcing parameter key uniqueness, required-value non-nullability, supported value types, ownership, and the dependency structure between a policy or program version and its declared parameter relation.
- Public preview showing which current matches would change for a proposed parameter update, atomic deployment of a rule or program definition together with an initial parameter dataset, and replacement semantics that distinguish a new definition version from an ordinary parameter change.
- Public explanation output that names the family identity, consuming version, and the exact parameter key and value that contributed to a match, alongside the inherited support, provenance, and diagnostic content, without private-catalog access.
- Extension `0.22.0`, compact author, policy-value editor, reviewer, and operator tasks, parameter-authoring and dual-authorization guidance, compatibility and retention documentation, release notes, executable correctness, concurrency, failure, performance, security, recovery, and direct-upgrade evidence, and a direct upgrade from `0.21.0`.

### Supported boundary

- M25 inherits the complete M24 platform, public API, managed-worker, typed-key, security, maintenance, isolation, immediate-mode, shared-condition, retention, recovery, resource-limit, external-effect, aggregate, window, provenance, temporal, effective-dating, diagnostic, and usability boundaries except for this parameter expansion.
- A parameter family declares one typed relational parameter source per consuming policy or program version. The parameter relation is ordinary PostgreSQL data with an explicit semantic key, required value columns and types, and normal join participation; no template language, string substitution, or per-instance generated rule is supported.
- Parameter changes are facts, not hidden rule mutation. A changed, added, or removed parameter row is evaluated through the same dependency, lifecycle, and locking paths as any other input change, and may combine with an M24 effective-dated version of the same policy without ambiguity about which version and which parameter row produced a result.
- Authorization may separate the role that may change a policy definition's logic from the role that may change its parameter values; both remain subject to the inherited ownership, grant, and RLS-rejection rules.
- Consequences remain asynchronous and at-least-once. A parameter-driven activation or deactivation promises deterministic logical eligibility and catch-up at a committed frontier, not exact wall-clock latency.

### Explicit non-goals

- A templating system, string substitution, placeholder expressions, arbitrary JSON parameters, or per-instance generated rule copies.
- Decision candidates, winner selection, decision tables, or coverage and conflict analysis over parameter-driven results.
- Policy-set gating, hypothetical fact simulation, deployment impact simulation, historical replay, or comparative backtesting.
- Implicit inference of a parameter's semantic key, value types, or owning family from column names, SQL text, or execution order.
- Client DSLs, visual or AI authoring, domain packages, or preparatory abstractions for M26 and later milestones.

### Decisions to close before the M25 contract freezes

- The exact parameter-family declaration, validation, preview, authoring, replacement, removal, and public-relation shapes; family and consuming-version identity; supported parameter key and value-column types; required-value and nullability rules; and compatibility rules.
- The exact activation and deactivation semantics when a parameter row is inserted, updated, or removed, including interaction with the inherited generation, refraction, and M24 effective-dated version-transition machinery.
- The total order for concurrent parameter change, rule-version deployment, effective-dated transition, source refresh, immediate maintenance, replacement, and reconciliation, including lock identities, acquisition order, bounded waits, rollback, and retry.
- The exact preview and explanation shape naming the family, consuming version, parameter key, and value that produced or would produce a match, and how each is redacted for an unauthorized reader.
- Authorization for authors, policy-value editors, deployers, operators, readers, and workers; whether logic-authoring and parameter-value authorship may be separated by role; ownership and grant changes; and exact unauthorized, unavailable, and conflicted results.
- State and index layout, per-family and per-parameter-relation admission limits, storage and latency budgets, coordinator ownership, standby and promotion behavior, failure injection, physical and logical restore, and direct-upgrade migration.

### Exit gates

- Every key in the frozen fixture returns the exact parameter-family identity, consuming version, parameter key and value, match and derived-truth state, lifecycle, work, support, provenance, diagnostic, explanation, and final public result at every frozen step.
- A parameter row inserted, updated, or removed activates or deactivates exactly the matches whose value crosses the change, through the same relational maintenance as any other input change, without recompiling, templating, or otherwise mutating rule logic in place.
- `preview` identifies exactly the matches that would change for a proposed parameter update before it is committed, and `explain` identifies the exact parameter key and value that contributed to a selected match, in every frozen case.
- Deploying a rule or program definition together with an initial parameter dataset commits both atomically; a rule-definition replacement and an ordinary parameter change remain distinguishable in history and are never conflated as the same event.
- Every empty, non-unique, missing-required, wrong-typed, or unauthorized-dependency parameter declaration is rejected before durable mutation and identifies the exact condition and remediation.
- Parameter changes combined with an M24 effective-dated version transition at, before, or after its boundary reach a state equivalent to one documented serialization and never expose a mixed version-and-parameter result.
- Every supported interleaving of parameter change, rule-version deployment, replacement, reconciliation, retention, and recovery reaches a state equivalent to an allowed serialization; every rejected interleaving fails within its published bound without partial family, lifecycle, provenance, or agenda state.
- Coordinator failure before and after every frozen commit, managed-worker restart, PostgreSQL crash/restart, and overdue catch-up preserves the last complete frontier and produces each due parameter-driven transition at most once with the exact lag and recovery evidence.
- Every reader, author, policy-value editor, deployer, operator, worker, unrelated role, and `PUBLIC` case returns the exact authorized or denied declaration, preview, deployment, status, history, and explanation result after grant, revoke, ownership change, replacement, retention, restore, and upgrade without leaking protected parameter existence or values.
- The maximum frozen active-family, parameter-row, dependency-fan-out, and retained-history profiles remain within their published evaluation, explanation latency, memory, storage, backup, restore, and upgrade budgets and fail admission before exceeding the supported envelope.
- Retention, replacement, reconciliation, physical restore, dump/restore, and direct `0.21.0 -> 0.22.0` upgrade preserve or repair the exact declarations, families, parameter state, versions, lifecycle identities, work, supports, provenance, grants, diagnostics, explanations, and continued coordinator behavior.
- Every inherited M0–M24 semantic, operational, security, recovery, performance, compatibility, documentation, usability, retention, provenance, temporal, and external-effect gate passes unchanged.
- Non-superuser authors, policy-value editors, deployers, readers, operators, and workers can declare, validate, preview, deploy, exercise, inspect, explain, diagnose, reconcile, replace, remove, recover, and upgrade the reference parameterized policies using only granted public APIs and documentation.

---

## Stage 26 — Decision tables

**Outcome:** turn a maintained SQL candidate relation into one durable, versioned, and explainable decision state per subject by giving candidate identity, priority, ambiguity, winner lifecycle, and bounded competitor evidence deterministic engine semantics, without adding a decision-table DSL.

**Entry gate:** the exact `v0.22.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, and every M0–M25 gate passes unchanged. Before the contract freezes, extend the M25 complete profile with subjects having one candidate, several ordered candidates, no remaining candidate, and tied best candidates; candidate insert, update, and delete that preserve or change the winner; priority and result changes; parameter-driven candidates; effective-dated decision-program versions; concurrent candidate change and version transition; scheduled and eligible immediate maintenance; pause, resume, replacement, reconciliation, retention, physical and logical recovery, standby promotion, and direct upgrade. Freeze every public declaration and result, program, version, subject, candidate, priority, result, winner, ambiguity, clock and frontier, lifecycle transition, work disposition, diagnostic and explanation, normalized public-query plan, storage cost, and final checksum.

### Deliverables

- One versioned public decision-program declaration over one maintained PostgreSQL candidate relation. It records a stable program identity, subject semantic key, candidate identity, `bigint` priority, typed result columns, owner and grants, maintenance mode, and public winner relation.
- Deterministic single-winner maintenance through the inherited coordinator, dependency graph, lifecycle, locking, and recovery paths. The lowest priority value wins; equally best candidates place only that subject in an explicit ambiguity state with executable work claim-barriered; removal of every candidate removes the current winner without inventing a default.
- Validation enforcing stable subject and candidate identity, a unique `(subject, candidate)` pair, non-null `bigint` priority and supported result types, relation ownership, dependency safety, and bounded candidates per subject before durable mutation; distinct candidates may share a priority only to produce the explicit ambiguity state.
- Public status, history, preview, and explanation that expose the selected winner, ambiguity, known-subject no-candidate, or never-observed subject state, its lifecycle identity and result when present, and a bounded canonically ordered set of relevant competitors, alongside inherited support, provenance, and diagnostics.
- Atomic deployment and replacement of decision-program versions without mixed-version winners, plus exact lifecycle semantics for a winner appearing, disappearing, changing identity, or revising its result while its identity remains stable.
- Extension `0.23.0`, compact author, reviewer, reader, operator, and worker tasks, decision-authoring and ambiguity-recovery guidance, compatibility and retention documentation, release notes, executable correctness, concurrency, failure, performance, security, recovery, and direct-upgrade evidence, and a direct upgrade from `0.22.0`.

### Supported boundary

- M26 inherits the complete M25 platform, public API, managed-worker, typed-key, security, maintenance, isolation, immediate-mode, shared-condition, retention, recovery, resource-limit, external-effect, aggregate, window, provenance, temporal, effective-dating, parameter-family, diagnostic, and usability boundaries except for this decision expansion.
- SQL remains the only policy expression language. One declared candidate relation supplies one subject key, one stable candidate identity, one non-null `bigint` priority, and one or more typed result columns; pg-react adds durable selection semantics and never parses predicates, ranges, or table cells into rules.
- At each complete committed frontier, exactly one candidate at the lowest priority value is authoritative; multiple candidates at that value make the subject ambiguous, with no arbitrary winner and new work barriered until resolution. Physical row order, transaction order, and maintenance timing never select a candidate.
- Candidate maintenance recomputes only affected subjects. Losing-candidate changes that leave the same winner identity and result create no false lifecycle transition; a changed result for the same winner is a revision, while winner replacement is one ordered old-winner-out and new-winner-in transition.
- M26 reports the no-candidate state only for subjects known through candidate or retained winner history and distinguishes it from a never-observed subject; proving coverage over an independently declared population, requiring a default, and finding unreachable candidates belong to M27.
- Consequences remain asynchronous and at-least-once. A decision winner promises deterministic logical eligibility and catch-up at a committed frontier, not synchronous selection or exactly-once external effects.

### Explicit non-goals

- A decision-table DSL, spreadsheet or range syntax, predicate parser, generated SQL, visual table editor, or second evaluation engine.
- Multi-winner decisions, weighted scoring, ensembles, optimization, probabilistic ranking, arbitrary tie-breakers, or user-defined comparison functions.
- Predeployment coverage and conflict analysis, required defaults, unreachable-candidate detection, or winner-distribution analysis beyond exact runtime ambiguity and current-state preview.
- Policy-set gating, hypothetical fact simulation, deployment impact simulation, historical replay, or comparative backtesting.
- Bounded synchronous firing, unstratified negation, recursive aggregation, client DSLs, visual or AI authoring, domain packages, or preparatory abstractions for M27 and later milestones.

### Decisions to close before the M26 contract freezes

- The exact decision-program declaration, validation, preview, deployment, replacement, removal, and public-relation shapes; program, version, subject, candidate, and winner identity; priority bounds; supported result types; result nullability, equality, collation, and compatibility rules; and retained-history representation.
- The exact never-observed, no-candidate, unique-winner, and ambiguity result shapes; candidate uniqueness; revision and activation identity; work cancellation and claim barriers; and recovery after ambiguity resolves.
- The total order for concurrent candidate insert, update, and delete, parameter change, decision-version deployment, effective-dated transition, source refresh, immediate maintenance, pause, replacement, and reconciliation, including lock identities, acquisition order, bounded waits, rollback, and retry.
- The exact preview and explanation contract, competitor relevance rule, canonical ordering and maximum count, truncation disclosure, support and provenance linkage, and redaction for unauthorized readers.
- Authorization for authors, deployers, readers, auditors, operators, and workers; ownership and grant changes; relation access; and exact unauthorized, unavailable, drifted, ambiguous, and not-retained results without leaking protected decision existence or values.
- State and index layout, per-program and per-subject candidate limits, storage and latency budgets, coordinator ownership, standby and promotion behavior, failure injection, retention protection, physical and logical restore, and direct-upgrade migration.

### Exit gates

- Every subject in the frozen fixture returns the exact program and version identity, candidate set, priority and result when present, winner or never-observed or no-candidate or ambiguity state, lifecycle, work, support, provenance, diagnostic, explanation, and final public result at every frozen step.
- Candidate insert, update, and delete recompute exactly the affected subjects. A losing-candidate change that preserves winner identity and result produces byte-for-byte unchanged winner and lifecycle output, while a result revision or winner change produces exactly the frozen transition.
- The unique lowest-priority candidate wins in every supported case. Equally best candidates always produce the same canonically ordered ambiguity evidence, no arbitrary winner, and no new executable claim until the ambiguity is resolved.
- Winner appearance, disappearance, revision, and replacement preserve exact attribution and the frozen identity scope: a result revision retains its winner activation identity, disappearance closes it, and appearance or replacement opens a new activation. Replacement produces one ordered old-winner-out and new-winner-in transition without a frontier containing mixed versions or two authoritative winners.
- Every missing, duplicate, nullable, wrong-typed, unsupported, drifted, RLS-protected, unauthorized, or over-limit candidate declaration is rejected before durable mutation and identifies the exact condition and remediation.
- Public preview, status, history, and explanation return the exact selected candidate and result or exact never-observed, no-candidate, or ambiguity state, plus the frozen bounded competitor set, canonical order, truncation disclosure, support, provenance, lifecycle, and authorization result.
- Candidate changes combined with parameter updates and effective-dated decision-version transitions at, before, or after a boundary reach a state equivalent to one documented serialization and never expose a mixed candidate, parameter, or version result.
- Every supported interleaving of candidate change, program deployment, replacement, pause, reconciliation, retention, and recovery reaches a state equivalent to an allowed serialization; every rejected interleaving fails within its published bound without partial winner, lifecycle, provenance, or agenda state.
- Coordinator failure before and after every frozen commit, managed-worker restart, PostgreSQL crash/restart, forward and backward clock adjustment, standby promotion, and overdue catch-up preserve the last complete frontier and produce each due winner transition at most once with exact lag and recovery evidence.
- Every reader, author, deployer, operator, worker, unrelated role, and `PUBLIC` case returns the exact authorized or denied declaration, preview, deployment, status, history, and explanation result after grant, revoke, ownership change, replacement, retention, restore, and upgrade without leaking protected decision existence, candidates, or results.
- The maximum frozen active-program, subject, candidates-per-subject, simultaneous-winner-change, dependency-fan-out, pending-work, and retained-history profiles remain within their published selection, explanation, memory, storage, backup, restore, and upgrade budgets and fail admission before exceeding the supported envelope.
- Retention, replacement, reconciliation, physical restore, dump/restore, and direct `0.22.0 -> 0.23.0` upgrade preserve or repair the exact declarations, versions, candidates, winners, ambiguities, lifecycle identities, work, supports, provenance, grants, diagnostics, explanations, and continued coordinator behavior.
- Every inherited M0–M25 semantic, operational, security, recovery, performance, compatibility, documentation, usability, retention, provenance, temporal, parameter, and external-effect gate passes unchanged.
- Non-superuser authors, deployers, readers, operators, and workers can declare, validate, preview, deploy, exercise, inspect, explain, diagnose, reconcile, replace, remove, recover, and upgrade the reference decision programs using only granted public APIs and documentation.

---

## Stage 27 — Decision coverage and conflict analysis

**Outcome:** make decision-program coherence inspectable and deployment-blocking by analyzing one proposed version over an explicit bounded population and candidate catalog at one complete frontier for ties, forbidden overlap, missing required defaults, unreachable candidates, uncovered subjects, and material winner-distribution changes, without parsing SQL predicates or claiming proof over hypothetical facts.

**Entry gate:** the exact `v0.23.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, and every M0–M26 gate passes unchanged. Before the contract freezes, extend the M26 complete profile with an explicit typed population and candidate catalog; fully covered and uncovered subjects; present and missing required defaults; reachable and unreachable candidates; allowed and forbidden overlap; unique and tied best candidates; proposed versions below, at, and above winner-distribution limits; population, candidate, parameter, and effective-dated version changes; concurrent analysis and deployment; scheduled and eligible immediate maintenance; pause, resume, replacement, reconciliation, retention, physical and logical recovery, standby promotion, and direct upgrade. Freeze every public declaration and result, program and version, population and candidate identity, analysis frontier and fingerprint, requirement, finding, severity and blocker, canonical evidence, distribution count and delta, authorization result, normalized public-query plan, storage cost, and final checksum.

### Deliverables

- One versioned public decision-analysis declaration attached to an M26 decision program. It records one finite typed population relation and semantic key, one candidate catalog, required-default and overlap requirements, winner-distribution limits, owner and grants, and the proposed version to analyze.
- Deterministic analysis of current and proposed candidate and winner relations at one complete committed frontier, returning exact findings for tied best candidates, forbidden overlaps, missing required defaults, unreachable catalog candidates, uncovered population keys, and exceeded distribution limits.
- Canonically ordered, bounded evidence for every finding, with total affected counts and explicit truncation, plus exact current and proposed winner counts and deltas by candidate identity.
- Deployment admission that evaluates every blocking requirement against the same relation fingerprints and complete snapshot used to admit the proposed version, and rejects a stale or failed analysis before any policy, lifecycle, provenance, or work mutation.
- Public validation, analysis, status, and history results that expose the analyzed program and versions, frontier and fingerprints, requirements, findings, severities, blockers, distribution summary, support, provenance, diagnostics, authorization, and remediation without requiring private-catalog access.
- Extension `0.24.0`, compact author, reviewer, deployer, reader, and operator tasks, coverage and conflict-remediation guidance, compatibility and retention documentation, release notes, executable correctness, concurrency, failure, performance, security, recovery, and direct-upgrade evidence, and a direct upgrade from `0.23.0`.

### Supported boundary

- M27 inherits the complete M26 platform, public API, managed-worker, typed-key, security, maintenance, isolation, immediate-mode, shared-condition, retention, recovery, resource-limit, external-effect, aggregate, window, provenance, temporal, effective-dating, parameter-family, decision, diagnostic, and usability boundaries except for this analysis expansion.
- Analysis covers one decision program, one current version, one proposed version, one explicitly declared finite population relation, and one declared candidate catalog at one complete committed frontier. PostgreSQL SQL and types remain authoritative; pg-react compares materialized keys, candidates, priorities, and results and never interprets predicate text.
- An uncovered subject is a declared population key with no proposed candidate. A required default is one catalog candidate identity declared to cover every population key. An unreachable candidate is a catalog identity producing no proposed candidate for the population. A forbidden overlap is more than one proposed candidate for a subject under an exclusive requirement; a tied best priority is always reported separately.
- Winner-distribution analysis returns exact current and proposed counts and deltas by candidate identity and rejects only the frozen configured materiality limits. It does not report per-key would-be lifecycle or work changes, which belong to M30.
- A successful report proves only the analyzed relations at its recorded complete frontier. Later fact, population, parameter, or version changes may change coverage, and M26 runtime ambiguity and claim barriers remain authoritative.
- Analysis creates no activations, advances no production frontier, executes no consequence, and mutates no authoritative policy or fact relation. Only an explicitly admitted proposed version may become authoritative.

### Explicit non-goals

- A SQL predicate parser, theorem prover, SAT or SMT integration, symbolic exhaustiveness proof, generated test data, or claims about undeclared or infinite populations.
- Policy-set gating, hypothetical fact simulation, per-key deployment impact simulation, historical replay, comparative backtesting, or policy promotion workflow.
- Cross-program conflict analysis, multi-winner decisions, weighted scoring, optimization, probabilistic analysis, or arbitrary user-defined finding code.
- A decision-table DSL, spreadsheet or range syntax, generated SQL, visual table editor, client DSL, visual or AI authoring, or second evaluation engine.
- Bounded synchronous firing, unstratified negation, recursive aggregation, domain packages, or preparatory abstractions for M28 and later milestones.

### Decisions to close before the M27 contract freezes

- The exact analysis declaration, validation, execution, admission, status, history, replacement, and removal shapes; population and candidate-catalog declarations; required-default and exclusivity representation; and current and proposed version identity.
- The exact finding taxonomy, stable identity, severity, deployment-blocking policy, remediation, canonical evidence order and bound, truncation disclosure, aggregate counts, and behavior when one subject produces several findings.
- The complete-frontier and relation-fingerprint contract; whether deployment reruns or reuses analysis; stale-report detection; and the total order for concurrent population, candidate, parameter, effective-dated version, source-refresh, analysis, deployment, replacement, and reconciliation changes.
- The exact current and proposed winner-distribution shape, candidate identity scope, zero-count handling, absolute and relative materiality limits, rounding, boundary behavior, and treatment of ambiguity and uncovered subjects.
- Authorization for authors, reviewers, deployers, readers, auditors, operators, and workers; relation access; ownership and grant changes; and exact unauthorized, unavailable, drifted, over-limit, and not-retained results without leaking protected population, candidate, or decision values.
- State and index layout, active-analysis and population limits, evidence and distribution bounds, latency and storage budgets, failure injection, retention protection, standby and promotion behavior, physical and logical restore, and direct-upgrade migration.

### Exit gates

- Every analysis in the frozen fixture returns the exact program and version identities, population and candidate-catalog identities, complete frontier and fingerprints, requirements, findings, severities, blockers, canonical evidence and truncation, current and proposed distributions and deltas, support, provenance, diagnostics, authorization, remediation, and final checksum.
- Every tied best priority, forbidden overlap, missing required default, unreachable candidate, uncovered population key, and exceeded distribution limit is reported with the exact frozen identity, severity, blocker, affected count, and bounded evidence; allowed overlap and in-limit changes produce no false finding.
- Repeating analysis over the same complete frontier and relation fingerprints returns byte-for-byte identical public output regardless of physical row order, query plan, transaction order, maintenance timing, restart, or standby promotion.
- A proposed deployment with any blocking finding or stale fingerprint fails before durable mutation. A successful deployment is admitted against the frozen snapshot contract and never exposes a frontier containing an unadmitted program version or partial policy, lifecycle, provenance, or work state.
- Every empty, duplicate, missing-required, wrong-typed, unsupported, drifted, RLS-protected, unauthorized, or over-limit population, candidate-catalog, requirement, or distribution-limit declaration is rejected before durable mutation and identifies the exact condition and remediation.
- Population and candidate insert, update, and delete, parameter change, and effective-dated decision-version transition recompute or invalidate exactly the affected analysis under the frozen invalidation contract and never silently reuse stale evidence.
- Current and proposed winner distributions report exact counts and deltas at, below, and above every frozen materiality boundary, including zero-count, ambiguity, default, and uncovered-subject cases, without expanding into per-key M30 impact simulation.
- Every supported interleaving of analysis, deployment, population or candidate change, pause, replacement, reconciliation, retention, and recovery reaches a state equivalent to an allowed serialization; every rejected interleaving fails within its published bound without a partial report or deployment.
- Coordinator failure before and after every frozen commit, managed-worker restart, PostgreSQL crash/restart, forward and backward clock adjustment, standby promotion, and overdue catch-up preserve the last complete analysis and deployment frontier and reproduce the exact report or explicit invalidation.
- Every reader, author, reviewer, deployer, operator, worker, unrelated role, and `PUBLIC` case returns the exact authorized or denied declaration, analysis, admission, status, and history result after grant, revoke, ownership change, replacement, retention, restore, and upgrade without leaking protected population, candidate, decision, or distribution values.
- The maximum frozen active-program, population-row, candidate-row, finding, evidence, dependency-fan-out, and retained-analysis profiles remain within their published analysis latency, memory, storage, backup, restore, and upgrade budgets and fail admission before exceeding the supported envelope.
- Retention, replacement, reconciliation, physical restore, dump/restore, and direct `0.23.0 -> 0.24.0` upgrade preserve or repair the exact declarations, requirements, versions, analysis frontiers and fingerprints, findings, distributions, grants, diagnostics, and continued deployment-admission behavior.
- Every inherited M0–M26 semantic, operational, security, recovery, performance, compatibility, documentation, usability, retention, provenance, temporal, parameter, decision, and external-effect gate passes unchanged.
- Non-superuser authors, reviewers, deployers, readers, and operators can declare, validate, analyze, inspect, diagnose, remediate, admit, replace, remove, recover, and upgrade the reference decision analyses using only granted public APIs and documentation.

---

## Stage 28 — Public API convergence and ergonomics

**Outcome:** make every representative M0–M27 capability usable through one coherent, names-first PostgreSQL workflow—define, validate, preview, deploy, run, and inspect—by freezing versioned declarations and targets, a small ordinary verb set, common result and finding envelopes, and public API governance, without removing specialized APIs, changing existing semantics, or creating a second evaluation or deployment engine.

**Entry gate:** the exact `v0.24.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, and every M0–M27 gate passes unchanged. Before the contract freezes, generate the complete released M0–M27 inventory of public functions, overloads, arguments, defaults, result types, grants, volatility, security-definer status, views, types, and contract versions; freeze the ordinary, advanced, compatibility, administrative, and internal classifications; and capture exact specialized-API transcripts and results for one command rule, derived program, practical temporal rule, effective-dated or parameterized policy, M26 decision program, and M27 decision analysis and deployment admission.

### Deliverables

- One checked-in, machine-readable inventory and classification of every M0–M27 public function, overload, view, type, grant, result contract, and ordinary documentation reference, enforced as a release gate for future public additions.
- One versioned declaration envelope and one names-first, schema-qualified target reference with strict field validation, explicit defaults, options and deployment preconditions, canonical normalization, deterministic digests, unambiguous resolution, and no silently ignored future fields.
- A deliberately small ordinary façade for `validate`, `preview`, `deploy`, `remove`, `run`, `status`, `explain`, and `doctor`, with the exact `replace` decision closed before freeze and complex inputs represented as named declaration or options fields rather than long positional signatures.
- Representative declaration and façade coverage for constraint and command rules, derived programs, temporal and deadline policy, shared conditions, effective-dated policy, parameter families, decision programs, and M27 decision coverage and admission, all delegated to the same authoritative implementation as the specialized APIs.
- Stable, versioned result envelopes and one error and finding taxonomy covering target identity, operation, state, summary, field paths, severity, blockers, remediation, stale evidence, authorization, bounded evidence, diagnostics, compatibility notices, and explicit truncation, while preserving public relational views for fleet-wide inspection.
- Names-first ordinary documentation organized around one lifecycle, a separate lossless advanced and compatibility reference, executable examples, an API-ergonomics scorecard, and a governance rule requiring a Public API impact section and an ADR before any genuinely new top-level ordinary verb is added.
- Extension `0.25.0`, compact author, reviewer, deployer, reader, and operator tasks, compatibility and migration guidance, release notes, executable semantic-equivalence, concurrency, failure, performance, security, recovery, usability, and direct-upgrade evidence, and a direct upgrade from `0.24.0`.

### Supported boundary

- M28 inherits the complete M27 platform, public API, managed-worker, typed-key, security, maintenance, isolation, immediate-mode, shared-condition, retention, recovery, resource-limit, external-effect, aggregate, window, provenance, temporal, effective-dating, parameter-family, decision, analysis, diagnostic, and usability boundaries except for this additive interaction layer.
- The façade covers the ordinary authoring and inspection path for the frozen representative fixtures. Specialized APIs remain supported and authoritative for compatibility, advanced controls, explicit frontiers, reusable analyses, exact operational actions, recovery, and lossless evidence.
- Equivalent façade and specialized operations share validation, locking, mutation, lifecycle, evidence, recovery, and authorization implementations. Objects created by either surface are indistinguishable through lossless inspection; no state migration or declaration rewrite is required.
- `validate`, `preview`, `status`, `explain`, and `doctor` are read-only. `deploy` and `remove` preserve each object kind's exact atomicity, stale-precondition, ownership, and lifecycle contracts; `run` preserves the existing bounded engine semantics.
- Declarations reference PostgreSQL relations, columns, functions, and policy objects rather than encoding predicates or transformations in a second language. Generic calls complement, rather than replace, stable relational views.
- Every ordinary workflow accepts stable public names and business keys. Immutable IDs remain returned and queryable but are required only for explicit historical or version-specific work.

### Explicit non-goals

- Removing, renaming, behaviorally weakening, or noisily deprecating an M0–M27 public function, overload, result, grant, view, or specialized workflow.
- A generic stringly typed action executor, proprietary rule language, JSON predicate language, client SDK, visual editor, AI authoring layer, or one declaration constructor per feature.
- Policy-set gating, hypothetical fact simulation, deployment impact simulation, historical replay, comparative backtesting, policy promotion workflow, new temporal operators, new decision semantics, bounded synchronous firing, automatic repair, unstratified negation, or recursive aggregation.
- Collapsing distinct administrative, reconciliation, retry, correction, finalization, watermark, retention, migration, or recovery actions whose separate safety contracts remain material.
- Granting generic callers broader authority or evidence than the corresponding specialized operation, exposing private relation identities, accepting unsafe search paths or arbitrary SQL, or changing row-level disclosure boundaries.

### Decisions to close before the M28 contract freezes

- The exact declaration and target PostgreSQL representations, API-version policy, supported object kinds, schema-qualified name resolution, normalization and digest algorithm, default expansion, unknown-field behavior, options, preconditions, and historical-version targeting.
- The exact ordinary verb identities, overloads, grants, volatility, result types, positional-argument budget, create-versus-replace contract, stale-preview behavior, removal semantics, and boundary between ordinary, advanced, compatibility, administrative, and internal surfaces.
- The exact result-envelope version and fields; finding identity, severity, blocker and remediation meanings; canonical evidence order and bounds; truncation, stale-evidence, authorization, unavailable, compatibility, and error representation; and feature-specific extension rules.
- The delegation and equivalence contract for every representative object kind, including validation, locking, normalization, mutation, lifecycle, provenance, diagnostics, recovery, and final checksum, plus the total order for concurrent façade and specialized operations.
- Ownership, role and `PUBLIC` grants, RLS and relation-access boundaries, security-definer behavior, disclosure limits, safe reference resolution, and exact unauthorized results without leaking protected declarations, subjects, findings, or evidence.
- Inventory generation and CI comparison, API-review and ADR policy, documentation tiering and glossary, executable-example and independent-usability fixtures, ergonomics scorecard, acceptable façade overhead, resource bounds, failure injection, retention, standby behavior, restore, and direct-upgrade migration.

### Exit gates

- Every frozen representative workflow completes through `define -> validate -> preview -> deploy -> run -> status/explain` using only ordinary documentation, stable names, business keys, and the canonical façade; no feature-specific status, doctor, analysis, or admission function is required.
- For every fixture, the façade and specialized API produce byte-for-byte equivalent normalized declarations, digests, durable state, public truth, lifecycle, provenance, evidence, findings, diagnostics, grants, and final checksums, regardless of JSON key order, physical row order, query plan, restart, restore, upgrade, or standby promotion.
- Generic M27 preview returns the exact frozen distributions, findings, severities, blockers, evidence order and truncation, authorization, and remediation, and generic deployment rejects failed or stale analysis before any policy, lifecycle, provenance, or work mutation.
- `validate`, `preview`, `status`, `explain`, and `doctor` create no durable state, jobs, actions, lifecycle changes, frontier changes, or hidden repair; rejected `deploy` and `remove` operations leave the same exact no-mutation checksum.
- Every released M0–M27 public identity, overload, default, result shape, grant, view, and semantic contract remains present and unchanged, and eligible existing objects are manageable through the façade without migration.
- Every caller receives exactly the authority and evidence available through the corresponding specialized API after grant, revoke, ownership change, replacement, retention, restore, and upgrade; unrelated roles and `PUBLIC` gain no access, and protected declarations, subjects, findings, and evidence do not leak.
- The machine-readable inventory contains no unclassified public surface; CI detects every addition or compatibility change; ordinary documentation presents one lifecycle and one advanced compatibility reference; and every new ordinary verb has the required approved justification.
- Ordinary examples stay within the frozen scalar-argument and concept budgets, use named declaration fields for complex inputs, require no UUID or private-catalog knowledge, and return consistent versioned envelopes and actionable field-path remediation.
- Fresh install, direct `0.24.0 -> 0.25.0` upgrade, crash/restart, physical restore, logical restore, reconciliation, retention, and standby promotion preserve every M0–M27 identity and state and reproduce exact façade/specialized equivalence.
- Every ordinary documentation snippet executes in CI, and an independently observed PostgreSQL developer can discover, recover from one intentional validation failure, preview the M27 decision findings, and deploy safely without maintainer interpretation.
- The maximum frozen declaration size, target count, evidence, finding, dependency-fan-out, and concurrent-operation profiles remain within published latency, memory, storage, backup, restore, and upgrade budgets; façade overhead stays within its published bound and duplicates no materialization, analysis, or evaluation work.
- Every inherited M0–M27 semantic, operational, security, recovery, performance, compatibility, documentation, usability, retention, provenance, temporal, parameter, decision, analysis, and external-effect gate passes unchanged.
- Non-superuser authors, reviewers, deployers, readers, and operators can define, validate, preview, deploy, run, inspect, explain, diagnose, remove, recover, and upgrade the representative objects using only granted public APIs and documentation.

---

## Stage 29 — Policy-set gating

**Outcome:** make policy applicability an explicit, versioned, deployable boundary by grouping versioned policy targets into one policy set and gating them with one finite typed PostgreSQL population relation or named shared condition at complete frontiers, so jurisdiction, product, tenant, contract, and rollout-cohort changes reuse unchanged policy logic and inherited lifecycle semantics without hidden engine flags or a second evaluator.

**Entry gate:** the exact `v0.25.0` release artifacts, checksums, disclosures, OCI digest, SBOM, provenance, and populated direct-upgrade path are published and verified, and every M0–M28 gate passes unchanged. Before the contract freezes, extend the M28 representative fixtures with two immutable versions of one policy set; relation-backed and shared-condition-backed applicability; present, absent, null, duplicate, and wrong-typed subject keys; empty and changing populations; constraint, command, derivation, temporal, effective-dated, parameterized, and decision members; scheduled and eligible immediate maintenance; effective-boundary, member-replacement, gate-replacement, pause, resume, reconciliation, retention, physical and logical recovery, standby promotion, and direct-upgrade transitions. Freeze every declaration, target, member and applicability identity, normalized digest, complete frontier and fingerprint, eligible-subject result, lifecycle and work transition, finding, evidence bound, authorization result, public-query plan, storage cost, and final checksum.

### Deliverables

- One `policy_set` kind in the M28 versioned declaration model, with a stable public name, immutable version, finite duplicate-free member targets, one applicability source and typed subject key, explicit effective bounds, strict validation, canonical normalization, deterministic digests, and no silently ignored fields.
- Applicability through either one schema-qualified finite PostgreSQL relation or one M20 named shared condition. Both use the existing typed-key codec, complete-frontier and fingerprint contracts and require one non-null, unique gate row per eligible subject.
- Deterministic composition of each member's existing truth with set eligibility. Gate entry and exit use every applicable inherited lifecycle, work, lease, and recovery semantic without copying predicates, materializing a second policy result, or executing a separate evaluation path.
- The existing `validate`, `preview`, `deploy`, `remove`, `run`, `status`, `explain`, and `doctor` façade, common finding and result envelopes, stable names-first targets, and public relational inspection extended for policy-set versions, members, applicability, effective state, eligible subjects, lifecycle, provenance, and diagnostics; no new ordinary verb.
- Atomic set-version deployment, replacement, effective transition, and removal with stale-precondition checks, explicit immutable-version or effective-schedule member binding, deterministic source-change invalidation, bounded evidence, exact authorization, and no partial policy, applicability, lifecycle, provenance, or work state.
- Extension `0.26.0`, compact author, reviewer, deployer, reader, and operator tasks, compatibility and migration guidance, release notes, executable correctness, concurrency, failure, performance, security, recovery, usability, and direct-upgrade evidence, and a direct upgrade from `0.25.0`.

### Supported boundary

- M29 inherits the complete M28 platform, specialized and ordinary APIs, managed-worker, typed-key, security, maintenance, isolation, immediate-mode, shared-condition, retention, recovery, resource-limit, external-effect, aggregate, window, provenance, temporal, effective-dating, parameter-family, decision, analysis, diagnostic, and usability boundaries except for this applicability layer.
- One flat policy-set version contains a bounded list of exact, already-deployed policy-bearing targets and one finite applicability source with one common typed subject-key contract. Non-scheduled members bind one immutable target version; effective-dated members bind an M24 stable policy schedule and inherit its authoritative version selection. Sets cannot contain sets; inline member declarations and cross-database sources are rejected.
- Supported members are the frozen representative constraint and command rules, derivation programs, temporal and effective-dated policies, parameterized policies, and decision programs. Applicability changes only eligibility; member predicates, parameters, priorities, results, effective intervals, ownership, and immutable identities remain authoritative and unchanged.
- A subject is eligible exactly when the deployed set version is effective and its applicability source contains the subject key at the sampled complete frontier. Absence is default-deny; null, duplicate, drifted, unavailable, unauthorized, or over-limit applicability fails under the frozen validation or runtime barrier rather than widening eligibility.
- Applicability-row changes are ordinary authoritative fact changes. They enter or withdraw member truth through each member's existing lifecycle, old-work, fresh-eligibility, reconciliation, and recovery contracts; completed history retains the exact policy-set and member-version identities that produced it.
- Policy-set effective bounds reuse M24's canonical half-open `[valid_from, valid_to)` contract. PostgreSQL relations and named shared conditions remain the sources of applicability truth; pg-react neither mutates them nor invents an independent gate state.

### Explicit non-goals

- Hypothetical fact simulation, deployment impact simulation, historical replay, comparative backtesting, why-changed explanation, policy promotion workflow, approval routing, or rollback orchestration.
- Replacing M5 rule packs, atomically authoring member definitions, inferring removals, rewriting member declarations, or changing existing specialized deployment workflows.
- Nested policy sets, arbitrary Boolean gate expressions, ordered gate precedence, exception inheritance, hierarchical tenant or jurisdiction resolution, cross-set optimization, or implicit composition. Authors may express richer applicability in the one PostgreSQL relation or named condition.
- Engine feature flags, session flags, a predicate parser, generated SQL, proprietary policy or gate DSL, client SDK, visual editor, AI authoring layer, or a second evaluation engine.
- New decision selection, parameter, temporal, synchronous-firing, unstratified-negation, recursive-aggregation, tuple-lineage, external-effect, or consequence semantics.
- Broader authority, RLS support, protected subject disclosure, unsafe search paths, arbitrary SQL execution, or visibility beyond the corresponding member and applicability-source grants.

### Decisions to close before the M29 contract freezes

- The exact policy-set declaration and target representation, immutable version identity, effective bounds, member ordering for normalization only, supported member-kind matrix, member-version resolution, unknown-field behavior, size limits, normalized digest, replacement, and removal preconditions.
- The exact common subject-key declaration and mapping, supported types and arity, relation-backed and shared-condition-backed source identity, uniqueness and null checks, complete-frontier and fingerprint contract, empty-source behavior, schema drift, source replacement, and stale-preview detection.
- Whether one member version may participate in several effective sets; the exact overlap, duplicate, and conflicting-effective-period rules; and the failure contract that prevents duplicate activation, derivation, decision, lifecycle, or work.
- The exact gate-entry and gate-exit transition for every supported member kind, including generation, revision, refraction, derived support, decision winners, deadlines, cooldown and hysteresis, pending and retrying work, leased fresh-eligibility checks, completed history, and scheduled versus immediate maintenance.
- The total lock and serialization order for concurrent set deployment, member replacement or removal, applicability insert, update, delete or replacement, effective-boundary transition, maintenance, claim, reconciliation, pause, restore, and standby promotion.
- The exact envelope extensions, finding identities and severities, blocker and remediation meanings, canonical eligible-subject and member evidence, counts, bounds, truncation, relational views, history, provenance, diagnostics, retention protection, and unavailable or not-retained results.
- Ownership, author, reviewer, deployer, reader, auditor, operator, and worker grants; authority intersection across a set, its members, and its applicability source; RLS and relation-access rejection; ownership changes; and non-leaking unauthorized results.
- Catalog and index layout, active-set, member, subject, evidence, and dependency-fan-out limits, latency and storage budgets, failure injection, backup and restore behavior, logical migration, direct-upgrade migration, and public-inventory governance.

### Exit gates

- Every declaration in the frozen fixture returns the exact normalized set and version identity, effective bounds, member targets, applicability source and subject key, complete frontier and fingerprints, digest, eligible-subject count and bounded evidence, findings, authorization, lifecycle, provenance, diagnostics, remediation, and final checksum.
- Every member produces exactly its existing result for eligible subjects and no result for ineligible subjects; relation-backed and equivalent shared-condition-backed gates produce the same eligible keys and downstream member truth, lifecycle, and work while retaining their distinct source identity, fingerprint, and provenance.
- Repeating read-only validation, preview, status, and explanation over the same frozen durable state returns byte-for-byte identical public output regardless of JSON key order, member or source-row order, query plan, restart, restore, upgrade, or standby promotion; mutating operations reach the exact final state required by their allowed serialization.
- Every empty, missing, duplicate, null, wrong-typed, unsupported, unqualified, drifted, RLS-protected, unauthorized, cyclic, stale, overlapping, or over-limit set, member, source, key, or effective declaration returns the exact frozen finding and leaves the complete no-mutation checksum unchanged.
- Set deployment, replacement, effective transition, and removal are individually atomic and serialize against member deployment and source change: no reader, worker, or standby observes a partial member list, mixed set versions, a widened fail-open population, or policy, lifecycle, provenance, and work state from incompatible frontiers.
- Applicability insert, update, and delete enter, revise, withdraw, and re-enter exactly the affected member results under each applicable inherited generation, refraction, support, decision, deadline, work, lease, and recovery contract, without duplicate evaluation, activation, derived truth, decision winners, or consequences.
- Gate and member replacement at every frozen effective-time boundary selects exactly one allowed set and member version, preserves old completed history, handles pending and leased work under the frozen transition matrix, and never invents an interval of unintended applicability.
- Every supported interleaving of set deployment, member change, applicability change, maintenance, claim, pause, reconciliation, replacement, removal, retention, and recovery reaches a state equivalent to an allowed serialization; every rejected interleaving fails within its published bound without partial mutation.
- Coordinator failure before and after every frozen commit, managed-worker restart, PostgreSQL crash/restart, forward and backward clock adjustment, overdue catch-up, physical restore, logical restore, and standby promotion preserve or reproduce the last complete applicability and member frontier or return the exact explicit barrier.
- Every author, reviewer, deployer, reader, auditor, operator, worker, unrelated role, and `PUBLIC` case returns the exact authorized or denied declaration, preview, deployment, eligible-subject, status, explanation, and history result after grant, revoke, ownership change, replacement, retention, restore, and upgrade without leaking protected set, member, source, or subject values.
- The maximum frozen active-set, member, applicability-row, source-change, evidence, dependency-fan-out, and retained-history profiles remain within their published maintenance, claim, preview, latency, memory, storage, backup, restore, and upgrade budgets and fail closed before exceeding the supported envelope.
- Retention, replacement, reconciliation, physical restore, dump/restore, and direct `0.25.0 -> 0.26.0` upgrade preserve or repair the exact set declarations, versions, members, applicability identities, frontiers, fingerprints, digests, grants, lifecycle, provenance, diagnostics, and continued runtime eligibility.
- The public API inventory contains only the approved `policy_set` declaration extension and relational inspection surface; ordinary documentation completes the reference jurisdiction and rollout-cohort tasks through the M28 lifecycle with stable names, executable examples, actionable findings, and no UUID or private-catalog knowledge.
- Every inherited M0–M28 semantic, operational, security, recovery, performance, compatibility, documentation, usability, retention, provenance, temporal, parameter, decision, analysis, API-governance, and external-effect gate passes unchanged.
- Non-superuser authors, reviewers, deployers, readers, auditors, and operators can define, validate, preview, deploy, run, inspect, explain, diagnose, replace, remove, recover, and upgrade the reference policy sets using only granted public APIs and documentation.

---

## Stage 30 — Applicability foundation

**Outcome:** establish the authoritative applicability foundation for policy-set runtime truth: identity model, scope semantics, disposition matrix, relational eligibility and support state, migrations, inspection primitives, and exact applicability fixtures. M30 is a contract and schema milestone; it does not claim complete ordinary runtime behavior.

**Release boundary:** M30 freezes the applicability contract. Its exit gate is the former M30-A foundation gate; no runtime implementation may redefine these semantics afterward.

**Release candidate:** extension `0.27.0`, with direct upgrade `0.26.0 -> 0.27.0`; publish only after the complete M30 gate and inherited M0–M29 evidence pass.

**Entry gate:** the exact `v0.26.0` release artifacts and populated upgrade evidence are published and verified, and every M0–M29 gate passes unchanged. Before implementation, freeze the applicability fixture transcript proving that one raw rule match plus one ineligible subject is out of scope, eligibility entry and exit are represented exactly, reentry is a new generation, and the claimed-work identity/data required for later revalidation can be inspected. M30 freezes that revalidation input only; M31 proves the actual skip and withdrawal execution semantics.

### Deliverables

- Canonical `match_keys`, `subject_keys`, and immutable `GLOBAL` or `POLICY_SET_REQUIRED` scope mode, reusing typed-key codec v2 for one-to-four non-null ordered `bigint`, `uuid`, or `text COLLATE "C"` components.
- One frozen v1 disposition matrix classifying every declaration and policy-set member kind as fully authoritative, supported with documented limitations, experimental, or unsupported and fail-closed.
- Indexed relational eligibility and scope-support schemas owned by exact policy-set versions; JSONB is bounded evidence and transport, never authoritative eligibility state.
- Migration states for existing M28 and M29 data, including `GLOBAL`, `LEGACY_METADATA`, and `NEEDS_SCOPE_MIGRATION`, without silent scope activation.
- Public relational inspection primitives for eligibility, raw and effective truth, scope supports, migration state, barriers, and bounded evidence without per-target function calls.
- Failing, then passing, applicability fixtures that assert exact identities, scope transitions, support counts, valid-empty behavior, and invalid-source barriers rather than counts alone.

### Supported boundary

- M30 freezes the identity, scope, disposition, storage, migration, and inspection contracts that M31 will execute.
- M30 freezes the claimed-work identity and data required for M31 revalidation, but not the resulting skip or withdrawal behavior.
- A scoped match is modeled as effective only when raw member truth exists and at least one current policy-set-version support admits its subject.
- Match identity and subject identity are independent; several matches may share one subject, and several sets may support one match without implying duplicate activation or work.
- Existing M28 delegated rules and decisions migrate as `GLOBAL`; metadata-only declarations remain inspectable as `LEGACY_METADATA`; existing M29 sets remain `NEEDS_SCOPE_MIGRATION`.
- M30 does not promise authoritative adapters, global coordination, lifecycle closure, work execution, or release qualification.

### Explicit non-goals

- Authoritative ordinary-kind adapters, generic removal, global coordination, lock ordering, lifecycle and support transitions, claimed-work revalidation, frontier advancement, recovery, or release qualification; these belong to M31.
- Hypothetical fact simulation, deployment-impact comparison, historical replay, comparative backtesting, or arbitrary why-changed comparison.
- Nested policy sets, Boolean or hierarchical gate expressions, ordered precedence, cross-database applicability, or implicit latest-version resolution.
- A custom policy DSL, generated predicates, arbitrary declaration-supplied SQL, client SDKs, visual or AI authoring, or a second evaluator.

### Decisions to close before the M30 contract freezes

- Exact identity normalization and compatibility treatment for `semantic_key`, `semantic_keys`, and scalar `subject_key`.
- Exact scope modes, disposition classes, eligibility and scope-support identities, schemas, indexes, limits, retention, and bounded evidence.
- Exact migration states, upgrade preservation rules, invalid-source barriers, and no-mutation guarantees.
- Exact public inspection columns, authorization, protected-subject disclosure, source-access role, unsupported-RLS, and safe-search-path contracts.

### Exit gates — applicability contract frozen

- Match and subject identities work independently for every supported codec-v2 type and arity, with deterministic normalization and no alternate policy-set codec.
- The disposition matrix rejects unsupported or metadata-only ordinary behavior before mutation and records every supported limitation.
- Relational eligibility and scope-support state is indexed, bounded, migration-aware, and inspectable without authoritative JSON-array scans or whole-set rewrites.
- The populated migration classification preserves all required identities, history, grants, and M29 evidence with no silent scope activation.
- The applicability fixtures fail against the pre-M30 behavior and pass against the completed M30 foundation with exact expected output, including valid-empty and invalid-source cases.
- The M30 contract, schema, migration, inspection, and fixture records are committed and independently reviewable before M31 begins.

---

## Stage 31 — Authoritative runtime

**Outcome:** make policy-set applicability and every ordinary façade operation authoritative, fail-closed, inspectable, and testable on the M30 foundation. Release target extension `0.28.0`; the working tree remains the M30 `0.27.0` foundation plus an unqualified M31 SQL layer until the M31 gates pass.

**Release boundary:** M31 freezes runtime truth: adapters, coordination, atomicity, lifecycle, work, frontiers, barriers, concurrency, and recovery are authoritative against the unchanged M30 applicability contract.

**Entry gate:** every M30 exit gate passes and its applicability contract, schema, migrations, inspection primitives, and exact fixtures are committed. M31 MUST NOT redefine identity, scope, disposition, eligibility, or support semantics; the exact `v0.26.0` release artifacts and every inherited M0–M29 gate must also remain green.

### Deliverables

- Complete authoritative adapters for ordinary `rule`, `decision_program`, and `policy_set` declarations across validation, preview, deployment, removal, status, explanation, diagnostics, authorization, migration, recovery, and global execution.
- Generic deployment of advanced-only kinds rejected before mutation with stable actionable findings; specialized APIs remain supported.
- One effective activation and lifecycle per member match, regardless of supporting-set count; lifecycle and support transitions occur only when total scope support crosses zero.
- A single global coordinator with a documented total lock order for applicability, member truth, decisions, derivations, lifecycle, work, claims, leases, replacements, removals, recovery, and frontiers.
- Claimed-work revalidation and exact lifecycle, support, withdrawal, skip, provenance, and frontier transitions for eligibility entry, exit, return, expiry, removal, and overlapping-set changes.
- Fail-closed runtime barriers for unavailable, unauthorized, drifted, incomplete, malformed, RLS-protected, or over-limit applicability sources, distinct from a valid empty population.
- Truthful `deploy`, `run`, `remove`, `status`, `explain`, and `doctor`; read-only operations preserve the exact authoritative checksum.
- Race, crash, restart, physical and logical restore, standby promotion, retention, reconciliation, and security testing that preserves agreement or establishes the exact published barrier.
- A continuous v1 qualification lane covering fresh installation, populated direct upgrade from `0.26.0`, rollback-by-restore and recovery, role isolation, packaged-artifact execution, and current performance budgets.
- Extension `0.28.0`, complete install and direct-upgrade SQL, contract, evidence, readiness, upgrade and release documentation, API inventory, and executable correctness, concurrency, security, recovery, performance, usability, and upgrade fixtures.

### Supported boundary

- Ordinary deployable kinds are `rule`, `decision_program`, and `policy_set`; derivation, temporal, shared-condition, effective-policy, parameter-family, analysis, repair, retry, reconciliation, retention, and recovery workflows remain specialized.
- A scoped match is effective exactly when raw member truth exists and at least one current policy-set-version support admits its subject.
- Match identity and subject identity are independent; several matches may share one subject, and several sets may support one match without duplicate activation or work.
- Valid empty applicability withdraws supports through ordinary lifecycle semantics; invalid applicability preserves the last complete frontier and blocks affected maintenance and execution.
- Global `run(sampled_time)` is the only ordinary coordinator operation. Any retained target overload must validate its target, perform the complete global run, and report global scope.
- Existing M28 delegated rules and decisions migrate as `GLOBAL`. Metadata-only declarations remain inspectable as `LEGACY_METADATA`; existing M29 sets remain `NEEDS_SCOPE_MIGRATION`.
- The direct upgrade preserves durable data and immutable identities and must not activate gating, create activations, withdraw work, or invent runtime objects.
- Existing lifecycle, decision, derivation, temporal, work-recheck, authorization, recovery, retention, and external-effect contracts remain authoritative.

### Explicit non-goals

- Hypothetical fact simulation, deployment-impact comparison, historical replay, comparative backtesting, or arbitrary why-changed comparison.
- Nested policy sets, Boolean or hierarchical gate expressions, ordered precedence, cross-database applicability, or implicit latest-version resolution.
- A custom policy DSL, generated predicates, arbitrary declaration-supplied SQL, client SDKs, visual or AI authoring, or a second evaluator.
- New decision-selection, temporal, parameter, synchronous-consequence, negation, recursive-aggregation, tuple-lineage, or exactly-once external-effect semantics.
- Automatic repair, unfrozen RLS behavior, policy promotion workflow, or a final `1.0.0` compatibility promise.

### Decisions to close before the M31 contract freezes

- Exact adapter registry, advanced-only findings, removal semantics, and remediation for legacy metadata.
- Exact lifecycle, temporal-state, derivation-support, decision-winner, and claimed-work recheck transitions for every supported member kind.
- Total coordinator and deployment, replacement, removal, claim, lease, recovery, and applicability-change lock order and serialization contract.
- Exact supported active-set, member, eligible-subject, scope-support, fan-out, evidence, latency, memory, storage, backup, restore, and upgrade limits.
- Exact authorization, ownership intersection, protected-subject disclosure, source-access role, unsupported-RLS, and safe-search-path contracts.

### Exit gates — runtime truth frozen

- Ineligible subjects create or retain no effective member truth, winner, scoped derived support, lifecycle transition, or executable work.
- Eligibility entry, exit, return, expiry, removal, and overlapping-set transitions produce exact generations, revisions, supports, events, episodes, withdrawals, skips, and provenance without duplication.
- Applicability and member changes commit in atomic agreement across eligibility, supports, effective truth, lifecycle, decisions, derivations, work, attempts, frontiers, and explanations.
- Every ordinary kind has a complete runtime adapter; unsupported kinds fail before mutation, and metadata alone is never reported as deployed.
- Generic removal retires authoritative runtime behavior and applies required lifecycle and work transitions atomically.
- Status, explanation, doctor, and public views agree exactly; validation, preview, status, explanation, and doctor leave authoritative state unchanged.
- Required races, crashes, restarts, physical and logical restores, standby promotion, retention, reconciliation, and security matrices preserve agreement or establish the exact published barrier.
- The populated direct `0.26.0 -> 0.27.0` upgrade preserves all required identities, history, grants, frontiers, lifecycle, work, and M29 evidence with no silent scope activation.
- Every ordinary documentation example executes in CI, and the scoped-rule reference workflow requires no UUID input, private catalog access, or maintainer interpretation.
- The independent technical review has no unresolved blocker; fresh-install, populated-upgrade, rollback-by-restore, recovery, role-isolation, packaged-artifact, and performance evidence has remained green throughout M31.
- The five-person M32 usability cohort is recruited before M31 closes, and early golden-path transcript or prototype feedback is recorded while the interface can still change.
- Every inherited M0–M29 semantic, operational, security, recovery, performance, compatibility, documentation, usability, and API-governance gate passes unchanged.
- All simulation, comparison, replay, backtesting, and why-changed work remains deferred until after M31 runtime truth, subsequent PostgreSQL-native ergonomics, and v1 hardening are complete.

---

## Stage 32 — PostgreSQL-native interface

**Outcome:** make the authoritative M31 product feel like PostgreSQL with durable rules: ordinary users author typed declarations, operate by stable names, inspect relational state, receive actionable diagnostics, and complete common workflows without hand-written JSON, internal UUIDs, private catalogs, milestone-specific APIs, or engine vocabulary.

**Release boundary:** M32 freezes the public PostgreSQL-native API and UX: ordinary schemas, constructors, verbs, views, diagnostics, exports, and task workflows.

**Entry gate:** extension `0.28.0` is published; every M31 exit gate passes and runtime truth is frozen. M30 and M31, the independent technical review, runtime truth, policy-set gating, work revalidation, façade delegation, removal, migration, continuous qualification evidence, and every inherited M0–M29 semantic, security, recovery, concurrency, and compatibility gate pass. The recruited five-person usability cohort has already provided recorded early design feedback. Before freeze, approve one executable golden-path transcript covering condition view, typed action, `pgreact.rule`, preview, deploy, global run, matches, work, and explanation.

### Deliverables

- One canonical ordinary schema, `pgreact`, for supported public functions, types, and views; `pgreact_internal` remains private and required `pgreact_api` compatibility wrappers delegate to the same authoritative implementation.
- Typed PostgreSQL constructors for every ordinary deployable kind, at minimum `pgreact.rule`, `pgreact.decision`, and `pgreact.policy_set`, normalizing into the existing canonical versioned declaration model.
- One frozen ordinary verb set: `validate`, `preview`, `deploy`, `remove`, `status`, `explain`, `doctor`, and globally serialized `run`.
- Exact PostgreSQL object identity through schema-qualified `regclass` and `regprocedure`, typed keys and values, safe defaults, fail-rather-than-guess inference, and stale-safe deployment preconditions.
- Compact relational inspection for rules, matches, decisions, policy sets, work, attempts, and fleet health, sufficient for ordinary author and operator questions without private-catalog joins.
- One stable finding structure—`code`, `severity`, `blocking`, `target`, `field`, `message`, `hint`, and `details`—with an inventory of compatibility-governed finding codes.
- Deterministic canonical export of every ordinary deployed object, suitable for validation, diffing, migration, Git storage, and deployment into another compatible environment.
- Task-first documentation, one verbatim executable first-rule workflow, task-oriented SQL fixtures, complete API classification, compatibility guidance, and extension `0.29.0`.
- Continued fresh-install, populated `0.26.0` upgrade, rollback-by-restore, recovery, role-isolation, packaged-artifact, and frozen benchmark evidence against every M32 candidate.
- Required contract, API-reference, migration, usability, evidence, and readiness documents; constructor and wrapper SQL; documentation tests; populated direct-upgrade and export/import fixtures.

### Supported boundary

- M32 changes presentation, authoring, inspection, diagnostics, and documentation only; M31 remains the single authoritative runtime and deployment model.
- PostgreSQL relations define conditions and candidates; typed PostgreSQL functions or registered external sinks define actions; PostgreSQL data defines parameters and applicability.
- Generic JSON declarations remain supported as canonical interchange for CI, GitOps, promotion, import, export, digests, automation, and future bindings, but are not the primary hand-authored path.
- Routine workflows use stable names; immutable UUIDs, versions, digests, episodes, supports, frontiers, and fingerprints remain available as advanced evidence and history.
- Commonly filtered, joined, aggregated, alerted-on, or monitored state is relational; JSONB is reserved for canonical declarations, bounded nested evidence, proof trees, and extensible detail.
- Compatibility APIs may remain, but documentation teaches one canonical path and no wrapper may create a second behavioral implementation.
- `preview` reports normalized identity, defaults, shape, counts, fingerprints, replacement state, findings, and bounded evidence; it does not promise exact hypothetical lifecycle effects.

### Explicit non-goals

- New rule, reasoning, temporal, decision-selection, policy-set, execution, delivery, lifecycle, support, or retraction semantics.
- A proprietary predicate language, YAML condition syntax, JavaScript evaluator, client DSL, second evaluator, or second deployment engine.
- Deployment-impact simulation, hypothetical fact simulation, historical replay, comparative backtesting, or why-changed comparison.
- New feature-specific coordinators, target-specific `run`, duplicate ordinary verbs, metadata-only targets, or placeholder explanations.
- A hosted CI/CD service, policy-promotion engine, approval workflow, visual editor, SDK, cloud control plane, or arbitrary SQL lineage.
- Removal of released compatibility APIs merely to reduce inventory size.

### Decisions to close before the M32 contract freezes

- Exact constructor signatures, named-argument contracts, defaults, bounded options structures, unknown-field behavior, and overload-resolution rules.
- Exact canonical schema migration, wrapper inventory, grants, deprecation classification, and behavior of every pre-v1 public object.
- Exact ordinary view inventory, required columns, meanings, retention behavior, evidence bounds, and advanced-identity exposure.
- Exact target syntax, action representation, decision constructor fields, policy-set constructor fields, export format, declaration version, and environmental identity resolution.
- Exact finding-code registry, severity and blocking rules, SQLSTATE use, message stability boundary, and remediation requirements.
- Exact replacement and removal preconditions, create-versus-replace behavior, stale-preview checks, and deterministic digest rules.
- Exact usability protocol, benchmark profiles required by M33, documentation fixture inventory, and supported resource bounds visible during authoring.

### Exit gates — public API/UX frozen

- Every ordinary deployable kind has a typed constructor and the complete ordinary workflow requires neither hand-written JSON nor an internal UUID.
- The canonical `pgreact` schema is implemented, every public object is classified, and every compatibility wrapper delegates to authoritative behavior.
- Public relational views plus `status`, `explain`, and `doctor` answer all frozen author and operator questions without private catalogs.
- Every frozen invalid declaration returns the exact actionable stable finding and leaves authoritative state unchanged.
- Only global `pgreact.run()` is taught as the ordinary coordinator; maintenance, repair, retry, reconciliation, correction, and retention remain explicitly named administrative operations.
- Every ordinary deployed object exports as a deterministic canonical declaration and reproduces its normalized digest after compatible environmental identities are resolved.
- Every ordinary documentation example executes in CI, including the complete first-rule workflow and task fixtures for lifecycle, scope, decisions, failed work, safe replacement, and export.
- At least four of five independent PostgreSQL developers complete the first-rule task without undocumented help; median time to first effective match is at most fifteen minutes; none uses private catalogs or internal UUIDs.
- Every repeated confusion affecting at least two participants is fixed or recorded as a concrete M33 release blocker.
- The continuous qualification lane remains green for fresh installation, populated upgrade from `0.26.0`, rollback-by-restore and recovery, role isolation, packaged artifacts, and frozen benchmark profiles.
- Every inherited M0–M31 gate passes unchanged against extension `0.28.0`.

---

## Stage 33 — V1 core qualification and compatibility baseline

**Outcome:** freeze the M30 applicability foundation, M31 runtime semantics, and M32 interface as the v1 core compatibility baseline and prove that the exact packaged product is installable, upgradeable, recoverable, secure, observable, performant within published bounds, and ready to support M34 without a second evaluator.

**Release boundary:** M33 freezes and qualifies the v1 core contract. M34 is
the required pre-v1 safety milestone and adds only the bounded comparison
capability defined below; it must preserve M33 runtime semantics and
compatibility. The release-candidate cycle follows M34.

**Entry gate:** extension `0.29.0` is published; every M32 exit gate passes and the public API/UX is frozen. Every M32 gate passes; the continuous qualification lane is green for fresh installation, populated direct upgrade from `0.26.0`, rollback-by-restore and recovery, role isolation, packaged artifacts, and representative benchmark profiles; the installed artifact can generate a complete inventory of functions, overloads, types, views, grants, finding codes, declaration fields, and compatibility aliases. M33 consolidates this existing evidence rather than exercising any matrix for the first time.

### Deliverables

- One normative v1 core baseline in `v1-contract.md` enumerating exact ordinary functions, argument identities, types, views and columns, declaration fields, envelope fields, findings, states, defaults, and semantic commitments.
- Complete compatibility, support-matrix, limits, security, upgrade, backup/restore, operations, troubleshooting, and deprecation contracts plus machine-readable API and finding inventories.
- Adjacent upgrade tests and one populated direct `0.26.0 -> 0.30.0` rehearsal equivalent to the staged path through `0.27.0`, `0.28.0`, and `0.29.0`.
- Restart, physical restore, logical restoration, PITR, reconciliation, and supported standby-promotion fixtures with explicit external-effect boundaries.
- A complete public-surface security review and regression suite covering grants, ownership, fixed search paths, exact function identity, role separation, information leakage, RLS rejection, and declaration safety.
- Reproducible small, moderate, and supported-boundary benchmark profiles measuring runtime, inspection, work, storage, memory, WAL, and recovery behavior.
- Published resource limits and safe failure policies for every bounded subsystem, plus public SQL observability and executable operational runbooks.
- Source and binary artifacts, extension SQL, supported OCI image, checksums, SBOM, provenance, exact dependencies, release notes, upgrade scripts, and installation guidance.
- Documentation execution, packaged-artifact qualification, independent usability, two controlled pilots, release evidence, readiness record, known limitations, and final release checklist.

### Supported boundary

- M33 freezes the core runtime and ordinary API: M34 may add comparison
  surfaces, but may not redefine existing lifecycle, policy scope, work,
  delivery, recovery, or authorization semantics.
- The M33 v1 core contract freezes ordinary SQL calls, views, types, declarations, findings, lifecycle, policy scope, work, delivery guarantees, compatibility matrix, upgrade policy, recovery model, limits, deprecations, security boundary, and documentation.
- Existing valid ordinary calls and declarations remain usable throughout `1.x`; required view columns and stable finding meanings do not disappear or change.
- New nullable columns, optional non-conflicting overloads, detail fields, and finding codes may be added in later compatible releases.
- Minor and patch releases do not silently change semantic match, generation, revision, eligibility, winner selection, work eligibility, leases, revalidation, delivery, support, effective-time, database-time, or event-time behavior.
- The support matrix is deliberately narrow and truthful; unlisted runtime tuples are unsupported or experimental and `doctor` reports detectable unsupported combinations.
- External delivery remains at least once; backup, PITR, failover, and reconciliation documentation must not imply exactly-once external effects.

### Explicit non-goals

- Any new product capability, rule kind, reasoning semantic, temporal operator, decision semantic, policy-set semantic, delivery guarantee, ordinary verb, DSL, SDK, visual authoring, or workflow orchestration.
- Deployment simulation, hypothetical facts, replay, backtesting, or
  why-changed comparison within M33 itself; M34 owns deployment comparison,
  while hypothetical facts are post-v1.
- Broad compatibility claims without exact tested evidence, universal throughput claims, or private-catalog repair as an operational procedure.
- Removing compatibility surfaces solely for API neatness or rewriting immutable historical release evidence.
- Promoting `0.30.0` directly to RC or GA, or starting the release-candidate
  cycle before M34 passes.

### Decisions to close before the M33 contract freezes

- Exact ordinary and advanced compatibility promises, provisional surfaces, compatibility-only aliases, deprecated objects, and earliest removal rules.
- Exact PostgreSQL, pg_trickle, operating-system, architecture, packaging, replication, isolation, preload, worker, RLS, and container support matrix.
- Exact upgrade transformations, reconciliation barriers, preserved durable state, rollback limits, logical-restore rebuilding, and failover support.
- Exact limits, benchmark hardware and data profiles, accepted regression exceptions, retention requirements, and failure behavior beyond supported bounds.
- Exact role and grant matrix, explanation-redaction policy, security-definer inventory, protected-evidence behavior, and unsupported authorization combinations.
- Exact P0/P1/P2 classification, evidence restart rules after contract-affecting fixes, pilot protocol, usability protocol, and release-candidate acceptance authority.
- Exact artifact provenance, checksums, SBOM format, API checksum generation, documentation execution scope, and final promotion procedure.

### Exit gates — v1 core baseline frozen and qualified

- No unapproved semantic or ordinary API expansion remains, and the generated installed-reality inventory exactly matches the frozen v1 core contract.
- Adjacent upgrades and the populated direct `0.26.0 -> 0.30.0` rehearsal preserve all valid state, execute no business work, and establish explicit barriers where reconciliation is required.
- Restart, physical restore, documented logical restoration, PITR boundaries, and every supported failover scenario pass exact recovery evidence.
- The security review and regression suite have no unresolved blocker; `PUBLIC` and every documented role possess only frozen authority.
- Median regressions above ten percent and p95 regressions above twenty percent are investigated; every accepted exception is understood, published, and approved.
- Every bounded subsystem has a published limit and fails safely with an exact actionable finding before unsafe partial mutation where possible.
- Every supported operational failure mode has public diagnosis and recovery SQL; no runbook edits private state.
- Every ordinary documentation example executes against the exact packaged candidate, and intentional failures assert exact stable finding codes.
- Independent usability meets the M32 thresholds; at least two of three tested operators complete a documented replacement, recovery, scoping, or drift task.
- Two controlled pilots complete upgrade, restart, backup/restore, action failure, recovery, doctor, and monitoring; together they exercise policy scoping or decisions.
- No P0 or P1 defect remains; any retained P2 has an explicit known limitation and disposition.
- Every inherited M0–M32 gate passes against extension `0.30.0`; the exact artifact is the qualified input to M34 and is not eligible for RC or GA promotion.

---

## Stage 34 — Deployment-impact simulation

**Outcome:** let users compare one proposed policy version with deployed behavior over the same current authoritative facts and applicability before deployment, with exact bounded relational evidence and no authoritative mutation or external effect.

**Release boundary:** extension `0.31.0`. M34 adds a read-only comparison
capability to the M33 core and is the v1 feature boundary. It does not change
production rule semantics; comparison-specific helpers must satisfy the
qualified semantic-equivalence fixtures. It does not start a v1
release-candidate cycle.

**Entry gate:** extension `0.30.0` is published and every M33 gate passes. Before implementation, freeze one exact fixture covering unchanged, added, removed, and changed results; decisions; applicability; would-be work; evidence truncation; authorization; and a selected-state no-effect checksum whose scope is explicit.

### Deliverables

- A PostgreSQL-native comparison operation accepting one proposed canonical declaration and an explicit deployed target, with stable names and typed identities rather than private UUID knowledge.
- Relational current, proposed, and delta results for affected subjects, matches, decisions, lifecycle transitions, and would-be work, with summary counts and bounded causal evidence.
- Semantic equivalence with qualified production results for evaluation, applicability, authorization, findings, limits, and time, behind a read-only execution boundary; implementation-path sharing is not required.
- Explicit completeness, truncation, sampled-time, source-frontier, declaration-digest, and available cost metadata so users can tell what was compared and whether the answer is exact.
- Public measured evidence for rows considered, affected subjects, would-be work, and elapsed time; fan-out, reevaluation, cascade, memory, and temporary-storage fields remain explicitly unavailable or placeholders until instrumented.
- Extension `0.31.0`, install and upgrade SQL, API inventory, compatibility notes, executable examples, and correctness, security, concurrency, recovery, no-effect, performance, and upgrade evidence.

### Supported boundary

- M34 compares proposed and deployed policy behavior over one explicit current authoritative snapshot; it does not accept hypothetical fact changes or historical input.
- Comparison creates no deployment, lifecycle mutation, durable work, attempt, consequence, external delivery, or authoritative frontier advancement.
- Results use public relational surfaces for filtering, joining, aggregation, and inspection; JSONB remains bounded nested evidence and extensible detail.
- Production semantics are authoritative. Comparison must match qualified production results or fail closed rather than approximate them.
- Existing M33 calls, views, findings, declarations, and semantic commitments remain compatible.

### Explicit non-goals

- Hypothetical facts, historical replay, comparative backtesting, arbitrary tuple lineage, automatic promotion, approval routing, rollback orchestration, or deployment workflow.
- A second evaluator, shadow runtime, copied source database, proprietary DSL, client SDK, visual editor, or hosted comparison service.
- Executing would-be consequences or claiming exact cost equivalence with a deployed run.

### Exit gates

- Unchanged, added, removed, and changed subjects and decisions match the exact result obtained by deploying and running the same proposal in an isolated reference transaction, while the comparison itself leaves the explicitly selected pg-react state checksum unchanged.
- Repeating a comparison over the same declaration, sampled time, source frontier, applicability, authorization, and limits returns identical ordered semantic rows, counts, completeness, and digests; measured runtime fields such as elapsed time may differ.
- Current, proposed, and delta rows reconcile exactly with their summaries; bounded or unavailable evidence is explicit and never presented as complete.
- No comparison creates or alters deployment, match, activation, decision, work, attempt, history, delivery, or external-effect state, including on error, cancellation, restart, and limit failure.
- Authorization and redaction match production access rules and leak no protected declaration, source, subject, result, or evidence data.
- Supported-limit and representative profiles meet published latency, memory, storage, and WAL budgets; qualification uses measured fields and does not treat placeholders or unavailable fields as cost evidence.
- Populated `0.30.0 -> 0.31.0` upgrade and rollback-by-restore preserve all M33 state and semantics; every inherited M0–M33 gate passes unchanged.

---

### Deferred v1 release-candidate cycle

The project has not scheduled a complete feature freeze or a `1.0.0` release.
Each milestone defines its own release version and gate. After the project has
enough user traction, the maintainers may explicitly start a new feature-freeze
and release-candidate cycle. That decision must identify the milestone that
defines the v1 feature boundary and the exact upgrade path into the first
candidate.

Once started, the cycle must publish at least one exact `1.0.0-rc.N` packaged
artifact. Every candidate must pass the applicable installation, upgrade,
recovery, security, role-isolation, comparison no-effect, documentation,
usability, pilot, and performance qualification. Any change to extension code,
SQL, packaging, compatibility behavior, or normative documentation requires a
new numbered candidate and reruns the affected evidence. `1.0.0` may promote
only a fully qualified candidate, with no change except final version metadata
and mechanically corresponding checksums and provenance.

---

## Stage 35 — Hypothetical fact simulation

**Outcome:** let users compare current production behavior with behavior under
one typed, ordered set of hypothetical row changes at an explicit complete
snapshot. M35 returns exact bounded policy, lifecycle, decision, and would-be
work differences without changing source or pg-react state.

**Release boundary:** extension `0.32.0`. M35 adds hypothetical changes to
the `pgreact.compare` and `pgreact.compare_results` model. It adds no top-level
ordinary verb. It preserves the M34 evaluator, authorization, evidence,
semantic-equivalence, authorization, evidence, resource-limit, and no-effect
contracts. `tests/m35.sh complete` is the release gate
for the exact packaged candidate. Completing M35 does not start a v1 feature
freeze or release-candidate cycle.

**Entry gate:** the exact `v0.31.0` artifacts are published and every M34 gate
passes. Before the M35 contract freezes, capture exact baseline and simulated
outputs for typed inserts, updates, and deletes. The fixture also covers
conflicting, duplicate, stale, and unauthorized changes, plus applicability,
derived, temporal, and decision effects. It freezes bounded evidence and the
complete source and authoritative-state checksums.

### Deliverables

- Additive forms of `pgreact.compare` and `pgreact.compare_results` accept one
  typed relational change set. The existing three-argument M34 functions remain
  unchanged.
- One change-set contract over a bounded set of direct source relations. Each
  change names its relation, operation, ordinal, typed key, and typed before and
  after row images where required. Validation rejects missing, extra, or guessed
  identity and type data.
- Simulation against one explicit deployed target, with an optional proposed
  declaration, at one source frontier, applicability snapshot, and sampled
  database and event time.
- Bounded relational results and causal evidence that identify changed facts,
  support, applicability, thresholds, deadlines, derived facts, decision
  candidates, winners, lifecycle transitions, and would-be work.
- Stable findings for missing, duplicate, conflicting, stale, unauthorized,
  unsupported, ambiguous, cyclic, and over-limit inputs. Every rejected input
  has the same exact no-mutation guarantee as a successful simulation.
- Reproducible cost evidence and documented limits for hypothetical rows,
  affected subjects, dependency fan-out, recursion depth, temporal transitions,
  reevaluation, memory, temporary storage, and runtime.
- Extension `0.32.0`, adjacent upgrade SQL from `0.31.0`, a versioned M35
  contract, API reference, API and finding inventories, examples, migration
  notes, known limitations, release notes, and executable qualification
  evidence.

### Supported boundary

- M35 supports the same ordinary `rule`, `decision_program`, and `policy_set`
  targets as M34. Unsupported target or source kinds fail during validation.
- One simulation evaluates one finite change set at one complete current
  snapshot. The snapshot binds the declaration and target, every evaluated
  source relation and its fingerprint, applicability, sampled database and event
  time, source frontier, and pg-react authoritative checksum. It does not
  advance through several frontiers or reconstruct missing history.
- An insert requires an absent typed key. A delete requires one matching current
  row and its exact before image. An update requires one matching current row and
  exact before and after images. Stale or ambiguous identity fails closed.
- Operations run in explicit ordinal order. Duplicate ordinals, conflicting
  operations, and a final state that violates the supported relation contract
  fail before evaluation. A change set may span the bounded direct source set.
  Indirect dependencies are recomputed and cannot also appear as direct changes.
- Inputs are typed PostgreSQL rows and relations. SQL remains the escape hatch.
  M35 adds no predicate language, scenario language, or alternate fact model.
- Applicability, recursion, negation, temporal behavior, decisions, and derived
  facts keep their existing production semantics and published bounds.
- M35 preserves M34 semantics and public guarantees. A read-only hypothetical
  relation adapter may supply row images to production-equivalent evaluation,
  but M35 does not add a second semantic evaluator.
- The same declaration, snapshot, ordered changes, authorization, and limits
  produce the same output. A concurrent authoritative change aborts the
  simulation instead of returning a stale answer.
- Callers need the M34 target authority and `SELECT` on every evaluated source.
  Sources with row-level security fail closed. M35 returns no redacted rows and
  adds no broader disclosure mode.
- No simulation mutates a source, pg-react state, lifecycle, work, attempts,
  history, frontiers, or effects. It executes no consequence or external
  delivery.

### Explicit non-goals

- Historical replay, comparative backtesting, automatic history capture,
  arbitrary optimization, arbitrary tuple lineage, or claims about facts that
  the caller did not supply.
- Durable scenarios, policy promotion, approvals, human workflows, scheduling,
  a custom DSL, client SDKs, visual or AI authoring, or a second evaluator.
- Hypothetical DDL or execution of source DML, triggers, defaults, sequences,
  cascades, volatile functions, consequences, or external calls. The caller
  supplies final typed row images.
- New recursion, negation, temporal, decision-selection, delivery, or
  exactly-once semantics.

### M35 contract decisions

The M35 contract is frozen by [`docs/m35-contract.md`](docs/m35-contract.md)
and [`docs/m35-known-limitations.md`](docs/m35-known-limitations.md). The
release deliberately supports direct table sources with one non-null `bigint`
identity column; unsupported source and identity shapes fail closed.

- Exact function signatures, change-set relation shape, row-image
  representation, source identity, key types and arity, ordinal type, operation
  names, and unknown-field behavior.
- Exact deployed-only and proposed-versus-deployed modes, snapshot identity,
  applicability identity, sampled database and event time, source-frontier
  validation, and stale-snapshot behavior.
- Exact insert, update, and delete preconditions, before-image equality,
  duplicate and conflict rules, key-changing updates, null handling, collation,
  generated columns, and supported constraint behavior.
- The source and target support matrix for rules, decisions, policy sets,
  applicability, derived facts, temporal inputs, parameters, and transitive
  dependencies. Every excluded combination needs one stable finding.
- Exact envelope and relational-result extensions, canonical row and evidence
  order, counts, completeness, truncation, declaration and change-set digests,
  causal links, cost fields, and finding codes.
- Exact ownership, source access, role grants, fixed security-definer search
  paths, protected-value handling, and unauthorized result contracts. M34 RLS
  rejection and no-row behavior remain unchanged.
- Exact serialization with concurrent production maintenance, deployment,
  replacement, removal, reconciliation, and recovery. Define abort, retry,
  cancellation, timeout, and no-mutation behavior for each boundary.
- Exact change-row, affected-subject, fan-out, depth, evidence, latency, write,
  WAL, memory, and temporary-storage limits. Freeze the benchmark profiles,
  upgrade and rollback evidence, and `tests/m35.sh complete` inputs.

### Exit gates

- Every complete supported insert, update, and delete run returns the exact full
  output of applying the same ordered final row images and policy in an isolated
  reference transaction. A limited run returns the exact canonical bounded
  output and explicit incomplete state. Both runs leave the exact source and
  authoritative checksums unchanged.
- Baseline, simulated, delta, lifecycle, and would-be work rows reconcile with
  the envelope when complete. Partial output identifies its exact bound and never
  presents partial counts or evidence as complete.
- Every missing, duplicate, conflicting, stale, unauthorized, unsupported,
  ambiguous, cyclic, and over-limit fixture returns its exact stable finding and
  leaves the complete no-mutation checksum unchanged.
- Bounded causal evidence accounts for every reported delta through changed
  facts, support, applicability, derived facts, temporal boundaries, or decision
  inputs. The result identifies unavailable or truncated evidence.
- Repeated simulations return byte-for-byte identical public output across
  physical input row order, query plans, restart, restore, adjacent upgrade, and
  supported standby promotion for the same frozen inputs and ordinals.
- Cancellation, timeout, crash, restart, recovery, and concurrent production
  activity cannot leak hypothetical state or return an answer from incompatible
  authoritative frontiers.
- Every documented role and `PUBLIC` case returns the exact authorized or denied
  result without leaking protected source, target, subject, row, result, or
  evidence values. RLS sources fail with the exact M35 finding, and every
  security-definer function has the frozen safe search path.
- One versioned reference corpus contains at least three production-shaped
  workloads. It records exact baseline, simulated, and delta outputs, successful
  and rejected changes, declaration and change-set digests, snapshot metadata,
  public-SQL task time, and declared latency, write, WAL, memory, storage, and
  recovery-to-authoritative-state budgets.
- Migration evidence moves applicable reference rules out of application
  branches, scheduled queries, or triggers. User-evaluation records cover both
  successful tasks and tasks blocked by installation, preload, managed-service,
  RLS, or compatibility limits.
- The published compatibility matrix rejects every unsupported combination
  during validation. The release simplification review records which API or
  capability was kept, narrowed, unified, or removed.
- Every complete result exposes the exact declaration digest, change-set digest,
  source frontier, sampled times, applicability identity, cost, and no-mutation
  checksums. Partial results expose the same available metadata and their exact
  completeness bound.
- Representative and supported-limit profiles satisfy the published budgets and
  expose dominant scans, fan-out, cascade depth, reevaluation, temporary storage,
  and generated would-be work.
- Fresh installation, populated `0.31.0 -> 0.32.0` upgrade,
  rollback-by-restore, packaged execution, and inherited M34 qualification pass
  in `tests/m35.sh complete` against the exact candidate artifact.
- Independent PostgreSQL users complete proposal comparison and hypothetical
  change tasks through public SQL without private catalogs, internal UUIDs,
  undocumented help, or a separate usage model.
- Every inherited M0–M34 gate passes. No P0 or P1 remains. Retained limitations
  are explicit, and the exact `0.32.0` artifact passes its release gate.

---

## Stage 36 — Historical replay

**Outcome:** let users replay one frozen policy over a caller-supplied typed
initial snapshot and a finite, deterministically ordered sequence of historical
fact changes. M36 advances explicit database time, event time, and source
frontiers and returns exact bounded matches, decisions, lifecycle transitions,
would-be work, evidence, and costs without changing source or pg-react state.

**Release boundary:** extension `0.33.0`. M36 adds read-only `pgreact.replay`
and `pgreact.replay_results` operations. It composes the M35 typed row-image
simulation model and preserves its authorization, semantic-equivalence,
evidence, resource-limit, and no-effect contracts. `tests/m36.sh complete` is
the release gate for the exact packaged candidate. Completing M36 does not start
a v1 feature freeze or release-candidate cycle.

**Entry gate:** the exact `v0.32.0` artifacts are published and every M35 gate
passes. Before the M36 contract freezes, capture exact replay outputs for a
complete initial snapshot and ordered insert, update, delete, and time-only
steps. The fixture also covers applicability, derived, temporal, decision,
late-input, finality, duplicate, nonmonotone, incomplete, unauthorized, and
over-limit cases. It freezes bounded evidence and the complete source-schema,
source-data, and authoritative-state checksums.

### Deliverables

- `pgreact.replay` and `pgreact.replay_results` accept one frozen deployed
  `rule`, `decision_program`, or `policy_set`, or one canonical declaration,
  with a supplied initial snapshot, replay steps, and options. Existing M34 and
  M35 comparison functions remain unchanged.
- One typed initial-snapshot contract over every supported direct source
  relation. The input names each relation and supplies every starting row.
  Replay binds each resolved relation-schema fingerprint. Empty relations are
  explicit rather than inferred from missing input.
- One replay-step contract. Each step names a unique ordinal, source frontier,
  sampled database time, event-time watermark, and an ordered M35 change set.
  Time-only steps advance temporal evaluation without inventing a fact change.
- Read-only evaluation of the initial snapshot and each replay step through the
  existing applicability, derivation, temporal, decision, lifecycle, and work
  semantics. Each change validates against the preceding replay state.
- Bounded relational initial, step, and final results with causal evidence for
  facts, support, applicability, thresholds, deadlines, derived facts, decision
  candidates, winners, lifecycle transitions, and would-be work.
- Stable findings for missing, duplicate, conflicting, nonmonotone, stale,
  unauthorized, unsupported, ambiguous, cyclic, invalid late or finalized,
  incomplete, and over-limit input. Every rejected replay has the same exact
  no-mutation guarantee as a successful replay.
- Reproducible cost evidence and documented limits for snapshot rows, replay
  steps, changed rows, affected subjects, dependency fan-out, recursion depth,
  temporal transitions, reevaluation, memory, temporary storage, and runtime.
- Extension `0.33.0`, adjacent upgrade SQL from `0.32.0`, a versioned M36
  contract, API reference, API and finding inventories, examples, migration
  notes, known limitations, release notes, and executable qualification
  evidence.

### Supported boundary

- M36 supports the same targets, direct source relations, row-image rules, and
  single non-null `bigint` identities as M35. Unsupported target, source,
  schema, or identity shapes fail during validation.
- One replay evaluates one frozen declaration over one complete initial
  snapshot and one finite sequence of steps. The snapshot binds the declaration
  and target, every evaluated relation and schema fingerprint, applicability,
  starting database time, event-time watermark, source frontier, and pg-react
  authoritative checksum.
- The caller supplies the complete initial snapshot and every later change. A
  replay does not read, acquire, retain, infer, or reconstruct missing source
  history. Current source rows are not substituted for missing historical rows.
- Initial rows and changes are typed PostgreSQL rows. Each change keeps the M35
  insert, update, delete, identity, before-image, conflict, and ordinal rules.
  SQL remains the escape hatch. M36 adds no event language or alternate fact
  model.
- Steps run in explicit ordinal order. Every step records its source frontier,
  sampled database time, and event-time watermark, and no value advances
  implicitly. Existing idempotency, late-input, and finality semantics remain
  authoritative. Replay reports the read-only outcome and never creates a
  maintenance barrier.
- The initial snapshot and replay steps use one frozen source schema. Historical
  DDL, type changes, generated expressions, triggers, defaults, sequences,
  cascades, and volatile functions are not replayed. The caller supplies final
  typed row images.
- Applicability, recursion, negation, temporal behavior, decisions, derived
  facts, lifecycle, and work keep their production semantics and published
  bounds. Replay-local lifecycle and work rows describe what would have happened
  and never become production identities or durable state.
- The same declaration, snapshot, steps, authorization, and limits produce the
  same semantic output. A concurrent change to the target declaration or an
  evaluated source schema aborts the replay instead of mixing revisions.
- Callers need the M35 target authority and `SELECT` on every represented source
  relation. Sources with row-level security fail closed. M36 returns no redacted
  rows and adds no broader disclosure mode. M36 reads current catalogs only to
  validate relation schemas and authorization; it never substitutes current
  relation data for supplied history.
- No replay mutates a source, pg-react state, lifecycle, work, attempts, history,
  frontiers, or effects. It deploys no policy, executes no consequence, and
  performs no external delivery.

### Explicit non-goals

- Comparative backtesting across policy versions, why-changed comparison,
  automatic policy selection, or claims about history that the caller did not
  supply. M37 owns two-version backtesting, and M38 owns why-changed comparison.
- Change-data capture, logical decoding, audit logging, history retention,
  history reconstruction, point-in-time recovery, a scenario store, or a second
  source of truth.
- Historical DDL or execution of source DML, triggers, defaults, sequences,
  cascades, volatile functions, consequences, or external calls.
- Durable replay jobs, scheduling, policy promotion, approvals, human workflows,
  rollback orchestration, a custom DSL, client SDKs, visual or AI authoring, or
  a second evaluator.
- New applicability, recursion, negation, temporal, decision-selection,
  lifecycle, delivery, or exactly-once semantics.

### Decisions to close before the M36 contract freezes

- Exact function signatures, target selection, initial-snapshot and replay-step
  shapes, relation and schema identity, row representation, key types and arity,
  ordinal types, and unknown-field behavior.
- Exact snapshot completeness proof, empty-relation representation, initial
  applicability state, declaration and source-schema pinning, canonical row
  order, and snapshot digest.
- Exact step ordering, batching, frontier identity and progression, database and
  event-time progression, time-only steps, equal times, late input, finality,
  gaps, duplicates, and backward-value behavior.
- Exact bootstrap and transition behavior for applicability, derived facts,
  recursion, negation, temporal corrections and finalizations, decisions,
  lifecycle identities, refraction, coalescing, and would-be work.
- Exact envelope and relational-result shapes, initial, step, and final rows,
  canonical order, counts, completeness, truncation, declaration, snapshot, and
  replay digests, causal links, cost fields, and finding codes.
- Exact ownership, source access, role grants, fixed security-definer search
  paths, protected-value handling, and unauthorized result contracts. M35 RLS
  rejection and no-row behavior remain unchanged.
- Exact serialization with concurrent deployment, replacement, removal, source
  DDL, recovery, and extension upgrade. Define abort, retry, cancellation,
  timeout, restart, and no-mutation behavior for each boundary.
- Exact snapshot-row, replay-step, change-row, affected-subject, fan-out, depth,
  evidence, latency, write, WAL, memory, and temporary-storage limits. Freeze the
  benchmark profiles, upgrade and rollback evidence, and `tests/m36.sh complete`
  inputs.

### Exit gates

- Every complete supported replay returns the exact initial, step, and final
  output of applying the same snapshot, ordered changes, times, frontiers, and
  frozen policy in an isolated reference database. A limited replay returns the
  exact canonical bounded output and explicit incomplete state. Both leave the
  exact source and authoritative checksums unchanged.
- Match, decision, lifecycle, temporal, and would-be work rows reconcile with
  each complete step and the final envelope. Partial output identifies its exact
  bound and never presents partial counts or evidence as complete.
- Every missing, duplicate, conflicting, nonmonotone, stale, unauthorized,
  unsupported, ambiguous, cyclic, invalid late or finalized, incomplete, and
  over-limit fixture returns its exact stable finding and leaves the complete
  no-mutation checksum unchanged.
- Bounded causal evidence accounts for every reported transition through input
  facts, support, applicability, derived facts, temporal boundaries, or decision
  inputs. The result identifies unavailable or truncated evidence.
- Repeated replays return byte-for-byte identical semantic output across
  physical snapshot row order, query plans, restart, restore, adjacent upgrade,
  and supported standby promotion for the same frozen inputs and ordinals.
  Measured elapsed time may differ.
- Cancellation, timeout, crash, restart, recovery, and concurrent production
  activity cannot leak replay state or return an answer that mixes declaration,
  schema, time, or frontier revisions.
- Every documented role and `PUBLIC` case returns the exact authorized or denied
  result without leaking protected source, target, subject, row, result, or
  evidence values. RLS sources fail with the exact M36 finding, and every
  security-definer function has the frozen safe search path.
- One versioned reference corpus contains at least three production-shaped
  workloads. It records exact snapshots, replay steps, results, rejected inputs,
  declaration, snapshot, and replay digests, time and frontier metadata,
  public-SQL task time, and declared latency, write, WAL, memory, storage, and
  recovery-to-authoritative-state budgets.
- Migration evidence moves one production-shaped replay task from an
  application-owned script or copied test database to M36 public SQL.
  User-evaluation records cover both successful tasks and tasks blocked by
  installation, preload, managed-service, RLS, compatibility, or missing-history
  limits.
- The published compatibility matrix rejects every unsupported combination
  during validation. The release simplification review records which API or
  capability was kept, narrowed, unified, or removed.
- Every complete result exposes the exact declaration, snapshot, and replay
  digests, starting and ending frontiers, sampled times, applicability identity,
  cost, and no-mutation checksums. Partial results expose the same available
  metadata and their exact completeness bound.
- Representative and supported-limit profiles satisfy the published budgets and
  expose dominant scans, fan-out, cascade depth, reevaluation, temporary storage,
  and generated would-be work per replay step and for the complete run.
- Fresh installation, populated `0.32.0 -> 0.33.0` upgrade,
  rollback-by-restore, packaged execution, and inherited M35 qualification pass
  in `tests/m36.sh complete` against the exact candidate artifact.
- Independent PostgreSQL users complete historical replay tasks through public
  SQL without private catalogs, internal UUIDs, undocumented help, copied source
  databases, or a separate usage model.
- Every inherited M0–M35 gate passes. No P0 or P1 remains. Retained limitations
  are explicit, and the exact `0.33.0` artifact passes its release gate.

---

## Stage 37 — Comparative backtesting

**Outcome:** let users run two frozen policy versions over one caller-supplied
typed history and see their differences at every replay point. M37 returns
exact bounded differences in matches, decisions, lifecycle transitions,
would-be work, deterministic resource counters, and changed-subject evidence.
It also reports measured costs and leaves source and pg-react state unchanged.

**Release boundary:** extension `0.34.0`. M37 adds read-only
`pgreact.backtest` and `pgreact.backtest_results` operations. It composes the
M34 comparison, M35 typed row-image simulation, and M36 replay models and
preserves their authorization, semantic-equivalence, evidence, resource-limit,
and no-effect contracts. `tests/m37.sh complete` is the release gate for the
exact packaged candidate. Completing M37 does not start a v1 feature freeze or
release-candidate cycle.

**Entry gate:** the exact `v0.33.0` artifacts are published and every M36 gate
passes. Before the M37 contract freezes, capture exact outputs for two policy
versions that produce equal and different matches, decisions, lifecycle
transitions, and would-be work over one shared replay. The fixture also covers
incompatible declarations, partial evidence, unauthorized input, concurrent
baseline-declaration and source-schema changes, and every inherited M36
rejection. It freezes both declaration digests, the shared snapshot and replay
digests, and the complete source and authoritative-state checksums.

### Deliverables

- `pgreact.backtest` and `pgreact.backtest_results` accept one deployed baseline
  target, one optional canonical candidate declaration, one M36 initial
  snapshot, replay steps, and options. M37 freezes the deployed declaration at
  call start. A null candidate compares that declaration with itself. Existing
  M34, M35, and M36 functions remain unchanged.
- One shared-history contract. M37 validates the initial snapshot, ordered row
  changes, database times, event-time watermarks, source frontiers, finality,
  and limits once and applies those exact inputs to both policy versions.
- Read-only evaluation of both versions through the existing applicability,
  derivation, temporal, decision, lifecycle, and work semantics. M37 compares
  two production-equivalent M36 results rather than adding another evaluator.
- Bounded relational initial, step, and final results for each version, plus
  canonical version-to-version differences in matches, decisions, lifecycle
  transitions, would-be work, costs, and affected subjects.
- Bounded changed-subject evidence that identifies the replay point and the
  result rows that differ. M37 reports the evidence already available from each
  replay side; it does not claim a complete why-changed explanation.
- Stable findings for missing, duplicate, mismatched, incompatible, stale,
  unauthorized, unsupported, ambiguous, cyclic, nonmonotone, incomplete, and
  over-limit input. Every rejected backtest has the same no-mutation guarantee
  as a successful backtest.
- Reproducible semantic cost counters, separately labeled elapsed-time
  measurements, and documented limits for snapshot rows, replay steps, changed
  rows, affected subjects, result alignment, dependency fan-out, recursion
  depth, temporal transitions, reevaluation, memory, temporary storage, and
  runtime for each side and the comparison.
- Extension `0.34.0`, adjacent upgrade SQL from `0.33.0`, a versioned M37
  contract, API reference, API and finding inventories, examples, migration
  notes, known limitations, release notes, and executable qualification
  evidence.

### Supported boundary

- M37 supports the same target kinds, direct source relations, row-image rules,
  and single non-null `bigint` identities as M36. Unsupported target, source,
  schema, identity, or policy-pair shapes fail during validation.
- One backtest compares the declaration frozen from one deployed baseline target
  with one canonical candidate declaration over one complete initial snapshot
  and one finite replay sequence. The candidate must have the same target kind
  and name, represented source relation, source-schema fingerprint, identity,
  and subject shape as the baseline.
- The caller supplies the complete initial snapshot and every later change. A
  backtest does not read, acquire, retain, infer, or reconstruct missing source
  history. Current source rows are not substituted for missing historical rows.
- Both versions receive the same typed starting rows, ordered changes, database
  times, event-time watermarks, source frontiers, final marker, and limits. A
  caller cannot advance one side differently from the other.
- Initial rows and changes keep the M36 snapshot and replay-step contracts and
  the M35 insert, update, delete, identity, before-image, conflict, and ordinal
  rules. M37 adds no event language or alternate fact model.
- Each version keeps production applicability, recursion, negation, temporal,
  decision, derived-fact, lifecycle, and work semantics within their published
  bounds. Backtest-local lifecycle and work rows never become production
  identities or durable state.
- M37 aligns results by canonical replay point and the target-specific public
  identities frozen in the M37 contract. Results report unchanged, added,
  removed, and changed values without treating physical row order or private
  identifiers as policy meaning.
- The same policy pair, snapshot, replay, caller security context, and limits
  produce the same semantic output. A concurrent change to the deployed
  baseline declaration or an evaluated source schema aborts the backtest instead
  of mixing revisions.
- One caller security context must authorize the complete policy pair and every
  represented source relation before M37 returns either side. Sources with
  row-level security fail closed. M37 returns no redacted rows and adds no
  broader disclosure mode.
- No backtest mutates a source, pg-react state, lifecycle, work, attempts,
  history, frontiers, or effects. It deploys no policy, executes no consequence,
  and performs no external delivery.

### Explicit non-goals

- Complete causal explanation of why the versions differ. M38 owns bounded
  why-changed comparison across versions, frontiers, and revisions.
- Policy scoring, ranking, optimization, recommendation, forecasting, automatic
  selection, promotion, approval, deployment, rollback, or claims that past
  results predict future behavior.
- Change-data capture, logical decoding, audit logging, history retention,
  history reconstruction, point-in-time recovery, a scenario store, or a second
  source of truth.
- Two independently deployed targets, arbitrary stored historical policy
  revisions, more than two versions, a matrix of histories, durable backtest
  jobs, scheduling, client SDKs, visual or AI authoring, or a second evaluator.
- Historical DDL or execution of source DML, triggers, defaults, sequences,
  cascades, volatile functions, consequences, or external calls.
- New applicability, recursion, negation, temporal, decision-selection,
  lifecycle, delivery, or exactly-once semantics.

### Decisions to close before the M37 contract freezes

- Exact function signatures, deployed-baseline freezing, null-candidate
  behavior, canonical candidate representation, version identity, target
  matching, argument order, defaults, and unknown-field behavior.
- Exact policy-pair compatibility rules for target kind and name, direct source
  relations, schema fingerprints, identity columns, applicability, parameters,
  decision outputs, policy-set membership, and transitive dependencies.
- Exact reuse of M36 snapshot and replay validation, including empty relations,
  row representation, step ordering, time-only steps, finality, frontiers,
  database and event time, late input, and incomplete history.
- Exact result alignment for rule semantic keys and bindings, lifecycle
  revisions and episodes, decision subjects and winners, policy-set members,
  would-be work identities, costs, and affected subjects. Define added, removed,
  changed, and unchanged rows for every supported target kind.
- Exact envelope and relational-result shapes, canonical order, counts,
  completeness, truncation, side labels, replay points, evidence links, cost
  fields, and finding codes.
- Exact baseline, candidate, snapshot, replay, and backtest digests. Define
  null and identical-candidate results, semantic equivalence, canonical
  serialization, and result identity without private UUIDs.
- Exact ownership, policy and source access, role grants, fixed
  security-definer search paths, protected-value handling, and unauthorized
  result contracts. M36 RLS rejection and no-row behavior remain unchanged.
- Exact serialization with concurrent deployment, replacement, removal, source
  DDL, recovery, and extension upgrade. Define abort, retry, cancellation,
  timeout, restart, and no-mutation behavior for each boundary.
- Exact snapshot-row, replay-step, change-row, affected-subject, aligned-result,
  fan-out, depth, evidence, latency, write, WAL, memory, and temporary-storage
  limits. Freeze the benchmark profiles, upgrade and rollback evidence, and
  `tests/m37.sh complete` inputs.

### Exit gates

- Every complete supported backtest matches two independent M36 replays over
  the same snapshot, ordered changes, times, frontiers, and limits. Its reported
  differences reconcile exactly with those two results. A limited backtest
  returns exact canonical bounded output and explicit incomplete state. Both
  leave source and authoritative checksums unchanged.
- An identical policy pair returns equal per-side semantic results and an exact
  empty difference. The frozen contract labels baseline and candidate direction
  consistently in every envelope, relational row, digest, and finding.
- Match, decision, lifecycle, temporal, would-be work, cost, and subject rows
  reconcile at every complete replay point and in the final envelope. Partial
  output identifies its exact bound and never presents partial counts or
  evidence as complete.
- Every missing, duplicate, mismatched, incompatible, stale, unauthorized,
  unsupported, ambiguous, cyclic, nonmonotone, invalid late or finalized,
  incomplete, and over-limit fixture returns its exact stable finding and
  leaves the complete no-mutation checksum unchanged.
- Bounded changed-subject evidence links every reported difference to both
  version result rows and their replay point. The result identifies unavailable
  or truncated evidence. It does not explain the causal reason for a difference
  or make an M38 why-changed claim.
- Repeated backtests return byte-for-byte identical semantic output across
  physical snapshot row order, query plans, restart, restore, adjacent upgrade,
  and supported standby promotion for the same frozen inputs. Measured elapsed
  time may differ.
- Cancellation, timeout, crash, restart, recovery, and concurrent production
  activity cannot leak backtest state or return an answer that mixes policy,
  schema, time, or frontier revisions.
- Every documented role and `PUBLIC` case returns the exact authorized or denied
  result without leaking protected policy, source, target, subject, row, result,
  or evidence values. RLS sources fail with the exact M37 finding, and every
  security-definer function has the frozen safe search path.
- One versioned reference corpus contains at least three production-shaped
  workloads. It records both policy versions, exact snapshots, replay steps,
  per-side results, differences, rejected inputs, digests, time and frontier
  metadata, public-SQL task time, and declared latency, write, WAL, memory,
  storage, and recovery-to-authoritative-state budgets.
- Migration evidence moves one production-shaped comparative backtest from an
  application-owned script or paired test databases to M37 public SQL.
  User-evaluation records cover both successful tasks and tasks blocked by
  installation, preload, managed-service, RLS, compatibility, or missing-history
  limits.
- The published compatibility matrix rejects every unsupported policy pair and
  input combination during validation. The release simplification review
  records which API or capability was kept, narrowed, unified, or removed.
- Every complete result exposes the exact baseline, candidate, snapshot, replay,
  and backtest digests, starting and ending frontiers, sampled times,
  applicability identities, deterministic per-side and comparison cost counters,
  separately labeled elapsed-time measurements, completeness, and no-mutation
  checksums. Partial results expose the same available metadata and their exact
  bound.
- Representative and supported-limit profiles satisfy the published budgets and
  expose dominant scans, fan-out, cascade depth, reevaluation, alignment work,
  temporary storage, and generated would-be work for each replay point and the
  complete backtest.
- Fresh installation, populated `0.33.0 -> 0.34.0` upgrade,
  rollback-by-restore, packaged execution, and inherited M36 qualification pass
  in `tests/m37.sh complete` against the exact candidate artifact.
- Independent PostgreSQL users complete comparative backtesting through public
  SQL without private catalogs, internal UUIDs, undocumented help, copied source
  databases, paired database runs, or a separate usage model.
- Every inherited M0–M36 gate passes. No P0 or P1 remains. Retained limitations
  are explicit, and the exact `0.34.0` artifact passes its release gate.

---

## Proposed sequence after M37

The project considers and implements one milestone at a time. M38 is a planning
option, not an implementation or release commitment. Selection depends on
evidence from M37 and user traction. Any selected milestone must compose the
production semantics and the M34–M37 comparison, simulation, replay, and
backtesting models rather than create another evaluator.

1. **M38 — Why-changed comparison.** Explain bounded causal differences between versions, frontiers, or revisions by composing existing provenance and comparison evidence, identifying changed support, facts, applicability, thresholds, deadlines, or winning candidates.

Policy promotion, approval routing, rollback orchestration, custom DSLs, visual or AI authoring, client SDKs, nested policy sets, weighted optimization, synchronous network actions, human workflows, exactly-once external delivery, arbitrary SQL lineage, untrusted dynamic code, unstratified negation, recursive aggregation, and distributed cross-database evaluation remain excluded unless separately proposed and proven.

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

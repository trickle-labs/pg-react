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

**Entry gate:** the exact `v0.3.0` release artifacts, checksums, disclosures, and direct-upgrade path are published and verified. The [fixed reference model](docs/m7-entry.md) requires two independent derivations of one fact, removal of one and then the last support, downstream rule observation, reconciliation, and physical recovery; its expected public state and explanation output are frozen before the API contract is fixed.

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

## Post-GA product directions

The directions below are intentional but are not implementation commitments and do not impose a fixed order. A direction becomes the next numbered milestone only when it has a demonstrated user or operational need, bounded prerequisites, explicit non-goals, a support matrix, and executable exit evidence. GitHub milestones represent only active or credible near-term implementation commitments.

A future direction may constrain a semantic decision, but it does not authorize speculative catalogs, APIs, or abstractions. PostgreSQL views, typed functions, explicit registration, immutable versions, and durable PostgreSQL state remain the canonical model.

### Product ergonomics

- Named reusable conditions where ordinary shared PostgreSQL views are insufficient.
- Schedule coordination, cost diagnostics, and targeted migration tooling driven by observed deployment friction.
- Compatibility, RLS, key-codec, recovery, and platform expansion one supported combination at a time.

### Execution and scale

M6 promotes audited batch execution. The remaining directions stay independent and unnumbered:

- Selective `IMMEDIATE` mode only for demonstrated read-your-writes needs and combinations covered by a tested isolation and locking contract.
- Explicit shared conditions before automatic common-subplan discovery; automatic sharing only when repeated work and compatible security contexts are measured.
- Retention redesign, catalog partitioning, and other storage changes only after current limits are reproduced by benchmarks.

These capabilities are independent; none is a prerequisite for derived knowledge unless its promoted milestone demonstrates that dependency.

### Derived knowledge

M7 promotes the smallest useful semantic slice: non-recursive derived facts with multiple logical supports, retraction, provenance, reconciliation, recovery, retention, and “why is this true?” explanation. M8 promotes positive derivation chains and cycles with grounded least-fixed-point maintenance and finite recursive explanation. M9 promotes safe stratified negation with deletion-sensitive truth maintenance across ordered strata. M10 promotes keyed `COUNT(*)` threshold dependencies over stable lower strata.

Unstratified negation, aggregate cycles, and richer aggregate functions remain separate later work and accept only programs with precise, testable semantics.

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
| **M6 — Execution maturity** | Raise consequence throughput through audited batching without weakening per-episode guarantees |
| **M7 — Maintained derived knowledge** | Maintain non-recursive supported facts with retraction, provenance, explanation, and recovery |
| **M8 — Monotone recursive derivation** | Maintain positive derivation chains and cycles to one grounded least fixed point |
| **M9 — Stratified negation** | Maintain safe negative dependencies to one ordered, deletion-sensitive result |
| **M10 — Stratified aggregation** | Maintain keyed counts over stable lower strata with exact threshold transitions |

Each implementation issue should belong to one milestone and one primary workstream label, for example `area/semantics`, `area/compiler`, `area/catalog`, `area/worker`, `area/security`, `area/operations`, `area/performance`, or `area/docs`.

Do not create GitHub milestones for the unnumbered post-GA directions. Promote only the next direction whose entry conditions and executable exit evidence are credible.

---

## Active and next milestones

**M8 — Monotone recursive derivation** is released as `0.5.0`. Immutable release evidence is recorded in `docs/m9-entry.md`.

**M9 — Stratified negation** is implemented as the `0.6.0` repository candidate. The next work is release qualification and publication of the exact archive and `linux/amd64` image, followed by checksum, digest, and direct-upgrade verification against those published bytes.

**M10 — Stratified aggregation** is the next defined milestone after M9. Its reference program and semantic fixtures may be designed before `v0.6.0` publication, but no M10 product change merges until that exact release satisfies the entry gate. Do not pull aggregate cycles, richer aggregate functions, unstratified negation, temporal semantics, new execution modes, or support-matrix expansion into M10.

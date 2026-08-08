# pg-react roadmap

> **Status:** Living delivery plan  
> **Last updated:** 2026-08-08  
> **Design authority:** [`DESIGN.md`](DESIGN.md) defines product semantics. This file defines delivery order, release scope, and evidence required to ship.

`pg-react` should become the easiest safe way to turn changing PostgreSQL data into durable, inspectable decisions and work. The roadmap is therefore organized around two outcomes:

1. **Easy to use:** rules are authored with ordinary PostgreSQL views and typed functions, safe defaults handle the common case, errors explain how to recover, and normal operation never requires direct access to private catalogs.
2. **Solid:** lifecycle events are deterministic, work is durable, concurrency and retries are explicit, external effects are honest about their guarantees, and upgrades, crashes, restores, and rebuilds do not silently lose or duplicate business work.

The stages below are **evidence gates, not calendar promises**. Parallel work is encouraged, but a later release must not ship before the earlier correctness gates are satisfied. Calendar commitments should be made only after the feasibility stage establishes the required `pg_trickle` integration contract.

---

## Product success criteria

A successful v1 lets a PostgreSQL developer:

1. Define a condition with a normal view.
2. Define an optional consequence with a typed PostgreSQL function or transactional outbox message.
3. Register the rule with one `pgreact.create_rule` call.
4. Inspect current matches, lifecycle state, pending work, attempts, drift, and health through documented SQL views and functions.
5. Pause, replace, reconcile, retry, and recover a rule without editing internal tables.

A successful v1 lets an operator trust that:

- within one immutable rule version, one semantic key that remains continuously present creates exactly one activation generation;
- physical refresh mechanics do not create false lifecycle events;
- match state, activation state, payloads, and agenda work commit atomically;
- two workers cannot own the same lease;
- stale or invalidated work cannot execute successfully;
- database-local consequences and outbox insertion are transactional;
- external delivery is at least once and uses deterministic idempotency keys;
- reconciliation is explicit and idempotent;
- source and function drift are visible and block unsafe execution;
- recovery and upgrade procedures are tested rather than inferred.

---

## Initial v1 contract

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
| Transactional outbox for external effects | Claims of global exactly-once external delivery |
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

The first implementation must be a narrow end-to-end path, not a collection of disconnected subsystems:

```text
source transaction
  -> pg_trickle refresh
  -> final semantic match delta
  -> activation transition
  -> durable agenda episode
  -> one typed PostgreSQL consequence
  -> inspectable completion history
```

### Deliverables

- Buildable Rust workspace with a `pgrx` extension skeleton and a minimal `pg-reactd` process.
- Reproducible PostgreSQL 18 development and CI environment with pinned dependency versions.
- A documented, versioned `pg_trickle` integration boundary owned by one adapter module.
- A synchronous critical refresh-observer or consolidated-delta mechanism that sees the final semantic result of a refresh transaction.
- A pure lifecycle transition planner for semantic identity, activation generations, and coalescing of physical delete-plus-insert maintenance.
- A minimal catalog containing immutable rule identity, current activation state, one agenda state path, and execution history.
- One reference rule using `ACTIVATE` and a typed database-local consequence.
- Property and integration test harnesses established before feature expansion.

### Exit gates

- Rollback produces no committed activation or work.
- Restart preserves committed lifecycle and agenda state.
- Concurrent transactions changing opposite sides of a join do not silently miss or duplicate the semantic transition.
- A physical delete-plus-insert that leaves the same semantic key present does not create a false deactivation and reactivation.
- A full rebuild followed by reconciliation reaches the same current activation state as equivalent differential maintenance.
- The typed consequence and episode completion commit atomically.

### Decision gate

If `pg_trickle` cannot provide a sound observation boundary, the project must explicitly choose one of the following before continuing:

1. implement the required public observer API upstream;
2. restrict pg-react to a smaller, proven maintenance subset;
3. redesign the integration boundary; or
4. pause the command-rule implementation.

A trigger-only approximation must not silently become the production contract.

---

## Stage 1 — Developer alpha: a small useful rule engine

**Outcome:** deliver the smallest release that users can understand, install, and use for real PostgreSQL-local rules.

### User-visible scope

- `CREATE EXTENSION pg_react` with a documented compatible `pg_trickle` installation.
- View-backed constraint rules.
- Activate-only command rules through typed PostgreSQL functions.
- `pgreact.create_rule`, pause, resume, drained replacement, and inspect operations. Alpha replacement requires a paused rule with no pending, retrying, or leased work; live cutover arrives in beta.
- Explicit semantic keys with non-null and uniqueness validation.
- Immutable versions, source snapshots, row signatures, and source drift reporting.
- Generated current-match views and stable public inspection views.
- Deterministic activation IDs and one activation generation per continuous truth interval.
- Bootstrap and reconciliation with an explicit, documented policy.
- `pgreact.validate_rule` and `pgreact.preview_rule` before durable deployment.
- `pgreact.explain_rule`, `pgreact.explain_activation`, `pgreact.explain_episode`, and `pgreact.health_check` with practical remediation hints.
- A minimal worker that executes one episode per transaction and performs a fresh pre-execution check.
- Scale smoke workloads for one rule with many matches, many rules with few matches, no-change refreshes, activation bursts, repeated replacement, and payload growth.

### Usability requirements

- The canonical example remains a three-step workflow: create a view, create a typed function, register the rule.
- The common command path requires only name, definition, semantic key, and activation consequence; advanced lifecycle and scheduling policy remains optional.
- Common configuration has safe defaults; policies that can create surprising work require an explicit choice.
- Preflight reports maintenance support, key and watched-column problems, consequence compatibility, expected refresh mode, dependencies, generated objects, and bootstrap or external-effect warnings.
- Validation errors name the rule, object, invalid property, and corrective action.
- Users do not need to query or update `pgreact_internal`.
- The README example is executable in CI as documentation-as-test.

### Exit gates

- A new user can complete the reference example using only public documentation and public SQL APIs.
- Registration rejects non-view definitions, null or duplicate semantic keys, incomparable watched columns, incompatible typed signatures, unsafe roles, and unsupported query capabilities before activation.
- Replacing or dropping a source view or consequence function produces visible drift or invalidation rather than ambiguous dispatch.
- Property tests cover long insert, update, delete, delete-plus-insert, rebuild, and reconciliation histories.
- Scale smoke tests publish baselines and reveal architectural cliffs before storage and catalog layouts harden; final release budgets are not required yet.
- Constraint and activate-only command rules can be installed, explained, paused, resumed, replaced after draining, and removed cleanly.

---

## Stage 2 — Reliability beta: complete lifecycle and durable execution

**Outcome:** make command rules dependable under concurrency, retries, crashes, and changing source data.

### Deliverables

- Complete `ACTIVATE`, `CHANGE`, and `DEACTIVATE` lifecycle support.
- Activation generations and change revisions with deterministic event identities.
- Normative watched-column comparison using PostgreSQL equality semantics, with explicit schema-change behavior.
- Typed old/new event payloads and stable `pgreact.activation_context`.
- Durable agenda states, claims, leases, heartbeats, expiry, retry backoff, cancellation, withdrawal, skip, completion, and terminal failure.
- Salience, agenda groups, conflict keys, and deterministic claim ordering within the documented scope.
- Independent pre-execution eligibility, source-fingerprint, function-fingerprint, lease, and conflict checks.
- Blue/green replacement implementing the design's cutover matrix for active, pending, retrying, and leased work.
- Generic transactional outbox with deterministic idempotency keys, a stable event envelope, replay behavior, and a normative consumer contract.
- Execution-attempt and reconciliation-audit history plus operator APIs for retry, cancel, reconcile, and lease repair.
- Stateless, horizontally scalable `pg-reactd` with polling as the authority and `LISTEN/NOTIFY` only as a wake-up hint.
- Feedback-loop limits and diagnostics for rules whose consequences change their own source facts.

### Exit gates

- Two workers cannot successfully own or complete the same lease.
- A stale worker cannot complete work after lease reclamation.
- A worker may claim episodes A and B, execute A, have A invalidate B, and then skip or withdraw B during B's fresh recheck.
- Database consequence execution and episode completion are atomic.
- Outbox insertion and episode completion are atomic; duplicate delivery, replay, and out-of-order retry tests exercise the consumer contract.
- Crash injection covers refresh rollback, server restart, worker death around consequence commit, ambiguous disconnects, lease expiry races, and outbox delivery ambiguity.
- Replacement races prove that old work dispatches only through its exact old binding or is rejected according to the declared cutover policy.
- No committed work is silently lost in the supported failure scenarios.
- Reconciliation is idempotent, respects its configured event-emission policy, and records an audit result even for state-only repair.
- All documented isolation-level combinations have tests; unsafe combinations fail explicitly.

---

## Stage 3 — Operational release candidate

**Outcome:** make pg-react supportable in a controlled production environment.

### Deliverables

- Published compatibility matrix for PostgreSQL, `pgrx`, `pg_trickle`, operating systems, architectures, maintenance modes, and isolation levels.
- Stable extension migrations and rebuild procedures for transient OID-based metadata.
- Tested PITR, physical failover, logical migration, PostgreSQL-major upgrade, and rolling worker-upgrade procedures.
- Source and function drift repair workflows with explicit claim barriers.
- Documented PostgreSQL roles for administration, authoring, operation, workers, and readers.
- Security review of ownership checks, `SET LOCAL ROLE`, exact function dispatch, `SECURITY DEFINER` functions, search paths, generated relations, and payload access.
- An explicit RLS and evaluation-role support decision; unsupported combinations are documented and rejected where necessary.
- Retention, cleanup, vacuum, and catalog-growth controls, including audited pruning and minimum history that survives payload cleanup.
- Fairness windows, starvation prevention, claim-size bounds, agenda-group and connection budgets, overload backpressure, lock ordering, and bounded deadlock retry behavior.
- Metrics, structured logs, health endpoints, and alerts for drift, invalid bindings, reconciliation, agenda depth and oldest age, hot conflict keys, claim saturation, per-rule backlog, latency, failures, lease expiry, and outbox state.
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

---

## Stage 4 — v1 general availability

**Outcome:** freeze and support the first dependable public contract.

### GA requirements

- The v1 SQL API, worker protocol, catalog migration policy, compatibility policy, and external-delivery guarantees are documented and versioned.
- Installation, authoring, operations, security, backup/restore, upgrades, and troubleshooting each have task-oriented documentation.
- The end-to-end reference example is tested against every release artifact.
- No unresolved issue can cause silent missed lifecycle events, silent duplicate lifecycle events, lost committed work, unsafe function dispatch, or unrecoverable catalog state within the supported matrix.
- Release artifacts, checksums, upgrade notes, and known limitations are published together.
- A pilot user or internal production deployment has completed installation, normal operation, failure injection, restore, and upgrade exercises.

The first GA should prefer a small, explicit support matrix over broad best-effort compatibility.

---

## Stage 5 — Post-GA expansion

Post-GA work is divided into two tracks. Neither may weaken the v1 lifecycle and recovery guarantees.

### v1.x: usability and scale

- Named reusable conditions.
- Rule packs and atomic batch deployment.
- Schedule coordination and cost diagnostics.
- Better rule-development previews and migration tooling.
- Explicitly audited `batch_safe` execution for proven commutative workloads.
- Measured catalog partitioning and retention improvements.
- Experimental common-subplan sharing only when fingerprints, versions, ownership, and security contexts are compatible.
- Selective `IMMEDIATE` mode only for combinations covered by a tested isolation and locking contract.

### v2 and experimental reasoning

- Logical supports, derived facts, provenance, and truth maintenance.
- Monotone fixed-point evaluation and atomic deployment of recursive components.
- Carefully bounded stratified negation and aggregate recursion where deletion semantics are proven.
- Temporal conditions with explicit event-time and database-time semantics, timers or scheduled reevaluation, retention, late-arriving data, and defined interaction with fixed points and negation.
- Optional fact-tuple identity for an explicitly defined query subset.
- Client-side DSLs, visual dependency tooling, natural-language-assisted authoring with validation, `pg_tide` adapters, LLM task patterns, and domain packages.

Canonical PostgreSQL views, typed functions, and explicit registration remain the foundation even when richer authoring tools are added.

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

Feature count is never a substitute for this evidence.

---

## Decisions to close at each gate

### Before developer alpha

- The exact `pg_trickle` observation contract.
- The pinned compatibility tuple.
- Watched-column defaults, comparison support, and schema-change behavior.
- The bootstrap defaults, including `SEED_CURRENT` for command rules, and the warnings required before explicit `FIRE_CURRENT` deployment.
- Whether pending activation payloads use latest-until-claim or rising-edge snapshots.
- The default behavior when compatible or incompatible source drift is detected.
- The stable output contract for validation, preview, and explanation.

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

Decisions should be recorded as short architecture decision records and linked from issues and pull requests.

---

## GitHub milestone structure

| Milestone | Purpose |
|---|---|
| **M0 — Feasibility and walking skeleton** | Retire the refresh-observation and lifecycle-atomicity risks |
| **M1 — Developer alpha** | Deliver a small, understandable, useful rule engine |
| **M2 — Reliability beta** | Prove complete lifecycle and durable execution under failure |
| **M3 — Operational RC** | Establish production support, security, recovery, and performance evidence |
| **M4 — v1 GA** | Freeze and publish the supported contract |
| **M5 — Post-GA expansion** | Improve usability, scale, reasoning, and ecosystem integration |

Each implementation issue should belong to one milestone and one primary workstream label, for example `area/semantics`, `area/compiler`, `area/catalog`, `area/worker`, `area/security`, `area/operations`, `area/performance`, or `area/docs`.

---

## Immediate next milestone

The next concrete target is **M0 — Feasibility and walking skeleton**. It should be represented by a small set of epics:

1. PostgreSQL 18, `pgrx`, and `pg_trickle` development environment.
2. Critical refresh-observer contract.
3. Pure semantic lifecycle transition planner.
4. View snapshotting, semantic-key encoding, and deterministic activation identity.
5. Minimal match-to-agenda atomic finalizer.
6. One typed consequence executed through one durable episode.
7. Property, concurrency, rollback, restart, and reconciliation test harness.
8. Executable high-value/high-risk order example from [`README.md`](README.md).

The milestone is complete only when the example survives the defined failure and concurrency tests. Everything else depends on that proof.

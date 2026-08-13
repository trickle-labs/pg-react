# pg-react state report — 2026-08-13

## Executive assessment

**Decision: M17 product implementation is not ready to start. M17 pre-entry work is ready to start.**

The repository is a clean, coherent M16 implementation candidate at extension
`0.13.0`, with a strong inherited test and recovery discipline. M17 is not a
partially implemented feature: it exists only as a detailed roadmap stage. No
M17 contract, entry fixture, schema, API, runtime, evidence model, upgrade, or
test gate exists yet.

The immediate blocker is objective. M17's entry gate requires published and
verified `v0.13.0` artifacts, checksums, disclosures, OCI digest, and a frozen
M17 reference program (`ROADMAP.md:1034`). At the live-state snapshot below,
the remote tag existed, but its release workflow was still running and no
GitHub release existed. The reference program also does not exist. Therefore
the entry gate is unmet.

The deeper blocker is semantic. M16 maintains one current aggregate snapshot
per group. M17 requires durable per-window identity, requested and complete
watermarks, ordered correction history, finalization, late-data admission,
bounded continuation, retention protection, and replay-safe recovery. Those
are new authoritative state, not fields that can safely be improvised while
coding.

The shortest safe path is:

1. let M16 publication finish and record its immutable release identities;
2. freeze one exact-output M17 reference program and close the five decision
   groups already listed in the roadmap;
3. write the M17 contract and executable entry fixture;
4. only then add the minimal `0.13.0 -> 0.14.0` SQL slice and public API changes.

## Snapshot and method

Assessment snapshot: **2026-08-13 14:44 CEST**.

| Item | Observed state |
|---|---|
| Repository | `trickle-labs/pg-react` |
| Branch | `main` |
| Assessed source HEAD | `084193a0f2ee2236c5777ff8fe00f609f71a5521` (`docs: define M17 event-time windows`) |
| Worktree before this report | Clean; `main` matched `origin/main` |
| M16 implementation | `7b647679f89576bc0a831f39ea1f42b7ff61ceac` |
| M16 tag | Remote `v0.13.0` points to `7b64767` |
| M16 GitHub release | Not present at snapshot |
| M16 release run | In progress: [run 31699725097](https://github.com/trickle-labs/pg-react/actions/runs/31699725097) |
| M16 branch CI | In progress: [run 31699689382](https://github.com/trickle-labs/pg-react/actions/runs/31699689382) |
| Assessed-HEAD CI | In progress: [run 31700929592](https://github.com/trickle-labs/pg-react/actions/runs/31700929592) |

This assessment combined:

- roadmap, design, public documentation, milestone records, migrations,
  runtime code, tests, workflows, packaging, and recent history;
- separate read-only audits of M17 scope, implementation readiness, and
  delivery/release health, reconciled against the repository;
- live GitHub checks for the remote tag, release, and Actions state;
- local formatting, unit-test, lint, and Compose configuration checks.

Local checks performed against `084193a`:

| Check | Result |
|---|---|
| `cargo fmt --check` | Pass |
| `cargo test --no-default-features` | Pass: 7 tests, 2 suites |
| `cargo clippy --no-default-features -- -D warnings` | Pass |
| `docker compose config --quiet` | Pass |

The full Docker-backed `tests/m16.sh` gate and pgrx PostgreSQL 18 compilation
were not rerun locally for this report. They are part of the in-progress CI
and release runs, so this report does not claim those live runs have passed.

## What pg-react is today

pg-react is a PostgreSQL extension that turns incrementally maintained query
truth into durable lifecycle state and asynchronous work. PostgreSQL objects
are the declaration and inspection surface; `pg_trickle` maintains relational
conditions; pg-react adds stable identities, activation transitions, facts,
supports, evidence, jobs, reconciliation, and recovery (`README.md:8-29`,
`DESIGN.md:74-175`).

The operational flow is:

```text
public PostgreSQL declaration
        -> validation / normalization / deployment
        -> versioned internal catalogs and dependency strata
        -> pg_trickle-maintained input or derived relation
        -> pg-react refresh / aggregate maintenance
        -> fact + support + activation lifecycle state
        -> database function, managed worker, or external outbox
        -> public status, evidence, explain, doctor, and reconciliation
```

Consequences remain asynchronous and at-least-once. Idempotency belongs at the
consumer boundary; neither M16 nor M17 promises synchronous completion or
exactly-once external effects (`ROADMAP.md:1053`, `README.md:116-127`).

### Implementation shape

The product is primarily PostgreSQL SQL, not a large Rust application:

- `sql/` contains the historical install scripts and one forward migration per
  release. The M16 migration alone adds 1,769 lines and carries the active
  declaration, validation, evaluation, explanation, and reconciliation changes.
- `src/` is deliberately small. Rust supplies lifecycle semantics, stable key
  identity, a reference oracle, PostgreSQL rewrite integration, and the managed
  background worker (`src/lib.rs:1-14`).
- `tests/` holds milestone-scoped exact SQL fixtures, shell runners, recovery,
  logical restore, upgrade, concurrency, performance, and compatibility cases.
- `docs/` records contracts, entry evidence, release notes, tasks, readiness,
  and upgrade procedures for recent milestones.

That shape matters for M17: the established minimal change surface is one
forward SQL migration plus exact fixtures and compact documentation. New Rust
infrastructure is not justified unless SQL/PostgreSQL cannot enforce a frozen
requirement.

### Milestone position

The repository has release tags from `v0.1.1` through `v0.13.0`. The delivered
capability sequence is internally consistent:

| Milestones | Capability established |
|---|---|
| M0-M4 | Lifecycle skeleton, developer alpha, reliability beta, operational RC, and v1 GA |
| M5-M10 | Atomic packs, batching, non-recursive derivation, positive recursion, stratified negation, and keyed `COUNT(*)` aggregation |
| M11-M15 | PostgreSQL-facing API redesign, database-time deadlines, authoring ergonomics, unified reasoning UX, managed runtime, and typed keys |
| M16 | Typed `COUNT(expression)`, `SUM`, `MIN`, and `MAX` over one strict lower-stratum dependency |
| M17 | Planned fixed event-time tumbling windows over the M16 aggregate boundary |

`README.md:204-209` still calls M16 a repository candidate. That wording is
accurate until the `v0.13.0` release run completes, but the remote tag has
already been pushed.

## M16 baseline inherited by M17

M16 is extension `0.13.0` and public contract version `5`
(`docs/m16-contract.md:1-5`). It supports exactly one aggregate dependency and
function per rule:

- inherited `COUNT(*)`;
- typed `COUNT(expression)`, `SUM`, `MIN`, or `MAX`;
- one named immutable input column rather than arbitrary SQL;
- PostgreSQL-native null, cast, comparison, collation, and overflow behavior
  within a frozen type matrix;
- strict lower, non-recursive strata;
- finite current aggregate evidence rather than input-row lineage.

The migration extends the inherited aggregate metadata in
`pgreact_internal.derivation_program_aggregate_inputs` and current evidence in
`pgreact_internal.aggregate_dependency_evidence`
(`sql/pg_react--0.6.0--0.7.0.sql:4-33`,
`sql/pg_react--0.12.0--0.13.0.sql:4-55,1168-1171,1282-1345`). The metadata
covers function, expression, source/result types, collation, relation name,
comparison, and threshold. The evidence covers current value, truth, group
identity, lower frontier, and related type information. It contains no
event-time, window, watermark, correction, or finality columns.

### Current aggregate execution path

`pgreact_internal.maintain_derived_support` is the decisive M16 runtime path
(`sql/pg_react--0.12.0--0.13.0.sql:1134-1347`):

1. It delegates non-aggregate and inactive cases to inherited maintenance.
2. It normalizes session rendering to UTC/ISO settings.
3. It queries the aggregate relation for the entire current group.
4. It creates or retracts the higher support according to current truth.
5. It upserts one current aggregate evidence row, advancing its lower frontier
   only when value, comparison, or threshold changes.

This is correct for M16's current-state contract. It is not a hidden M17
correction engine. It neither records each lower-frontier delta nor preserves
an ordered history of changes for replay or audit.

Reconciliation has the same snapshot orientation. It scans active activations,
recomputes current aggregate values, compares current metadata, records
diagnostics, and invokes an inherited rebuild
(`sql/pg_react--0.12.0--0.13.0.sql:775-1013`). It cannot presently detect a
missing or duplicated window correction, incomplete watermark batch, or lost
finalization event.

### Current public surface

M16's relevant public facade consists of:

- `pgreact_api.validate_program(jsonb)`;
- `pgreact_api.preview_program(jsonb)`;
- `pgreact_api.deploy_program(jsonb, text)`;
- the `pgreact.aggregate_dependency_evidence` view;
- `pgreact_api.explain(text, jsonb)`;
- `pgreact_api.reconcile_program(text)`;
- inherited removal, configuration, status, doctor, and run operations.

The evidence view exposes function, expression, types, exact current value,
threshold, truth, strata, lower frontier, and group key
(`sql/pg_react--0.12.0--0.13.0.sql:1487-1514`). Unified explanation emits
contract version `5` and the same finite aggregate summary
(`sql/pg_react--0.12.0--0.13.0.sql:1516-1608`). There is no watermark advance
or watermark status API and no public window/correction/finality evidence.

### Foundations M17 can reuse

M17 should preserve and extend these working foundations:

- dependency strata and component frontiers;
- atomic PostgreSQL transactions and advisory-lock patterns;
- program validation, preview, deploy, replace, remove, explain, doctor, and
  reconcile facades;
- stable typed semantic-key encoding and public/private key separation;
- M15's SQL key arity of one to four components
  (`sql/pg_react--0.11.0--0.12.0.sql:43-57`);
- the existing `bigint`, `uuid`, and `text` tuple codec
  (`src/identity.rs:30-50`);
- UTC rendering normalization already used during aggregate evaluation;
- role, ownership, `SECURITY DEFINER`, search-path, and authorization patterns;
- managed/external worker compatibility, batch configuration, health, and
  backpressure surfaces;
- exact-output recovery, logical restore, replacement, and populated upgrade
  fixtures.

The existing codec is generic; M17 still must validate its stricter domain
rule: at most three group components, followed by exactly one signed `bigint`
window ordinal. The generic Rust encoder allows more components and must not be
treated as the M17 policy boundary.

## Delivery and operational health

### Strengths

- Version identity is consistent across `Cargo.toml:7`,
  `pg_react.control:2`, `Dockerfile:14`, `docker-compose.yml:3-9`,
  `.github/workflows/ci.yml:29`, and the release workflow.
- Builder and runtime images are pinned by immutable digest
  (`Dockerfile:1-12`). `pgrx` is pinned to `0.18.0` for PostgreSQL 18
  (`Cargo.toml:15-18`).
- CI checks formatting, Rust unit tests, pgrx/PostgreSQL 18 compilation,
  Compose validity, an image build, and the full current milestone gate
  (`.github/workflows/ci.yml:8-29`).
- Release automation repeats those checks, publishes GHCR, creates a
  deterministic gzip archive and SHA-256 manifest, records the OCI digest, and
  creates the GitHub release (`.github/workflows/release.yml:13-61`).
- M16 repository evidence covers typed validation, its type/value matrix,
  null/empty/order behavior, explanation, replacement, reconciliation,
  recovery, logical restore, and populated direct upgrade
  (`docs/m16-evidence.md:3-17`, `tests/m16.sh:26-85`).
- Operator documentation covers installation verification, health, metrics,
  workers, backup/restore, upgrades, troubleshooting, and support collection.

### Non-blocking weaknesses

- GitHub Actions use mutable `actions/checkout@v4` and
  `dtolnay/rust-toolchain@stable` refs. The release job grants `contents: write`
  and `packages: write` for the whole job and checkout preserves credentials by
  default (`.github/workflows/release.yml:8-17`). This is a release-integrity
  risk despite the stronger digest-pinned container inputs. Pin action/toolchain
  identities, disable persisted credentials where unused, and narrow write
  permission to the publishing boundary.
- CI does not currently enforce Clippy, rustdoc, dependency advisories/licenses,
  shell/workflow lint, coverage, SBOM, signing, or provenance attestation. Add
  only gates required by the release policy; Clippy and advisory scanning offer
  the highest immediate value.
- Performance fixtures exist, but the current workflow runs the milestone gate
  rather than a separately tracked recurring benchmark job.
- Packaging is intentionally image-centric and `linux/amd64`. Cargo metadata is
  insufficient for crates.io publication, which is harmless if crates.io is an
  explicit non-goal.
- There is no standalone examples or benchmark directory. The canonical README
  walkthrough and integration fixtures currently carry that burden.

None of these should distract from the M17 semantic entry gate. They are
release-engineering improvements, not reasons to invent an M17 framework.

## M17 defined scope

M17's roadmap outcome is precise: add one fixed-duration, UTC-epoch-aligned,
event-time tumbling window per inherited M16 aggregate dependency, with direct
`timestamptz` input, monotone durable watermarks, bounded lateness,
deterministic corrections, finite evidence, atomic strata, and recovery
(`ROADMAP.md:1030-1044`). The target extension is `0.14.0` with a supported
direct upgrade from `0.13.0`.

The supported boundary is intentionally narrow (`ROADMAP.md:1048-1053`):

- exactly one aggregate dependency and function;
- one finite authoritative or derived lower-stratum relation;
- at most three group-key components plus one window ordinal;
- direct finite non-null `timestamptz` event time;
- fixed-duration, UTC-epoch-aligned, half-open `[start, end)` windows;
- materialize only windows touched by input;
- retain a touched window emptied by retraction until finalization;
- accept corrections only while complete watermark is strictly before
  `window_end + allowed_lateness`;
- keep consequence execution asynchronous and at-least-once.

The roadmap explicitly excludes sliding, hopping, session, calendar,
processing-time, and ingest-time windows; temporal joins; recurrence; complex
event processing; multiple windows; recursion; cross-window feedback;
automatic or coordinated watermarks; speculative results; finality retraction;
source CDC/brokering; synchronous effects; new aggregates/codecs/protocols; and
unbounded lineage (`ROADMAP.md:1057-1061`). These non-goals should remain hard
boundaries during implementation.

## M17 entry-gate audit

| Required entry evidence | State | Assessment |
|---|---|---|
| Remote `v0.13.0` tag | Present | Satisfied: points to `7b64767` |
| Successful M16 CI | In progress at snapshot | Not yet satisfied |
| Published `v0.13.0` GitHub release | Absent at snapshot | Not satisfied |
| Published archive and checksum manifest | Release still running | Not verified |
| Published immutable OCI digest | Release still running | Not verified |
| Release disclosures/notes | File exists; publication absent | Not yet satisfied |
| Populated `0.12.0 -> 0.13.0` fixture | Present in repository | Implemented; release run still pending |
| Frozen M17 reference program | Absent | Not satisfied |
| Frozen exact M17 outputs and diagnostics | Absent | Not satisfied |

`docs/m16-readiness.md:3-7` still says to run the M16 gate and then tag/push
`v0.13.0`; that record became stale as soon as the tag was pushed. It should be
superseded by `docs/m17-entry.md` only after the release run succeeds and its
artifact identities are verified.

## Requirement-to-implementation gap

| M17 area | Reusable current state | Missing authoritative work | Readiness |
|---|---|---|---|
| Contract and entry fixture | Detailed roadmap boundary and M10-M16 document pattern | `m17-entry`, contract, exact reference outputs, task/evidence/readiness/upgrade/release records | Blocked |
| Declaration | M16 aggregate object and strict validation | Event-time column, duration, lateness shapes; compatibility and canonical rendering | Blocked on contract |
| Timestamp validation | PostgreSQL type resolution; UTC rendering | Direct-only, finite, non-null `timestamptz`; exact diagnostics for data and declaration drift | Absent |
| Window identity | Typed key codec; one-to-four SQL key components | Exact ordinal formula/range/overflow, boundary math, composite public rendering | Blocked on decision |
| Persistence | Versioned aggregate metadata and current evidence | Requested/complete watermarks, per-window input summaries, window state, finality, correction history, retention dependencies | Absent |
| Maintenance | Dependency ordering, lower frontiers, atomic support/fact updates | Per-window lower-frontier deltas, canonical correction order/identity, replay no-op | Architectural delta |
| Watermark advancement | Managed coordinator/batch settings and public run patterns | Ownership, API, authorization, target persistence, bounded continuation, concurrency, standby rules | Absent |
| Finalization and late input | Transactional validation/error patterns | Exact final boundary, too-late admission policy, claim barrier, recovery after authoritative violation | Blocked on policy |
| Evidence and explain | Finite aggregate view and contract-v5 explanation | Window bounds/ordinal, requested/complete watermark, lateness boundary, finality, correction identity/frontier | Absent |
| Reconciliation | Snapshot audit and repair under advisory lock | Window/correction/watermark/finality audit and repair semantics | Architectural delta |
| Replacement/removal | Versioned atomic program lifecycle | Transfer/retire behavior for open windows, targets, corrections, and final evidence | Unspecified |
| Recovery | Physical/logical restore and restart fixtures | Exact preservation/reconstruction of watermark batches, corrections, and finality | Absent |
| Retention | Existing audited pruning concepts | Open-window and replay/rollback/explain protection; exact permitted prune rules | Blocked on policy |
| Performance | Existing milestone smoke/performance fixtures | Budgets for correction-heavy input and large watermark jumps; indexes and batch ceiling | Absent |
| Packaging | Established single-step upgrade/release workflow | `0.14.0` identities, worker compatibility, direct upgrade, fresh install and release gates | Not started |

## Decisions that must close before product code

The roadmap itself marks five decision groups as open
(`ROADMAP.md:1065-1069`). They are implementation blockers because each changes
public API, durable identity, transactional behavior, or recovery.

### 1. Declaration and deterministic window identity

Freeze:

- the exact JSON/SQL declaration and overload shapes;
- whether M16 declarations remain unwindowed by absence of a window object;
- duration and lateness bounds and their canonical rendering;
- rejection of months/calendar components and non-finite values;
- the exact `timestamptz` type/domain boundary;
- the signed `bigint` ordinal formula, negative timestamps, range, and overflow;
- composite public key and preview rendering.

The reference fixture must include timestamps immediately before, exactly at,
and immediately after boundaries, including pre-epoch timestamps and multiple
session time zones.

### 2. Watermark authority and execution

Freeze:

- who owns a watermark: input declaration, relation, or program version;
- the public target and status signatures and role grants;
- transaction boundaries for requesting and completing advancement;
- repeated, backward, concurrent, and jumping target behavior;
- batch bound, scheduling, resumption, and target-versus-complete reporting;
- lock order and primary/standby behavior.

The durable complete watermark is a commit claim. It must advance only in the
same transaction that makes every crossed materialized window final and makes
their evidence and downstream lifecycle state complete.

### 3. Too-late input policy

Freeze one exact admission policy for input at or beyond finality, its SQLSTATE
and diagnostic envelope, whether the authoritative write is rejected or the
program is quarantined, the claim barrier, and the operator repair procedure.

This is the sharpest unresolved policy decision in the current roadmap: the
supported boundary requires behavior to follow the eventual frozen policy
(`ROADMAP.md:1052`), while the policy still must be chosen before contract
freeze (`ROADMAP.md:1067`). No runtime code should choose it accidentally.

### 4. Correction identity and ordering

Freeze:

- one durable correction identity derived from program/input/window fact and
  committed lower frontier;
- canonical ordering across insert, update, window move, delete, replay,
  replacement, reconciliation, and downstream lifecycle work;
- behavior for aggregate changes that preserve comparison truth;
- no-op behavior when a lower frontier is replayed;
- whether current aggregate state can be rebuilt from retained summaries and
  how history is verified without general row lineage.

M16's current evidence-row identity cannot stand in for this history.

### 5. Evidence, retention, concurrency, and recovery

Freeze the public evidence schema, retention horizon, indexes, resource limits,
batch ceilings, lock order, failure rollback, drift response, pruning audit,
logical-dump identity, physical recovery, and direct-upgrade behavior. Explicit
fixtures must prove that an incomplete batch resumes from the last complete
watermark without duplicating corrections or finalization.

## Risk register

| Priority | Risk | Evidence | Consequence | Required mitigation |
|---|---|---|---|---|
| P0 | M17 entry gate is unmet | Release absent/in progress; no M17 fixture | Work begins from an unverified predecessor and moving oracle | Finish/verify M16 release; record immutable identities; freeze entry fixture |
| P0 | Public/durable contract is unfrozen | `ROADMAP.md:1065-1069` | Early schema/API choices become incompatible state | Close all five decision groups before migration code |
| P0 | Too-late policy is undefined | `ROADMAP.md:1052,1067` | Silent divergence, rejected authoritative data, or irrecoverable finality | Freeze exact admission, diagnostics, barrier, and repair path |
| P0 | No executable M17 oracle exists | No `tests/m17*` or `docs/m17-entry.md` | “Correct” behavior cannot be reviewed or regression-tested | Build exact reference schedule/output fixture first |
| P1 | M16 snapshots do not provide M17 correction history | Current recomputation/upsert path at migration lines 1195-1345 | Replays, moves, and late corrections can duplicate or disappear | Add explicit correction identity/state after contract freeze |
| P1 | Watermark completion is a new atomicity boundary | No target/complete state or API | Completion may outrun finalization or downstream truth | Persist target/complete separately; batch atomically under frozen lock order |
| P1 | Reconciliation is snapshot-only | Migration lines 775-1013 | Lost correction/finality history may pass current repair | Define temporal audit invariants and exact repair limits |
| P1 | Retention can destroy open-window recovery evidence | No M17 retention dependency model | Replay, explanation, rollback, rebuild, or finalization becomes impossible | Protect per-window input summaries and open/pending/recovery-horizon state; audit every prune |
| P1 | Resource and performance ceilings are unspecified | Roadmap decision group; no M17 benchmark | Watermark jumps or correction storms cause unbounded work | Freeze batch/window limits, indexes, and regression budgets |
| P1 | Recovery identity is unproved | No M17 restore/upgrade fixture | Dump/restore or restart changes ordering/finality | Exact physical, logical, restart, and populated-upgrade fixtures |
| P2 | Milestone status docs are stale | M12, M15, and M16 readiness wording | Engineers may implement from obsolete assumptions | Make `m17-entry` the dated source of entry truth; keep old records historical |
| P1 | Release job trusts mutable inputs with broad write permission | `checkout@v4`, stable Rust, job-wide `contents`/`packages: write` | A moved upstream ref can affect published source artifacts and images | SHA-pin actions/toolchain, disable unused persisted credentials, and narrow publishing permission |
| P2 | Quality/security gates are narrow | No CI Clippy/advisory/SBOM/signing | Defects or dependency risk can escape | Add targeted gates separately from M17 semantics |

## Documentation consistency findings

- There are no `docs/m17-contract.md`, `docs/m17-entry.md`,
  `docs/m17-evidence.md`, `docs/m17-readiness.md`, `docs/m17-tasks.md`, M17
  upgrade guide, release notes, or `tests/m17.sh`. The M10-M16 pattern makes
  these absences meaningful, not cosmetic.
- `docs/m12-readiness.md` predicts richer aggregation as M13, while the actual
  roadmap places ergonomics at M13, richer aggregation at M16, and windows at
  M17. Preserve it as historical evidence or label it explicitly superseded.
- `docs/m15-readiness.md` says no post-M15 milestone is committed and M16 is a
  proposal. It is also historical now.
- `docs/m16-readiness.md` still instructs tagging/pushing `v0.13.0`; the remote
  tag now exists and publication is in progress.
- `README.md` is a useful product entry point but intentionally compresses
  milestone history. It must not be used as the sole readiness record.

## Recommended M17 start sequence

### Gate 0 — finish the predecessor

Do not merge M17 product code until the `v0.13.0` CI and release runs succeed.
Verify the archive SHA-256 and OCI digest from the published artifacts, then
record the exact commit, run, release URL, archive digest, image identity, and
upgrade fixture in `docs/m17-entry.md`.

If either run fails, fix M16/release infrastructure as M16 work. Do not hide the
failure inside the M17 migration.

### Gate 1 — freeze behavior before schema

Create the smallest bounded reference program that covers the full M17 entry
gate. Its fixtures should assert full ordered outputs, not counts:

- declarations and previews;
- boundary and pre-epoch window assignments;
- every M16 aggregate and supported type needed by the M17 contract;
- null expression and emptied-window behavior;
- in-order and out-of-order inserts, updates, moves, and deletes;
- on-time, correctably late, and finalized input;
- repeated, backward, concurrent, incomplete, and jumping watermark targets;
- exact aggregate values, facts, supports, evidence, corrections, frontiers,
  diagnostics, explanations, and finality;
- replacement, reconciliation, restart, physical/logical restore, and populated
  direct upgrade.

The fixture can initially fail or serve as a frozen oracle, but expected output
must be reviewed before production code encodes it.

### Gate 2 — publish the contract

Write `docs/m17-contract.md` from the frozen decisions, not by copying the
roadmap. Include exact public signatures, authorization, SQLSTATE/diagnostic
envelopes, canonical renderings, state transitions, lock/batch behavior,
retention guarantees, repair limits, and non-goals. Link the immutable M16
entry record.

### Gate 3 — implement one vertical PostgreSQL slice

Prefer one forward migration, `sql/pg_react--0.13.0--0.14.0.sql`, extending the
existing program and public API paths. The first vertical slice should prove:

1. declaration validation and normalization;
2. deterministic window ordinal/bounds and composite semantic identity;
3. durable requested/complete watermark and one bounded advancement batch;
4. one correction identity applied exactly once;
5. atomic aggregate/evidence/fact/support/frontier update;
6. public status and explanation of that state.

Reuse the existing codec, transaction, role, program-version, explanation, and
worker patterns. Avoid a new Rust service, scheduler abstraction, or generic
streaming layer: none is required by the frozen M17 boundary.

### Gate 4 — complete lifecycle and failure semantics

Add window moves/deletes, emptied windows, correctably late input, finalization,
too-late handling, truth-preserving corrections, concurrent target behavior,
resume after injected failure, replacement/removal, reconciliation, retention,
drift, and resource ceilings.

### Gate 5 — recovery, compatibility, and release

Add exact fresh-install, API-inventory, privilege, concurrency, restart,
physical restore, logical restore, and populated `0.13.0 -> 0.14.0` tests. Rerun
the inherited M0-M16 gate unchanged. Then update version identities, managed
worker compatibility (`src/managed.rs:101`), images, workflows, README, tasks,
evidence, readiness, upgrade, and release notes.

## Minimum definition of “ready to implement”

M17 may move from pre-entry work to product implementation when all of these
are true:

- [ ] M16 CI and release runs completed successfully.
- [ ] `v0.13.0` archive, checksum, OCI digest, release notes, and direct upgrade
      were independently verified and recorded.
- [ ] The M17 reference program and full exact expected outputs are frozen.
- [ ] Declaration, duration/lateness, ordinal, and compatibility semantics are
      exact.
- [ ] Watermark ownership, API, authorization, transactions, batching,
      concurrency, and standby behavior are exact.
- [ ] Too-late input admission, diagnostics, barrier, and repair are exact.
- [ ] Correction identity/order and replay behavior are exact.
- [ ] Evidence, retention, locks, limits, failure rollback, recovery, and
      upgrade behavior are exact.
- [ ] `docs/m17-contract.md` and the executable entry fixture agree byte for
      byte on public output.

## Final judgment

pg-react is in good shape at the M16 implementation boundary: its architecture
is PostgreSQL-native, its public facade is established, identity and strata are
reusable, recovery is treated as product behavior, and release automation is
substantial. The codebase does not show abandoned M17 scaffolding or competing
temporal abstractions that need cleanup first.

M17 is nevertheless a state-model change, not a routine extension to the M16
aggregate query. Starting with catalogs or runtime code now would force the
implementation to decide public and recovery semantics implicitly. Start with
M16 publication verification and the exact M17 oracle. Once those are frozen,
the project can proceed with a narrow SQL-first migration and reuse most of the
existing platform without creating a general streaming subsystem.

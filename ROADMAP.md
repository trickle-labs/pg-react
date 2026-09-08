# pg-react roadmap

> **Status:** Living delivery plan  
> **Last updated:** 2026-09-08
> **Current release:** `0.43.1` (M54)

## Product goal

Make changing PostgreSQL facts into durable, inspectable policy state and work
with a small ordinary path and explicit advanced surfaces. PostgreSQL remains
authoritative; rules remain inspectable; safe change beats speculative breadth.

## Committed release sequence

The [September assessment](pg-react-assessment.md) supplies the next work.
Its findings describe source mechanisms at `3807329`, not locally reproduced
PostgreSQL failures or measured capacity. Each plan starts by reproducing the
affected behavior and ends with executable release gates.

| Release | Scope | Required outcome | Implementation plan |
| --- | --- | --- | --- |
| `0.43.2` | Authorization and review correctness | Intended roles can use the API; reviewed changes bind to executable dependencies; comparison holds facts constant; valid package graphs finish within a fixed budget | [v0.43.2 plan](v0.43.2-implementation-plan.md) |
| `0.43.3` | Durable work and recovery | A damaged job does not undo healthy work; retries and draining leases recover; status is truthful; populated restore uses the matching artifact | [v0.43.3 plan](v0.43.3-implementation-plan.md) |
| `0.44.0` | Measured operating limits and SQL maintenance | Comparison avoids unrelated history scans; capacity and recovery limits have reproducible evidence; current SQL and qualification are independently inspectable | [v0.44.0 plan](v0.44.0-implementation-plan.md) |

These releases are ordered commitments without calendar promises. `0.43.2`
closes authorization and review risks. `0.43.3` closes the remaining P1
progress and recovery findings. Broad production adoption remains gated on
both patches. `0.44.0` measures the corrected implementation before making
supported-scale claims. Release qualification must report any still-open
finding from a later plan as a limitation of the candidate.

This sequence replaces the open-ended selection process in the earlier M54
plans and [future vision](vision/pg-react_future_milestones.md). Existing
milestone numbers remain historical topic identifiers. The versioned plans
define delivery order. `1.0.0` remains postponed indefinitely.

## Assessment coverage

Each finding has one release responsible for closure. Later releases retain
its regression tests. F07 and F10 move ahead of the assessment's third phase
because misleading comparisons and exponential graph processing are P1
correctness risks. F14 and F16 move with their shared planning and identity
code. F15 moves with runtime recovery so operator output agrees with claiming.
F18 moves ahead of maintenance so recovery qualification has useful CI signals.

| Finding | Release | Concrete deliverable |
| --- | --- | --- |
| F01 | `0.43.2` | Idempotent API grant synchronization for fresh install, upgrade, and role rotation |
| F02 | `0.43.2` | Explicit PUBLIC revokes and positive and negative effective-privilege tests |
| F03 | `0.43.2` | Shared transitive source validation and a caller-authorized comparison execution context |
| F04 | `0.43.2` | Locked enforcement of every accepted legacy deployment precondition |
| F05 | `0.43.2` | Explicit old-work consent based on deployed effect-bearing work |
| F06 | `0.43.2` | Versioned review fingerprints covering supported executable and transitive dependencies |
| F07 | `0.43.2` | Same-snapshot rule and decision comparison with lifecycle-aware work projections |
| F08 | `0.43.3` | Saturating retry arithmetic and durable bookkeeping at maximum retry settings |
| F09 | `0.43.3` | Per-job failure isolation with atomic consequence and completion state |
| F10 | `0.43.2` | Bounded topological processing for validation and package ordering |
| F11 | `0.43.3` | Populated stopped-cluster backup, adjacent upgrade, and failed-upgrade restore qualification |
| F12 | `0.43.3` | Name-based and automatic recovery of expired leases in draining versions |
| F13 | `0.43.3` | Managed status preserves structured coordination failures and their causes |
| F14 | `0.43.2` | Package preview blocks unsupported child changes before deployment |
| F15 | `0.43.3` | Correct advisory claimability and a real state-change timestamp |
| F16 | `0.43.2` | Canonical quoted identifiers and correct constructor volatility |
| F17 | `0.44.0` | Target-specific comparison provenance, fewer source scans, and execution-cost qualification |
| F18 | `0.43.3` | Current scheduled qualification and explicitly pinned manual historical lanes |

The assessment's unnumbered work also has a release home. `0.43.2` adds the
normal-role authoring journey, stable declaration examples, and semantic API
inventory assertions. `0.43.3` adds executable recovery runbooks and failed-run
evidence retention. `0.44.0` separates current SQL from migration history,
organizes regression checks by behavior, and publishes the benchmark matrix.

## Gates carried by every release

1. Reproduce each assigned finding against the preceding release. Preserve
   full expected output and state, including denied calls and failure paths.
2. Preserve valid ordinary calls under the [versioning policy](docs/versioning.md).
   Keep compatibility entry points installed. Document any deliberately
   invalidated review token or corrected diagnostic field.
3. Preserve the qualified PostgreSQL, pg_trickle, pgrx, isolation, platform,
   and managed-runtime boundary in [current-release.json](docs/current-release.json)
   until a separate compatibility run establishes a change.
4. Append adjacent upgrade SQL and a deterministic fresh-install artifact.
   Freeze published SQL artifacts. Prove exact populated-state preservation
   except for explicitly documented migration changes.
5. Run the current docs audit, semantic and installed API audits, Rust checks,
   inherited SQL regressions, fresh install, adjacent upgrade, and concurrency
   cases against the exact candidate. Add M34 and M35 comparison regressions
   explicitly; the current M54 inherited list does not include them.
6. Update version assertions together when implementing each release, including
   `ROADMAP.md`, the release manifest, extension metadata, container defaults,
   worker compatibility, API inventory, and release workflow. These planning
   documents do not change the current released version.
7. Publish only the image and evidence that qualification tested. Retain logs
   on failure. A missing database run, skipped benchmark, or static-only pass
   cannot satisfy an execution gate.

`0.43.3` replaces the inadequate populated recovery gate identified by F11.
The `0.43.2` plan requires a consistent backup for its own adjacent update,
but must not present the inherited M54 complete lane as proof that F11 is closed.

## Candidates after v0.44.0

Select additional capability from a named workload and executable acceptance
criteria after these releases. Safety evidence still takes priority.

| Candidate | Choose when |
|---|---|
| M59 — Supported-scale qualification | Throughput, WAL, storage, retention, recovery, or bounded-cost uncertainty blocks adoption |
| M58 — Authorization alignment | Grants, security context, or RLS blocks a real supported workload |
| M45 — Rolling/hopping windows | Missing event-time windows block an otherwise suitable policy |
| M55 — Schema-change safety | Ordinary DDL cannot be shown safe |
| M56 — Rebuild/reconciliation safety | Restore, rebuild, failover, or reconciliation cannot be shown safe |

The committed plans already cover the assessment's authorization, recovery,
and scale work associated with M58, M56, and M59. Remaining work in these topics
needs new evidence. General RLS support and rolling or hopping windows have no
committed release.

## Explicit non-goals

The roadmap does not promise a policy DSL, client SDK, visual or AI authoring,
cross-database deployment, approval routing, exactly-once external delivery,
general workflow orchestration, or a new scheduler.

Completed milestone detail through M53 is preserved in
[roadmap-through-m53.md](docs/history/roadmap-through-m53.md). Release
contracts and qualification evidence are indexed by [History](docs/history.md).

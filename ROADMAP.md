# pg-react roadmap: optional MDM stewardship integration

> **Status:** Ready to start stack qualification; stewardship APIs and joint compatibility remain to be implemented and proven\
> **Updated:** 12 September 2026\
> **Released baseline:** pg-react `0.45.0`; target dependencies pg-trickle `0.105.2` and pg-mdm `0.11.0`\
> **Proposed sequence:** `0.46.0`–`0.50.0`, then independently opt-in `0.51.0`  
> **Budget:** Approximately six person-weeks per version, including tests, review, documentation, and contingency  
> **Version 1.0:** Remains postponed; this roadmap does not introduce a 1.0 deadline

## 1. Product goal and interpretation

Turn MDM review facts into **routing decisions, deadline policies, and durable requests for MDM-controlled actions**, while preserving pg-react's ordinary SQL authoring, review, deployment, comparison, explanation, and recovery model.

Implement the [React plan](plans/PLAN_PG_REACT_MDM_STEWARDSHIP.md) and the [MDM companion plan](plans/PLAN_PG_MDM_STEWARDSHIP_INTEGRATION.md) through the release sequence below. Start with ordinary local policy tables. Output-delta consumption, Tide, a semantic event feed, and prepared/resumable MDM execution remain outside the initial integration. The [evidence register](docs/planning/EVIDENCE.md) separates released capabilities, missing APIs, and joint qualification work. [S0, S8, S9]

The architectural boundary is:

```text
pg_trickle public extension contracts
    -> independently coordinated MDM evidence/publication
    -> MDM-owned local policy-case relation
    -> pg-react routing/deadline policies
    -> pg-react durable database work
    -> typed MDM intent submission
    -> MDM-owned receipt and, where applicable, later publication

Authenticated human approvals -> MDM approval API, never a React worker
```

pg-react owns policy evaluation and delivery bookkeeping. MDM owns reviews, identity resolution, authorization of control changes, human approvals, and final publication. The adapter is optional; neither core extension gains a mandatory dependency on the other. MDM-specific logic belongs outside the generic rule evaluator. [S0 §§1, 5–7]

## 2. Rebase on the released dependencies

pg-trickle `0.105.2` advertises stable, enabled `external_graph_refresh` and `output_delta_consumer` major 1, minor 0. The earlier wait for a released Graph V1 build is obsolete. Start R0 qualification against this release now. Archive its published assurance evidence and rerun the joint cases before accepting the stack. The release's deferred soak and longevity work must remain visible in the supported operating limits. [S8]

pg-react `0.45.0` still pins pg-trickle `0.98.0` and rejects enabled Graph/Delta capabilities in `sql/current/pgtrickle.sql`. R0 must update runtime admission, health diagnostics, packaging, migrations, and compatibility fixtures together. Resolve the existing PostgreSQL 18.4 manifest versus 18.3 image discrepancy against the actual selected binaries. Preserve `pg_trickle.differential_max_change_ratio=1.0` until its lifecycle regression proves a replacement safe. [S1–S3]

pg-mdm `0.11.0` supplies review publication, human pair decisions, golden overrides, Graph V1 integration, and transactional refresh. Its qualified dependency is pg-trickle `0.105.1`; `0.105.2` needs a compatibility rerun. It does not supply `mdm_steward.policy_cases_v1`, `submit_policy_intent`, bindings, policy receipts, or approval proposals. The companion plan is now present and defines that post-0.11 work. MDM's forced FULL candidate-pair refresh remains required until an exact-output regression proves it can be removed. [S0, S9]

## 3. Approach: qualify first, deliver a narrow vertical slice

Implement one release at a time. Keep the base rule engine useful without the adapter. Use the existing explicit pg-react coordinator; do not introduce a second scheduler or move ownership of MDM's graph into a React consequence.

The new pg-trickle extension points are used as a **public capability and qualification boundary** for the selected stack. The MDM side owns any admitted Graph V1 execution. React reads committed MDM policy tables and submits local typed intents. Replacing React's own coordinator with Graph V1, or optimizing its lifecycle through Delta V1, requires a different, workload-backed design and is not silently included in these six budgets.

Start the runtime compatibility work and MDM M0 contract work together. Qualify the released upstream profile before dependent integration implementation. MDM M1 supplies the real policy projection needed to close R0 and R1; MDM M2 supplies the intent API needed to qualify R2 and R3. Fixture work supports these steps, but cannot close a live gate. [S0 §2; S8, S9]

The critical path has explicit handoffs:

| Order | Owner | Work and handoff |
|---|---|---|
| 1 | React runtime owner and MDM release owner | Build one PostgreSQL 18 stack with pg-trickle `0.105.2`; rerun both projects' compatibility suites and retain the exact artifact evidence. |
| 2 | MDM contract owner with React adapter owner | Complete M0: freeze types, signatures, roles, request identity, freshness, binding races, and receipt outcomes in `MDM-STEWARDSHIP/1`. |
| 3 | MDM implementation owner | Complete M1: publish the logged, authorized non-RLS policy table and stable occurrence keys atomically with MDM publication. This closes the MDM dependency for React `0.46.0` and `0.47.0`. |
| 4 | MDM implementation owner and React adapter owner | Complete M2 and React `0.48.0`: typed controls, bindings, deduplication, receipts, immutable work, and atomic delivery. MDM work can proceed while React builds R1. |
| 5 | React runtime owner and joint release reviewer | Complete `0.49.0`, then MDM M4 with React `0.50.0`: time-only escalation and the full end-to-end, privilege, race, upgrade, and recovery suite. |
| 6 | MDM approval owner | Schedule M3 separately before React `0.51.0`; the initial rollout has no approval dependency. |

Track M0–M4 as separate post-0.11 MDM work packages. The MDM repository has no assigned versions beyond `0.11`; agree owners and estimates before committing joint dates. The React budgets below do not fund the missing MDM implementation.

## 4. Versioned delivery sequence

Each budget is **30 person-days = six person-weeks**, assuming five working days per person-week. It is engineering effort, not elapsed time or a promised date. Upstream implementation, waiting for partner releases, and deployment observation time are not hidden inside the estimate. Required React integration engineering and joint testing are included.

| Version | Outcome and original milestone | Principal scope | Release exit | Effort |
|---|---|---|---|---:|
| [0.46.0](plans/v0.46.0.md) | Stack and contract qualification — R0 | Resolve artifact identity; pin the qualified stack; approve the MDM-owned interface; capability admission, authorization, shared fixtures, rollback and upgrade harness | Exact stack passes the required conformance and isolation tests; the signed contract is available; no live policy effects are enabled | 6 person-weeks |
| [0.47.0](plans/v0.47.0.md) | Read-only policy package — R1 | Routing candidates, deadline configuration, versioned declarations, complete bounded shadow comparisons, public explanations | Routes and deadlines match expected results with no MDM writes, intent submission, or durable command execution | 6 person-weeks |
| [0.48.0](plans/v0.48.0.md) | Durable intent adapter — R2 | Immutable request snapshots and keys; local transactional submission; receipt correlation; stale-work handling; binding checks | Duplicate/retried work causes at most one intended MDM control change; rollback and replacement races are demonstrated | 6 person-weeks |
| [0.49.0](plans/v0.49.0.md) | Managed deadlines and escalation — R3 | Time-only reevaluation; bounded escalation levels; action-relevant change tracking; deadline preservation | An idle overdue case escalates once per permitted level; restarts, retries, human edits, and audit updates cannot create repeat actions | 6 person-weeks |
| [0.50.0](plans/v0.50.0.md) | Joint rollout and supported operating envelope — R5 | Shared failure suite, fixed-population shadowing, named cohort, operational queries, recovery/clone drills, measured limits | Initial routing/deadline/escalation profile is qualified on a real MDM stack and approved for the named cohort | 6 person-weeks |
| [0.51.0](plans/v0.51.0.md) | Optional approval-policy integration — R4 | After MDM M3: constrained proposals for approval requirements and display of MDM-owned outcomes | No human votes or approval authority move into React; approval support remains separately gated and disabled by default | 6 person-weeks |

The primary route is **30 person-weeks** through `0.50.0`; the conditional approval release adds **six**, for **36** total. Number assignments are proposals, not reserved release dates. A corrective `0.45.x` patch, if necessary, is not a separate six-person-week feature milestone; rebase the adjacent upgrade chain on the actual preceding release.

R5 intentionally precedes optional R4. This sequencing change makes the source's first-release routing/escalation success independent of approval support. All six source milestones are retained; none is represented as already implemented. [S0 §§5, 8]

## 5. Dependency gates and honest completion

| Gate | Required evidence | Blocks |
|---|---|---|
| **UPSTREAM** | `0.105.2` release availability and stable enabled Graph V1 are established in source; archive release evidence and pass independent ownership, rollback, boundary, restart, and upgrade cases | Dependent integration implementation and live qualification; R0 compatibility work starts now |
| **IDENTITY** | PostgreSQL, pg_trickle, pg-react and image digest agree with the effective runtime; exact binaries pass qualification | Completion of `0.46.0`; supported-stack claims |
| **CONTRACT** | Companion proposal is available; MDM M0 must freeze and approve exact SQL types/signatures, concurrency, idempotency, permissions, and examples | Completion of `0.46.0`; client implementation against a frozen interface |
| **MDM-READ** | `0.11.0` review publication exists; MDM M1 must add the authorized non-RLS policy table and occurrence mapping | Read-only joint qualification; fixture results alone do not close R0/R1 |
| **MDM-INTENT** | Absent in `0.11.0`; MDM M2 must implement atomic control/receipt behavior, binding lifecycle, and deduplication | Live intent qualification in `0.48.0`; no provisional private API substitute |
| **TIME** | Supported managed temporal path proven to evaluate after time advancement without business-table writes | Completion of `0.49.0` |
| **COHORT** | Named workload and owner; full shadow coverage; numeric operating/recovery thresholds; approved pause/restore procedures | Completion of `0.50.0` |
| **APPROVAL** | MDM M3 or explicitly approved semantic equivalent is implemented and qualified, with independently advertised support | Start and enablement of `0.51.0` only |

A skipped positive test, design document, fixture-only pass, or disabled capability is not a completed live gate. Record statuses as `passed`, `failed`, `blocked`, or `not_applicable`, with the reason and evidence. A required blocked gate prevents release qualification. Upstream and MDM version targets are hints for planning; capability and behavioral evidence decide admission. [S0; S4–S6]

## 6. Contract invariants carried by every version

1. **Authority stays with MDM.** React cannot resolve identity, record human votes, or bypass MDM stewardship validation. Start with one administrative scope and an authorized non-RLS policy projection; no RLS-hiding view or `BYPASSRLS` workaround.
2. **One local transactional effect boundary.** Submit the typed intent, retain the MDM receipt reference, and complete corresponding React database work in one PostgreSQL transaction. Never call `mdm.refresh()` from a consequence.
3. **Immutable retry identity.** Persist a canonical versioned request key and complete body with work. Retries reuse both. Changed arguments require new work and a new key; stale work is terminal and triggers explicit reevaluation.
4. **Current binding is authoritative.** Recheck the active policy binding at execution under a race-safe MDM contract. Old-policy work cannot act after replacement. Pause prevents new intents; it does not reverse accepted controls or publication.
5. **Time is an explicit input.** Use managed temporal/deadline facilities, not a materialized `now()` predicate assumed to refresh itself. Keep existing due dates unless an authorized replacement says otherwise.
6. **Evidence is bounded and honest.** A `partial` comparison does not establish whole-population safety. Command delivery, MDM control application, pending publication, and business resolution are distinct states.

These are source requirements, with detailed proposed engineering mechanisms in the version plans. [S0 §§3–8]

## 7. Common release engineering

Every version must pass [RELEASE-GATES.md](docs/planning/RELEASE-GATES.md), including ordinary-API compatibility, fresh install, adjacent upgrade, populated recovery, normal-role tests, concurrent execution, and exact-artifact evidence. Preserve published SQL artifacts; append migrations instead of rewriting history. Never update `docs/current-release.json` merely to land these planning documents. [S7]

Use these repository locations:

| Location | Responsibility |
|---|---|
| `integrations/pg-mdm/` | Optional adapter package, MDM-owned contract pin, mapping and operator documentation |
| `showcase/mdm-stewardship/` | Runnable fixture and, once gated, live examples |
| `tests/integrations/pg-mdm/` | Shared fixtures, contract, privileges, concurrency, restart and failure cases |
| `docs/planning/` | Evidence register and cross-release acceptance requirements |
| `plans/v0.xx.0.md` | Detailed implementation plan for each version |

Assign a React runtime owner, adapter owner, MDM contract owner, upstream liaison, and independent release reviewer before each version starts. These are responsibilities, not assumed hires or dedicated full-time staffing.

## 8. Scope controls and decision points

Re-estimate after `0.46.0` and `0.48.0` from actual engineering effort. Each plan includes two person-days of contingency. When projected effort exceeds 30 days, remove optional ergonomics or split a newly discovered feature into a separately approved future release. Never cut permission checks, exact retry semantics, recovery, or required evidence to preserve a version number.

Keep general RLS/multi-tenancy, rolling/hopping event windows, a new scheduler, generalized workflow/BPM, identity resolution, human approval execution, network notification transports, Delta V1 consumption, and a wholesale Graph V1 coordinator migration outside this sequence. Existing generic schema-change, rebuild/reconciliation, and scale work can interrupt the sequence when a demonstrated safety defect blocks the selected workload; this roadmap does not claim those broad topics are complete.

The final first-release decision is narrow: **Can the named MDM cohort be routed, assigned due dates, and escalated safely while human stewardship remains authoritative?** Broader adoption requires additional measured evidence, not a larger version number.

## References

Source identifiers S0–S9 resolve in the [evidence register](docs/planning/EVIDENCE.md). Start implementation with the [0.46.0 plan](plans/v0.46.0.md); every later plan lists its own admission gates and predecessor.

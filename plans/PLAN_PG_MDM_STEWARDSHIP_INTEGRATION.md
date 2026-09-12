# pg-mdm: policy-assisted stewardship implementation plan

**Status:** Post-0.11 implementation plan; proposed stewardship APIs remain unimplemented\
**Updated:** 12 September 2026\
**Dependency target:** pg-mdm `0.11.0` plus the work below, pg-trickle `0.105.2`, and the pg-react `0.46.0`–`0.50.0` sequence\
**Repository:** `trickle-labs/pg-mdm`\
**Companion:** [pg-react implementation plan](PLAN_PG_REACT_MDM_STEWARDSHIP.md)  
**Proposed shared contract:** `MDM-STEWARDSHIP/1`

## 1. Goal and ownership

Let pg-react recommend where an identity-review case should go, when it should be escalated, and later which approval policy applies. pg-mdm remains the authority for review state, human approvals, permitted decisions, and identity changes.

pg-mdm `0.11.0` implements review publication, durable pair `MATCH` and `NOT_MATCH` decisions, anchored golden overrides, and transactional graph refresh. Reuse those implementations. Assignment, deadlines, escalation controls, automation bindings, policy receipts, and approval proposals remain new work. This optional integration extends the released core without making pg-react a core dependency. [1][2][3]

```text
MDM publishes a review case
    -> React evaluates a policy
    -> React submits a bounded intent through an MDM API
    -> MDM validates and records the permitted control change
    -> A later MDM refresh publishes any resulting identity change
```

There is no synchronous MDM -> React -> MDM refresh cycle. Human decisions remain possible without pg-react.

## 2. Entry gate

Start joint stack qualification now. Released pg-trickle `0.105.2` advertises stable, enabled `external_graph_refresh` major 1, minor 0. Replace the old wait for the planned `0.97` freeze with a check of this release's artifact and assurance evidence. Pass the MDM graph, rollback, recovery, and clone-isolation cases before dependent integration implementation. [5]

MDM `0.11.0` pins pg-trickle `0.105.1`. Qualify `0.105.2` using the existing MDM E2E, upgrade, restore, security, and package checks. Keep full-entity resolution and the forced FULL candidate-pair nodes in `src/graph_spec.rs`; `0.105.2` has no engine changes that establish a fix for the multi-row pair-insert problem. Delta V1 remains unused. [4][5]

Qualify pg-react against the same packaged stack in R0. Its released `0.45.0` runtime accepts pg-trickle `0.98.0` with disabled Graph/Delta capabilities, so both admission logic and packaging need changes. Use trigger CDC, scheduler off, `READ COMMITTED`, and separate MDM-owned EXTERNAL graphs as the initial joint profile. These are joint restrictions, not all of pg-trickle's capabilities. [6]

Keep M0–M4 as proposed post-0.11 MDM work packages. The MDM roadmap has no assigned later release numbers. Assign an MDM implementation owner and estimate these packages separately from the React release budgets before setting joint dates.

## 3. First release scope

Ship **queue assignment, due dates, escalation state, and audit receipts**. Use one administrative scope in one PostgreSQL database. Keep sensitive identity evidence behind MDM permissions; policy inputs expose only approved metadata.

Defer multi-person approvals to the next optional milestone. Defer automatic `MATCH` / `NOT_MATCH`, direct merge/split commands, bulk actions, cross-database delivery, and a reviewer UI. Existing MDM matching rules continue to make their normal automatic decisions.

## 4. Shared interface: `MDM-STEWARDSHIP/1`

This section is the proposed normative interface for both plans. Names below are **new proposed names**, not existing SQL functions. Freeze exact PostgreSQL types and signatures in the contract milestone.

Build on the released public data without treating it as the finished policy contract:

| Released foundation | Required addition |
| --- | --- |
| `mdm_out.<entity>_review` after first publication | Project `review_id uuid`, `issue_key bytea`, `occurrence integer`, status, reason, masked metadata, and `concurrency_version bigint` into an MDM-owned policy table. Add queue, due date, escalation, permissions, and basis fields. |
| Review recurrence creates a new UUID and occurrence | Allocate a persistent bigint `case_key` for each occurrence. Retain closed mappings for replay and restore. |
| `mdm.describe(entity_name text, format text)` | Map definition versions, decision epoch, publication revision, and `pending_stewardship` to documented contract fields. Add a policy-specific evidence digest and action-driving revision. |
| `mdm_steward.decide(...)` and golden-override APIs | Preserve these as human stewardship operations. They have optimistic versions but no policy request-key protocol; do not use them as an automated intent adapter. |

MDM's `pending_stewardship` uses the latest successful publication observation, including no-change observations. Do not infer pending state solely from an unchanged publication revision. Freeze the mapping between review `concurrency_version`, decision epoch, definition versions, and proposed intent tokens in M0. [1][2]

| Proposed surface | Contract |
| --- | --- |
| `mdm_steward.policy_cases_v1` | Permission-controlled, logged policy-input table. MDM alone maintains it. Expose a unique, non-null `case_key bigint`, the original `review_id`, immutable occurrence `opened_at timestamptz`, entity, reason, open/resolved state, permitted actions, queue, due date, escalation level, and concurrency/basis tokens. |
| `mdm_steward.submit_policy_intent(...)` | Typed, allowlisted command API. Initial actions are `ASSIGN_QUEUE`, `SET_DUE_AT`, and `ESCALATE`. No arbitrary SQL, private-table writes, or identity mutations. |
| `mdm_steward.policy_receipts_v1` | Authorized results keyed by binding and request key; record action, outcome, reason, policy provenance, actor, and any resulting publication revision. |

**Identity and freshness.** Allocate `case_key` once per review occurrence, retain its mapping, and never reuse it. Do not hash an opaque review ID into a bigint. The MDM V1 design gives recurring issues new review occurrences; the integration must preserve that distinction. [2]

Record `opened_at` when a new occurrence is first published. Retain it through later publications and restore; recurrence gets its own timestamp. Released review rows have revision numbers but no creation timestamp. M0 must define an auditable backfill for existing occurrences from retained publication evidence. If that evidence is unavailable, expose an unknown timestamp and withhold automatic deadline assignment until an authorized backfill supplies it. Never use adapter installation or retry time as the case opening time.

Each intent carries `binding_id`, `request_key`, `case_key`, typed action arguments, expected review version, definition version, publication revision, stewardship epoch, evidence-basis digest, and policy/evaluation/work references. The basis includes relevant subject membership and evidence. Relevant changes invalidate an unexecuted proposal. The first implementation may reject conservatively when the wider boundary changes.

**Authorization and concurrency.** Authenticate the caller, then check for an existing request. For a new request, lock and validate the case and automation binding in the same transaction as the control update. Check allowed actions, queue membership, deadline limits, manual assignment locks, and the binding's currently authorized policy digest. Conflicting requirements fail closed; an automated request cannot weaken an administrator's minimum review requirements.

**Idempotency.** Enforce uniqueness on `(binding_id, request_key)`. An identical authorized retry returns the existing receipt without repeating the action. Reuse with different arguments returns `IDEMPOTENCY_CONFLICT`. Preserve request identity across retries and ambiguous connection outcomes.

**Publication.** Evidence fields in the policy table change only with a successful MDM publication; administrative fields change with their control transaction. `APPLIED_CONTROL` means a routing or deadline update committed. Later identity-decision support must distinguish `ACCEPTED_PENDING_PUBLICATION` from `APPLIED_PUBLICATION`; only the latter records a successful resulting MDM publication. Resolving identity is never inferred from an intent receipt alone. This preserves the design's separation between accepted stewardship input and published semantic state. [2][3]

## 5. Implementation milestones

| Milestone | Deliverables | Exit evidence |
| --- | --- | --- |
| **M0: contract and scope** | MDM contract owner and React adapter owner freeze the shared SQL contract, roles, tokens, state transitions, errors, and exact fixtures. Qualify the target dependencies with R0. | Both projects approve one contract revision; M1 can implement without guessing types or authority. |
| **M1: review projection** | MDM implementation owner adds the logged policy table, retained occurrence-key mapping, masked fields, and publication-atomic updates. | Exact public rows and rollback state pass on real MDM; unlocks React R0 completion and R1 joint acceptance. |
| **M2: routing and escalation** | MDM implementation owner adds binding administration, three typed actions, receipts, manual locks, bounded deadlines/levels, and deduplication. May proceed alongside React R1 after M0/M1. | Full receipt and control-state assertions pass for duplicate, stale, unauthorized, paused, and replaced-binding calls; unlocks React R2/R3. |
| **M4: joint qualification** | Joint release owners run concurrency, restore, privilege, failure, upgrade, and end-to-end tests with React R5 at `0.50.0`. | The initial cohort passes all required cases before enablement; exact artifacts and recovery steps are recorded. |
| **M3: optional approval requirements** | MDM approval owner adds an exact-action proposal ledger, authenticated human approval API, requirement versions, and final validation. Schedule independently before React R4 at `0.51.0`. | Two required approvals mean two distinct authorized humans; self-approval, stale evidence, and requirement downgrades fail. |

Deliver M0 → M1 → M2 → M4 for the initial rollout. M3 retains its original identifier but follows its own approval gate. The released `mdm.preview()` validates or samples definitions; it does not implement M3 proposal approval.

## 6. Approval and automation safeguards

An approval covers a specific proposed action and its subjects and evidence. Capture human identity from authenticated database access or a separately trusted identity gateway. Never accept an actor string supplied by pg-react as proof of human identity. The React worker cannot supply human votes.

Reuse MDM's database-role binding checks and fixed-path privileged helpers. Its released APIs verify role names and OIDs and reject superuser/BYPASSRLS application sessions. Add a distinct automation binding and role that can submit allowed controls but cannot call human decision or override APIs. Prove this through React's actual worker execution identity, including `SET ROLE` and `SECURITY DEFINER` behavior. [1]

MDM checks approval requirements at acceptance and checks directive coherence again during publication. Changed evidence, membership, definitions, or requirements require a new review of the affected proposal. Rejecting a proposal is not the same as creating a durable `NOT_MATCH` constraint.

Automatic resolution requires a separate future capability and review. Do not implement the earlier illustrative “95% confidence” shortcut: V1 specifies evidence strengths and deterministic rules, not a calibrated probability contract. A machine policy must not acquire the manual `MATCH` operation's ability to override authoritative conflicts. Preserve cannot-link, lock, completeness, and component-integrity checks. [2]

## 7. Acceptance and recovery

| Scenario | Required result |
| --- | --- |
| Repeated request or retry after uncertain commit | One control change and one logical receipt. |
| Human changes the case while React work is queued | Stale work is rejected; manual intent is not overwritten. |
| Case closes, reopens, or changes definition | Old occurrence work cannot affect the new occurrence. |
| MDM refresh fails after a later identity decision is accepted | Previous publication stays intact; receipt remains pending, never falsely published. |
| Restore, clone, or policy replacement | New automated writes remain disabled until bindings, deduplication state, and case bases are reconciled. |
| Unauthorized or cross-scope access | No state mutation or disclosure of protected case details. |

Retain receipts, key mappings, and approval evidence for the documented replay/audit horizon. Out-of-horizon requests fail closed rather than being treated as new. A pause blocks new automated intents; accepted directives require explicit supersession to reverse them.

**First joint demonstration:** an ambiguous customer case is assigned, becomes overdue without further source edits, is escalated once, receives a human decision, and is closed only after a successful MDM publication.

Implement this demonstration in `showcase/mdm-stewardship/` with exact expected policy rows, immutable requests, receipt rows, work outcomes, and final review state. Reuse MDM's `scripts/build_e2e_image.sh`, `scripts/run_e2e_tests.sh`, `tests/e2e.sql`, `tests/restore.sql`, and upgrade/security checks. Include multi-row candidate inserts and AUTO/FULL equivalence before changing refresh safeguards. A release tag or expected-results manifest is not a passing test log.

## Sources reviewed

[1] pg-mdm `v0.11.0`, commit `97b78c8`: `README.md`, `sql/archive/pg_mdm--0.11.0.sql`, `src/api/steward.rs`, and `src/catalog.rs` in `../pg-mdm`. See the [release evidence register](../docs/planning/EVIDENCE.md#s9-pg-mdm-0110-foundation-and-missing-contract).

[2] pg-mdm `v0.11.0`: `src/output.rs`, `src/review.rs`, `src/api/describe.rs`, and `DESIGN_V1.md` in `../pg-mdm`.

[3] pg-mdm `v0.11.0`: `DESIGN_V2.md` section 12 describes future stewardship assignment and approval work.

[4] pg-mdm `v0.11.0`: `DEPENDENCIES.md`, `ROADMAP.md`, `plans/v0.11.md`, and `src/graph_spec.rs` in `../pg-mdm`.

[5] pg-trickle `v0.105.2`, commit `33df4cc9`: `docs/capability-manifest.json`, `CHANGELOG.md`, and release qualification manifest in `../pg-trickle1`. See the [release evidence register](../docs/planning/EVIDENCE.md#s8-pg-trickle-01052-release).

[6] [pg-react support matrix](../docs/support-matrix.md) and [R0 implementation plan](v0.46.0.md).

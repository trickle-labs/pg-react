# pg-react: MDM stewardship policy integration plan

**Status:** Ready for R0 compatibility work; live stewardship depends on MDM M1/M2\
**Updated:** 12 September 2026\
**Baseline:** pg-react `0.45.0`; qualify pg-trickle `0.105.2` and pg-mdm `0.11.0` plus the companion's new APIs\
**Repository:** `trickle-labs/pg-react`  
**Companion:** [pg-mdm implementation plan](PLAN_PG_MDM_STEWARDSHIP_INTEGRATION.md)  
**Proposed shared contract:** `MDM-STEWARDSHIP/1`

## 1. Goal and ownership

Provide an optional integration that turns MDM review facts into **routing decisions, deadline policies, and durable requests for MDM-controlled actions**.

Reuse pg-react's relational conditions, decisions, command work, policy sets, comparison, and explanations. Do not add a general workflow engine, a duplicate review ledger, or a second identity resolver. The existing pg-react contract explicitly excludes general workflow/BPM semantics. Human approvals and final identity decisions belong to MDM. [1][2][6]

```text
MDM policy-case relation
    -> React conditions and routing decisions
    -> React durable command work
    -> typed MDM intent API
    -> MDM receipt

Human approval -> authenticated MDM approval API, not a React worker
```

Package the integration as an optional adapter and policy example maintained in this repository. Neither core extension should acquire a mandatory dependency on the other.

## 2. Dependencies and implementation gate

Start R0 stack qualification now that pg-trickle `0.105.2` advertises stable, enabled Graph V1. Collect the released assurance evidence and pass the agreed conformance cases before dependent integration implementation. MDM `0.11.0` implements review publication but lacks the proposed policy projection and intent API. MDM M1 and M2 remain prerequisites for read-only and effectful joint qualification respectively. [4][5]

Compatibility is the first engineering task. pg-react `0.45.0` pins pg-trickle `0.98.0` and requires disabled Graph/Delta capabilities in `sql/current/pgtrickle.sql`. MDM `0.11.0` pins `0.105.1`. Update React admission, diagnostics, fixtures, and packaging for `0.105.2`, then qualify both projects on the same PostgreSQL 18 artifact. Resolve the existing PostgreSQL 18.3/18.4 image discrepancy using effective runtime identity. [3][4]

Keep React's explicit coordinator, trigger CDC, scheduler-off profile, and differential-refresh safeguard. MDM owns its EXTERNAL graph members and strict refresh transaction. An enabled Graph or Delta capability does not mean React must consume it. Test committed policy-table visibility, shared-source CDC, skipped ordinary refreshes, and FULL fallback before accepting the joint profile. Never infer successful delivery from NOTIFY or freshness metrics. [5]

The first integration reads ordinary local policy tables. It does not depend on Tide, a semantic event feed, output-delta consumption, or a prepared/resumable MDM execution path.

## 3. Shared contract and policy inputs

Treat section 4 of the [MDM plan](PLAN_PG_MDM_STEWARDSHIP_INTEGRATION.md#4-shared-interface-mdm-stewardship1) as the proposed normative contract. React implements a client, not a competing definition.

Consume the proposed `mdm_steward.policy_cases_v1` table, submit through `mdm_steward.submit_policy_intent(...)`, and read `mdm_steward.policy_receipts_v1`. Those names are proposals, not installed APIs.

MDM M1 must publish this table from released `mdm_out.<entity>_review` rows, preserve UUID review occurrences, and allocate the bigint case key. M0 must map `concurrency_version`, definition versions, decision epoch, publication revision, and evidence basis to exact intent types. React must not assemble an authoritative projection by joining MDM private catalogs. `mdm_steward.decide()` is a human directive API, not a substitute for M2 request deduplication or automation authority. [4]

Use the MDM-provided `case_key bigint` as the policy subject. Preserve the original review identity and concurrency tokens in the work snapshot. This avoids relying on broader key support than the current ordinary comparison interface provides: that interface requires one unique, non-null bigint key. [3]

Begin with one administrative scope and a non-RLS policy projection containing only authorized metadata. pg-react currently rejects RLS-protected evaluated sources. Reject unsupported deployments explicitly; do not hide an RLS source behind a view or grant `BYPASSRLS` as a workaround. Multi-tenant qualification is separate work. [3]

## 4. Initial policy package

| Policy | Inputs | Consequence |
| --- | --- | --- |
| **Route a review** | Reason code, entity type, approved business metadata, manual-assignment protection | Request an allowed queue through `ASSIGN_QUEUE`. |
| **Set a due date** | Case creation time and versioned service-window configuration | Request `SET_DUE_AT`, subject to MDM's deadline limits. |
| **Escalate an overdue review** | Open state, due date, escalation level, sampled database time | Request one `ESCALATE` action per case and configured level. |

Emit work only when the desired control value differs from current MDM state and the case permits automation. Use one active routing-policy binding per scope and explicit priority rules. Tied routing candidates produce an inspectable ambiguous result, not arbitrary assignment. A missing candidate leaves the case available for manual handling. React already distinguishes winner, ambiguous, and no-candidate decisions. [2]

For deadlines, use the supported managed deadline/temporal facilities, with a test proving time advancement alone causes evaluation. **Do not rely on a materialized condition containing `now()` refreshing without data changes.** Preserve the original deadline unless an authorized policy replacement explicitly changes it. [2]

## 5. Implementation milestones

| Milestone | Deliverables | Exit evidence |
| --- | --- | --- |
| **R0 — Stack and contract qualification** | Align the selected pg-trickle build with React's managed runtime. Approve `MDM-STEWARDSHIP/1`, supported SQL types, authorization rules, and shared fixtures. | Packaged stack passes coordination, ownership, rollback, and upgrade tests. |
| **R1 — Read-only policy package** | Add MDM condition views, routing candidates, deadline configuration, and versioned policy declarations. Use existing validate/preview/compare surfaces. | Expected routes and deadlines are explained without writing MDM state or creating real external effects. |
| **R2 — Durable intent adapter** | Add typed consequences, stable request-key generation, receipt correlation, stale-work reconciliation, and domain-outcome handling. | Repeated execution produces one MDM control change; no private access or nested MDM refresh occurs. |
| **R3 — Deadline escalation** | Wire managed time evaluation and bounded escalation levels. Prevent feedback from receipts and audit fields. | An idle overdue case escalates once; restart and retry do not duplicate the escalation. |
| **R4 — Optional approval-policy integration** | After MDM M3 is qualified, propose approval requirements within MDM's administrator-set limits. Display MDM-owned approval outcomes. | React never records human votes or bypasses MDM authorization; unsupported capabilities fail closed. |
| **R5 — Joint rollout** | Run the shared failure suite, shadow comparison, narrowly scoped enablement, dashboards, and recovery exercises. | First-release routing/escalation scope is qualified; approval support remains independently opt-in. |

Suggested new locations: `integrations/pg-mdm/` for adapter contracts and SQL, `showcase/mdm-stewardship/` for a runnable example, and `tests/integrations/pg-mdm/` for cross-project tests. Keep MDM-specific logic out of the generic rule evaluator.

Execute R0 → R1 → R2 → R3 → R5 for the first release, corresponding to pg-react `0.46.0`–`0.50.0`. Run MDM M0 alongside R0, require M1 to close R0/R1, and require M2 to qualify R2/R3. Run MDM M4 with R5. R4 remains independently gated on MDM M3 and maps to `0.51.0`. The [roadmap handoff table](../ROADMAP.md#3-approach-qualify-first-deliver-a-narrow-vertical-slice) assigns owners; each version plan retains its acceptance cases and effort budget.

## 6. Execution and retry semantics

Execute a local MDM intent call, record its receipt reference, and finish the corresponding React database work in one PostgreSQL transaction. Do not invoke `mdm.refresh()` from a consequence; MDM refresh runs independently after committed control changes. Database consequences already use transactional execution in pg-react. [1][2]

Derive a request key from a canonical, versioned encoding of:

```text
binding ID + policy revision + case occurrence + lifecycle generation
+ action-driving revision + consequence identity + escalation level
```

Persist that key and the complete request body with the work. Every retry uses the same values. Distinct intended actions need distinct keys; audit timestamps and unrelated publication changes must not manufacture new requests.

| Result | React behavior |
| --- | --- |
| `APPLIED_CONTROL` | Record successful control delivery; do not claim the identity case is resolved. |
| `ACCEPTED_PENDING_PUBLICATION` | For later decision support, show MDM acceptance separately from final publication. |
| `APPLIED_PUBLICATION` | Surface the MDM publication reference; React does not infer this from enqueue success. |
| Stale or superseded request | Record a terminal domain outcome and explicitly reevaluate current case facts; do not retry the stale payload forever. |
| Denied, invalid, or idempotency-conflict request | Stop that work, expose the reason, and require correction. |
| Transient database failure or uncertain commit | Use existing bounded retries with the same request key. |

Keep command completion distinct from business resolution. No external exactly-once guarantee is introduced. A later optional Tide adapter may deliver notifications, but network retries belong to that transport integration, not this MDM adapter. [1]

## 7. Prevent loops and unsafe policy changes

Watch only action-relevant columns. Exclude receipt timestamps, worker heartbeats, and audit-only updates; do not trigger new work solely because a publication boundary advanced. After a stale result, reevaluate using fresh MDM tokens. A changed request body creates a new work item and request key; never rewrite an attempted request or reuse its key for different arguments.

Version policy packages and preview replacements before deployment. Activate the matching MDM automation-binding policy digest in the same local deployment transaction where supported; otherwise keep the binding disabled until both sides are consistent. Withdraw or hold incompatible queued work. Execution must recheck the active binding so an old policy cannot act after replacement.

A pause prevents new intents. It does not reverse accepted MDM directives or published identities. Reversal is an explicit MDM action with its own authorization and audit.

## 8. Acceptance and rollout

Test duplicate execution, concurrent human edits, source/evidence changes, recurring reviews, ambiguous routing, time-only expiry, stale policy work, MDM publication failure, disabled bindings, missing capabilities, privileges, restore, and clone isolation.

First add one runnable end-to-end example: publish an ambiguous case, propose and apply its queue and due date, advance managed time without business writes, escalate once, accept a human decision, then independently refresh MDM to close the review. Assert exact policy rows, request bytes, receipts, React work outcomes, and final published review state. Reuse the same fixtures in both projects' release checks; a count-only assertion cannot prove that the intended case or action was processed.

Start with side-effect-free comparisons and representative cases. A bounded or `partial` comparison is not proof of complete population safety; partition a fixed test population into supported bounded comparisons or use an isolated qualification database. Preserve pg-react's documented comparison limits. [1][2]

Enable only routing and escalation for a small named cohort after tests pass. Monitor stale-intent rate, denied requests, overdue-case age, work backlog, repeated escalation attempts, and accepted-but-unpublished decisions. Retain public policy/work references needed to join MDM receipts throughout the shared audit horizon.

**First-release success:** a case is routed and escalated safely, human stewardship remains authoritative, and retries, pauses, or restarts cannot silently change identity or duplicate an intended control action.

## Sources reviewed

[1] [pg-react README](../README.md).

[2] [pg-react concepts](../docs/concepts.md).

[3] [pg-react support matrix](../docs/support-matrix.md) and [R0 implementation plan](v0.46.0.md).

[4] [MDM companion plan](PLAN_PG_MDM_STEWARDSHIP_INTEGRATION.md) and [pg-mdm 0.11.0 source evidence](../docs/planning/EVIDENCE.md#s9-pg-mdm-0110-foundation-and-missing-contract).

[5] [pg-trickle 0.105.2 source evidence](../docs/planning/EVIDENCE.md#s8-pg-trickle-01052-release).

[6] [MDM ownership and approval safeguards](PLAN_PG_MDM_STEWARDSHIP_INTEGRATION.md#6-approval-and-automation-safeguards).

# pg-react: MDM Stewardship Policy Integration Plan

**Status:** Proposal; no implementation or API compatibility promise  
**Date:** 7 September 2026  
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

Honor the chosen start policy: keep this work at specification level until the planned pg-trickle 0.97 feature-freeze milestone, or a later equivalent released build, passes the agreed upstream gate. MDM must also have working review publication and stewardship validation before the live adapter is qualified. [4][5]

**Compatibility is the first engineering task.** The current pg-react 0.43.1 support matrix qualifies pg-trickle 0.81.0, not 0.97. Do not simply change a version check. Test and, where necessary, adapt managed coordination, transaction boundaries, ownership, recovery, and upgrades against the selected Graph V1-capable build. Qualify the entire stack before enabling effects. [3]

The first integration reads ordinary local policy tables. It does not depend on Tide, a semantic event feed, output-delta consumption, or a prepared/resumable MDM execution path.

## 3. Shared contract and policy inputs

Treat section 4 of the [MDM plan](PLAN_PG_MDM_STEWARDSHIP_INTEGRATION.md#4-shared-interface-mdm-stewardship1) as the proposed normative contract. React implements a client, not a competing definition.

Consume the proposed `mdm_steward.policy_cases_v1` table, submit through `mdm_steward.submit_policy_intent(...)`, and read `mdm_steward.policy_receipts_v1`. Those names are proposals, not installed APIs.

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

Start with side-effect-free comparisons and representative cases. A bounded or `partial` comparison is not proof of complete population safety; partition a fixed test population into supported bounded comparisons or use an isolated qualification database. Preserve pg-react's documented comparison limits. [1][2]

Enable only routing and escalation for a small named cohort after tests pass. Monitor stale-intent rate, denied requests, overdue-case age, work backlog, repeated escalation attempts, and accepted-but-unpublished decisions. Retain public policy/work references needed to join MDM receipts throughout the shared audit horizon.

**First-release success:** a case is routed and escalated safely, human stewardship remains authoritative, and retries, pauses, or restarts cannot silently change identity or duplicate an intended control action.

## Sources reviewed

[1] [pg-react README: public surfaces, guarantees, and exclusions](https://github.com/trickle-labs/pg-react/blob/main/README.md).

[2] [pg-react concepts: lifecycle, decisions, transactions, temporal rules, and comparison](https://github.com/trickle-labs/pg-react/blob/main/docs/concepts.md).

[3] [pg-react support matrix: qualified upstream version, RLS, and key limits](https://github.com/trickle-labs/pg-react/blob/main/docs/support-matrix.md).

[4] [MDM roadmap: implementation gate and sequential core development](https://github.com/grove/pg-mdm/blob/main/ROADMAP.md).

[5] [pg-trickle 0.97 plan: assurance and feature freeze](https://github.com/trickle-labs/pg-trickle/blob/main/roadmap/v0.97.0.md).

[6] [MDM V2 design: stewardship ownership and published semantic state](https://github.com/grove/pg-mdm/blob/main/DESIGN_V2.md).

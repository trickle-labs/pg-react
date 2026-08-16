# M30 + M31: Applicability Foundation and Authoritative Runtime

> **Status:** Proposed milestones<br>
> **Date:** 2026-08-16<br>
> **Predecessor:** M29 / extension `0.26.0`<br>
> **M30:** Applicability foundation<br>
> **M31 proposed release:** extension `0.27.0`<br>
> **Direct upgrade:** `0.26.0 -> 0.27.0`<br>
> **Replaces:** the currently planned M30 hypothetical fact simulation milestone<br>
> **Primary outcome:** establish applicability foundation in M30, then make policy-set applicability and every ordinary façade operation authoritative, fail-closed, inspectable, and testable in M31<br>
> **Semantic scope:** complete or narrow existing M28 and M29 behavior without adding a rule language, reasoning model, simulation engine, or delivery guarantee<br>
> **Release role:** first convergence milestone on the path to a final `1.0.0` contract

---

## 1. Decision

M30 and M31 should pause semantic expansion and establish a strict product rule:

> **No public operation may report an object as deployed, gated, active, removed, explained, or ready unless the corresponding authoritative runtime behavior has occurred and is directly inspectable.**

The current roadmap assigns M30 to hypothetical fact simulation. This proposal moves simulation until after the ordinary runtime and API are coherent enough to provide a trustworthy production baseline.

The work is split into two sequential milestones:

1. **M30 — Applicability foundation.** Freeze the identity model, scope semantics, disposition matrix, relational eligibility and support schema, migrations, inspection primitives, and failing/then-passing applicability fixtures.
2. **M31 — Authoritative runtime.** Complete adapters, the global coordinator, lock ordering, lifecycle and support transitions, claimed-work revalidation, frontier and barrier semantics, race and recovery testing, and release qualification.

M31 does not freeze the final `1.0.0` API. Together, M30 and M31 create the truthful behavioral foundation that later PostgreSQL-native interface and v1 qualification milestones can safely freeze.

---

## 2. Normative language

The terms **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are normative.

- **MUST** and **MUST NOT** define release-blocking requirements.
- **SHOULD** and **SHOULD NOT** define the expected design unless the implementation contract records a stronger reason and equivalent evidence.
- **MAY** identifies optional behavior that cannot weaken a required guarantee.

---

## 3. Repository evidence motivating M30

The released `v0.26.0` artifact adds M29 policy sets and identifies hypothetical fact simulation as the next planned milestone. The current roadmap likewise lists M30 as simulation.

M28 introduced a common declaration format and an ordinary workflow of `validate`, `preview`, `deploy`, `run`, `status`, `explain`, `doctor`, and `remove`. Its inventory lists eight representative declaration kinds. In the released SQL, however, generic deployment delegates to authoritative runtime authoring only for `rule` and `decision_program`; other accepted kinds can be recorded in the façade catalog without a delegated runtime identity.

The current generic `remove` changes the declaration catalog state without removing the delegated runtime object. Generic `explain` returns status plus the supplied subject, generic `doctor` reports that the façade is available, and target-based `run` falls back to the global coordinator for non-rule targets. These operations expose useful scaffolding, but their names imply stronger object-specific behavior than the implementation performs.

M29 stores eligible subjects as a JSONB array on each policy-set version. Its `run(policy_set)` path refreshes that snapshot and returns `"gated": true`. The M29 release fixture verifies declaration validation, subject counts, subject lookup, drift detection, refresh, and removal, but it does not assert that an ineligible member match cannot create an activation, derived support, decision winner, or episode of work. The M29 evidence record explicitly identifies applicability storage as the released boundary.

M30 and M31 resolve these boundaries before they become part of the final v1 mental model.

---

## 4. Milestone outcome

M30 is complete when the identity model, scope semantics, disposition matrix, relational eligibility and support schema, migration states, inspection primitives, and exact failing/then-passing applicability fixtures are committed and independently reviewable. It does not claim complete runtime authority.

M31 is complete when all of the following statements are true:

1. **Policy-set eligibility changes authoritative runtime truth.** An ineligible subject cannot create or retain effective member truth, a current decision winner, scoped logical support, or executable work.

2. **Match identity and subject identity are separate.** A rule may be matched by `order_id` while policy applicability is determined by `customer_id`.

3. **Eligibility is relational.** Active eligibility is stored and indexed as rows using the existing typed-key codec. JSONB remains available only for bounded evidence and transport.

4. **Multiple policy sets do not duplicate work.** A member match admitted by several sets has one activation and one lifecycle. Policy sets provide scope supports for that activation.

5. **Runtime failures fail closed without fabricating business transitions.** An unavailable, unauthorized, drifted, or invalid applicability source blocks affected maintenance and execution. It does not silently use stale eligibility or reinterpret an infrastructure failure as an empty business population.

6. **Every accepted ordinary declaration kind has a complete runtime adapter.** A declaration without an authoritative adapter is rejected before durable mutation.

7. **Every ordinary verb is truthful.** `deploy`, `run`, `remove`, `status`, `explain`, and `doctor` perform or describe their documented runtime operation.

8. **The `0.26.0 -> 0.27.0` upgrade makes no silent behavioral change.** Existing M29 metadata is preserved but is not automatically converted into active runtime gating.

9. **No simulation engine is introduced.** Hypothetical facts, replay, backtesting, and arbitrary deployment-impact comparison remain outside M30 and M31.

---

## 5. Supported product model

### 5.1 Match identity

A **match identity** identifies one condition row or one decision candidate lifecycle.

The canonical declaration field becomes:

```json
"match_keys": ["order_id"]
```

`match_keys` MUST contain between one and four distinct, non-null columns supported by the existing typed-key codec.

The current `semantic_key` and `semantic_keys` forms MAY remain as compatibility aliases during the pre-v1 period. Preview MUST normalize them to `match_keys` and return a migration finding.

### 5.2 Subject identity

A **subject identity** identifies the business entity governed by policy applicability.

The canonical declaration field becomes:

```json
"subject_keys": ["customer_id"]
```

Subject identity MUST use the existing codec-v2 boundary:

- one through four ordered key components;
- `bigint`, `uuid`, or `text COLLATE "C"`;
- no null components;
- deterministic component order;
- PostgreSQL typed equality as the comparison authority.

The existing typed-key contract already supports these types and tuple sizes. M30 reuses it rather than introducing a policy-set-specific identity format.

A member MAY omit `subject_keys` only when its subject identity is exactly its match identity. If match and subject identity differ, omission MUST be a validation error.

### 5.3 Explicit scope mode

Every policy-bearing member version MUST have one immutable scope mode:

- `GLOBAL`
- `POLICY_SET_REQUIRED`

`GLOBAL` remains the default for existing versions. A global version operates independently of policy sets and MUST be rejected as a policy-set member.

`POLICY_SET_REQUIRED` means:

- raw member truth may be maintained while no set admits the subject;
- effective truth is default-deny until at least one effective policy set admits the subject;
- membership in a set never changes the member predicate, parameters, priority, consequence binding, or immutable version;
- removing the final scope support closes effective truth through the member’s ordinary lifecycle.

The scope mode is immutable because changing it changes the meaning of activations and work.

### 5.4 Scope support

A **scope support** records that one exact policy-set version currently admits the subject of one exact member match.

The effective truth of a scoped member match is:

```text
raw member truth
AND
at least one current scope support
```

A match admitted by several policy sets has several scope supports but only one effective activation.

Scope-support transitions have the following required semantics:

- `0 -> 1` support creates the normal activation generation.
- `N -> M`, where both are greater than zero, changes scope evidence but creates no activation or deactivation.
- `1 -> 0` support creates the normal deactivation transition.
- Raw payload change while support remains positive creates the normal member change revision.
- Raw truth disappearance closes the effective match regardless of the number of former scope supports.
- Reentry after the support count returned to zero creates a new activation generation.

This support model prevents duplicate work while preserving exact policy-set provenance.

### 5.5 Frozen v1 kind disposition

M30 MUST freeze the following disposition before implementation proceeds. No accepted kind may mean metadata registration without authoritative runtime behavior.

| Kind | Ordinary object disposition | Policy-set member disposition |
|---|---|---|
| constraint or command `rule` | Fully authoritative and required for v1 | Fully authoritative and required for v1 |
| `decision_program` | Fully authoritative and required for v1 | Fully authoritative and required for v1 |
| `policy_set` | Fully authoritative and required for v1 | Unsupported and fail-closed; nested sets remain outside v1 |
| `derived_program` | Supported with documented limitations through its specialized API | Supported with documented limitations and complete scope, support, retraction, recovery, and explanation evidence |
| `temporal_policy`, including deadline, cooldown, and hysteresis behavior | Supported with documented limitations through its specialized API | Supported with documented limitations and complete inherited temporal evidence |
| `effective_policy` | Supported with documented limitations through its specialized API | Supported with documented limitations and complete effective-date evidence |
| `parameter_family` and parameterized policy behavior | Supported with documented limitations through specialized APIs | Supported with documented limitations and complete parameter-selection evidence |
| `shared_condition` | Supported with documented limitations as reusable condition and applicability infrastructure | Unsupported and fail-closed as a member |
| `decision_analysis` | Unsupported as a deployable object; analysis evidence only | Unsupported and fail-closed |
| Any unlisted kind | Unsupported and fail-closed | Unsupported and fail-closed |

M30 has no experimental runtime member kind. A future experimental kind must remain outside ordinary deployment and the v1 support promise until a separate contract defines its isolation, inspection, and failure behavior.

---

## 6. Policy-set execution contract

### 6.1 Applicability declaration

M30 retains relation-backed and shared-condition-backed applicability.

The canonical shape becomes:

```sql
SELECT pgreact_api.declaration(
    'policy_set',
    'eu-review',
    jsonb_build_object(
        'version', '2',
        'members', jsonb_build_array(
            jsonb_build_object(
                'kind', 'rule',
                'name', 'manual-review-required',
                'version', '2026-08-16'
            )
        ),
        'applicability', jsonb_build_object(
            'source_kind', 'relation',
            'relation', 'app.eu_customer_gate',
            'subject_keys', jsonb_build_array('customer_id')
        ),
        'valid_from', '2026-09-01T00:00:00Z',
        'evidence_limit', 100
    )
);
```

The M29 scalar `subject_key` field MAY remain as a one-component compatibility alias. Preview MUST normalize it to `subject_keys`.

The existing M29 bounds remain in force unless M30 publishes measured replacement limits:

- at most **64 members** per policy-set version;
- at most **100,000 eligible subjects** per applicability source;
- `evidence_limit` between **1 and 1,000**.

These are support boundaries, not targets that imply the full 64-by-100,000 cross-product is inexpensive. M30 MUST publish the measured support-count envelope separately.

### 6.2 Relational eligibility storage

The JSONB `eligible_subjects` array MUST cease to be authoritative runtime state.

M30 MUST introduce a relational eligibility representation equivalent to:

```sql
policy_set_eligibility (
    policy_set_version_id uuid,
    subject_identity      bytea,
    subject_values        jsonb,
    key_codec_version     smallint,
    complete_frontier     timestamptz,
    PRIMARY KEY (policy_set_version_id, subject_identity)
)
```

The physical schema MAY differ, but it MUST provide:

- one indexed row per currently eligible subject;
- deterministic identity using the existing typed-key codec;
- exact policy-set-version ownership;
- complete-frontier evidence;
- stable dump, restore, upgrade, and rebuild behavior;
- bounded JSON rendering for public inspection;
- no requirement to parse or scan one large JSON array for an eligibility check.

`pgreact.policy_set_eligible_subjects` remains the public relational inspection boundary. It SHOULD add the canonical subject identity, ordered values, key types, and complete frontier while retaining compatibility columns where practical.

### 6.3 Applicability refresh

The normal global coordinator cycle MUST process policy applicability and member truth in one coordinated transaction:

1. acquire the existing coordinator, claim, DDL, and recovery barriers in the established order;
2. sample database time once;
3. advance applicability sources and member dependencies to compatible complete frontiers;
4. validate the applicability source identity, schema, permissions, key types, uniqueness, null behavior, row limit, and fingerprint;
5. apply the eligibility-row delta;
6. update scope supports;
7. apply member lifecycle, decision, derivation, temporal, and work transitions;
8. commit all resulting frontiers, history, lifecycle events, and episodes together.

A failure in any step MUST roll back the entire cycle.

A single committed applicability-row change SHOULD require work proportional to the affected subject and affected member matches. It MUST NOT rewrite one JSON document containing every eligible subject.

### 6.4 Valid empty population versus invalid source

A valid, complete applicability relation containing zero rows means no subjects are eligible. It therefore withdraws all scope supports supplied by that set through normal lifecycle semantics.

An invalid or unavailable source is different. The following conditions MUST establish a runtime barrier:

- source relation missing or replaced incompatibly;
- source fingerprint drift;
- missing caller or runtime privileges;
- row-level security where unsupported;
- null or duplicate subject keys;
- unsupported key type or collation;
- row count above the frozen limit;
- incomplete or unavailable source frontier.

While the barrier exists:

- no new scope support may be created;
- affected activation, change, or derivation work may not execute;
- the coordinator MUST NOT reinterpret the failure as an empty population;
- existing lifecycle state remains at its last complete frontier;
- `status` and `doctor` report `blocked`;
- repair followed by a successful coordinated run computes the exact delta from the last complete frontier.

This distinction prevents an infrastructure or authorization failure from fabricating mass business deactivations.

### 6.5 Effective dates and removal

A scope support exists only while both conditions are true:

1. the policy-set version is effective under its half-open `[valid_from, valid_to)` interval;
2. the subject is present in the applicability relation at the current complete frontier.

Policy-set expiry or removal closes supports supplied by that version. It deactivates a member match only when the removed support was its final current support.

Removing a policy set MUST NOT remove its member definitions.

Replacing a member version MUST require a new exact member binding and a new policy-set version. “Latest version” resolution is prohibited.

---

## 7. Member-kind semantics

### 7.1 Constraint and command rules

For rules, applicability filters the maintained raw match relation before effective lifecycle transitions are recorded.

A rule with:

```json
"match_keys": ["order_id"],
"subject_keys": ["customer_id"],
"scope_mode": "POLICY_SET_REQUIRED"
```

may have several order matches for one customer. Eligibility is checked by customer, while every order retains its own activation identity.

An ineligible raw match MUST remain queryable as raw condition truth through advanced inspection, but it MUST NOT appear as an effective activation or create work.

### 7.2 Temporal, deadline, cooldown, and hysteresis policies

Eligibility gates the temporal state machine.

Losing the final scope support MUST:

- close the effective generation;
- withdraw pending work according to the inherited recheck policy;
- stop or clear scoped arm, duration, deadline, cooldown, or hysteresis state as defined by the existing member contract.

Regaining eligibility starts a new eligibility interval. Time spent outside scope MUST NOT count toward a continuous-duration requirement unless the existing temporal contract explicitly defines historical accumulation.

M30 adds no new temporal operator.

### 7.3 Effective-dated and parameterized policies

A match is effective only when:

- the policy version selected by the existing effective-date contract is active;
- its parameters are valid under the existing parameter-family contract;
- at least one policy-set scope support exists.

Policy sets MUST NOT copy parameter rows, rewrite the condition, or select alternative parameter values.

### 7.4 Decision programs

Eligibility MUST be applied before a scoped subject’s authoritative winner is exposed.

A subject outside scope has the explicit state:

```text
OUT_OF_SCOPE
```

`OUT_OF_SCOPE` is distinct from:

- `NEVER_OBSERVED`;
- `NO_CANDIDATE`;
- `AMBIGUOUS`;
- a selected winner.

Entering scope recomputes the subject under the existing decision semantics. Leaving scope closes the current winner lifecycle and records the exact scope evidence.

### 7.5 Derivation programs

Applicability MUST participate at the logical-support boundary.

A gated derivation rule may create support only for an eligible subject. Removing one policy-set support removes only that scope support. A derived fact retracts only when its final valid logical support disappears.

Applicability MUST NOT be implemented by filtering the final derived relation after fixed-point evaluation, because that could retain downstream support that should no longer exist.

### 7.6 Shared conditions

A shared condition remains a valid applicability source.

A shared condition MUST no longer be accepted as a policy-set member. It is reusable condition infrastructure rather than a policy with an independent activation or consequence lifecycle.

Existing M29 declarations containing shared-condition members are preserved as legacy metadata and require explicit migration.

---

## 8. Work and execution safety

Eligibility becomes part of the existing fresh-execution recheck.

For activation and change work requiring current truth:

- `PENDING` or `RETRY_WAIT` work becomes `WITHDRAWN` when the final scope support disappears;
- claimed work that loses eligibility before invocation becomes `SKIPPED`;
- a stale lease cannot complete work after another worker has reclaimed or invalidated it;
- completed attempts and external-delivery history remain immutable;
- a later return to scope creates work only through the new activation generation or revision.

Deactivation work uses the existing desired-state and historical-event policies. Policy-set semantics MUST NOT introduce a broader “drain old work” option that bypasses a member’s fresh-eligibility contract.

Every episode created for a scoped member MUST retain enough immutable evidence to identify:

- the member version;
- match identity;
- subject identity;
- activation generation and revision;
- policy-set versions supporting the transition;
- eligibility and member frontiers;
- the recheck policy used at execution.

The engine already defines `WITHDRAWN` for pending work invalidated before claim and `SKIPPED` for a failed pre-execution recheck. M30 reuses those states.

---

## 9. Global coordinator semantics

`pgreact_api.run(sampled_time => clock_timestamp())` remains the only ordinary coordinator operation.

M13 established one globally coordinated run that advances sources, derivations, downstream rules, and database time in dependency order. M30 extends that transaction to policy applicability and scope supports.

The target overload:

```sql
pgreact_api.run(target, sampled_time)
```

MUST be reclassified as compatibility behavior.

It MUST either:

- validate the target and delegate to the complete global run while returning `summary.scope = "global"`; or
- be removed from the ordinary inventory before v1 and replaced in documentation with `run(sampled_time)`.

It MUST NOT perform target-specific behavior for some kinds and silently run the entire database for others.

M30 adds no new ordinary `refresh` or `reconcile` verb.

---

## 10. Truthful ordinary façade

### 10.1 Ordinary declaration kinds

M30 narrows the ordinary deployable kind set to objects with a complete, understandable runtime lifecycle:

- `rule`
- `decision_program`
- `policy_set`

The following remain supported through specialized advanced APIs but MUST be rejected by generic `deploy` until a complete ordinary adapter exists:

- `derived_program`
- `temporal_policy`
- `shared_condition`
- `effective_policy`
- `parameter_family`

`decision_analysis` is analysis evidence and MUST no longer be treated as a deployable runtime object.

The rejection MUST occur during `validate` and `preview`, before catalog or runtime mutation, using a stable finding such as:

```text
M30_KIND_ADVANCED_ONLY
```

The finding MUST identify the specialized supported workflow.

### 10.2 Adapter requirement

Every ordinary kind MUST have one authoritative adapter implementing:

- normalization;
- complete validation;
- preview;
- create and replacement deployment;
- authoritative removal;
- target resolution;
- status;
- explanation;
- diagnostics;
- global-run participation;
- authorization;
- migration and recovery.

The façade MUST delegate to the same internal implementation used by specialized APIs. It MUST NOT maintain parallel policy or lifecycle semantics.

### 10.3 `validate`

`validate` MUST check all prerequisites needed for successful deployment, including:

- exact object resolution;
- relation and function identities;
- key columns and types;
- action signatures and privileges;
- scope mode and subject identity;
- policy-set member compatibility;
- effective intervals;
- source fingerprints;
- RLS boundaries;
- supported runtime adapter;
- resource limits;
- replacement preconditions.

Expected declaration failures return structured findings. Unexpected infrastructure failures raise a stable SQLSTATE with `DETAIL` and `HINT`.

### 10.4 `preview`

`preview` remains read-only.

For a scoped rule or policy set, it MUST report:

- normalized declaration and digest;
- raw match count;
- eligible subject count;
- effective match count;
- gated-out match count;
- member compatibility;
- source and member frontiers;
- source fingerprints;
- bounded, deterministically ordered evidence;
- migration or runtime blockers;
- whether deployment would create, replace, or remove authoritative runtime behavior.

M30 preview does not compare arbitrary proposed rule semantics with a deployed version. That broader deployment-impact capability remains later work.

### 10.5 `deploy`

`deploy` MUST atomically create or replace the authoritative runtime object.

A successful result may report `state = "deployed"` only when:

- the immutable runtime version exists;
- all generated or maintained relations exist;
- lifecycle and scope bindings are installed;
- required frontiers are complete;
- the object is visible through public runtime inspection;
- no partial mutation survives failure.

A declaration row with a null delegated runtime identity MUST NOT be reported as deployed.

### 10.6 `remove`

`remove` MUST retire authoritative runtime behavior, not only declaration metadata.

For a policy set, removal closes its current scope supports and applies resulting lifecycle and work transitions in the same coordinated transaction.

For a rule or decision program, removal delegates to the corresponding authoritative retirement contract.

If an object cannot be authoritatively removed through the façade, `remove` MUST reject it as unsupported.

### 10.7 `status`

`status` MUST distinguish:

- declaration state;
- immutable deployed version;
- runtime state;
- health state;
- migration requirement;
- raw and effective truth counts;
- active lifecycle state;
- pending, retrying, leased, failed, withdrawn, and skipped work;
- source and applicability drift;
- complete frontiers.

It MUST NOT report `deployed` solely because an `api_declarations` row exists.

### 10.8 `explain`

`explain` MUST provide actual subject or match causality.

For a scoped rule match, the minimum evidence is:

```json
{
  "raw_match": true,
  "match_identity": {"order_id": 42},
  "subject_identity": {"customer_id": 10},
  "scope_mode": "POLICY_SET_REQUIRED",
  "eligible": false,
  "supporting_policy_sets": [],
  "effective_match": false,
  "reason": "SUBJECT_NOT_ELIGIBLE",
  "activation": null,
  "work": []
}
```

For an effective match, explanation MUST additionally identify the activation generation, revision, supporting policy-set versions, lifecycle event, requested work, and current work outcomes.

For decisions, it MUST distinguish `OUT_OF_SCOPE` from no candidate or ambiguity.

For derivations, specialized explanation remains authoritative and MUST include the scope support in the proof path.

### 10.9 `doctor`

`doctor` MUST inspect operational health.

Target diagnostics MUST cover:

- runtime adapter presence;
- source and action drift;
- applicability drift;
- incomplete frontiers;
- blocked policy sets;
- subject-key incompatibility;
- stale or invalid scope supports;
- managed-runtime readiness;
- pending migration;
- unsupported RLS;
- work that cannot pass fresh eligibility.

Reporting only that the façade exists is insufficient.

### 10.10 Read-only boundary

`validate`, `preview`, `status`, `explain`, and `doctor` MUST produce no durable mutation, job, lifecycle change, frontier movement, automatic repair, or hidden reconciliation.

A checksum covering all authoritative catalogs and runtime relations MUST remain identical before and after each read-only operation.

---

## 11. Public API impact

M28 governance requires every later milestone to justify its effect on the ordinary API. This proposal answers that requirement as follows.

### 11.1 New user goal

A PostgreSQL developer can restrict an existing policy to a typed population and trust that the population controls actual truth and work.

### 11.2 Shortest safe workflow

```text
define PostgreSQL views and functions
    -> declare scoped member
    -> validate
    -> preview
    -> deploy member
    -> declare policy set
    -> validate
    -> preview
    -> deploy set
    -> run()
    -> status / explain / doctor
```

### 11.3 Existing ordinary verbs used

M30 uses the existing verbs:

- `validate`
- `preview`
- `deploy`
- `run`
- `status`
- `explain`
- `doctor`
- `remove`

### 11.4 Declaration changes

M30 adds or canonically defines:

- `match_keys`
- `subject_keys`
- `scope_mode`
- composite applicability `subject_keys`

It narrows the deployable meaning of `kind`.

### 11.5 Result-envelope changes

M30 increments the common result contract to version **18** and adds stable sections for:

- declaration state;
- runtime state;
- raw truth;
- effective truth;
- subject identity;
- scope supports;
- runtime barriers;
- work recheck outcome;
- migration state.

### 11.6 Inspection

The capability is inspectable through existing `status`, `explain`, and `doctor` operations plus public relational views.

### 11.7 New top-level verbs

M30 adds no top-level ordinary verb.

### 11.8 Specialized APIs retained

Specialized derivation, temporal, effective-policy, parameter-family, decision-analysis, repair, retry, reconciliation, correction, finalization, retention, and recovery APIs remain supported where their safety contracts are materially distinct.

---

## 12. Compatibility and direct upgrade

### 12.1 General rule

The `0.26.0 -> 0.27.0` upgrade MUST preserve all existing durable data and immutable identities.

It MUST NOT silently activate policy-set gating for existing M29 declarations because that could create or withdraw lifecycle state and work during an extension upgrade.

### 12.2 Existing delegated rules and decisions

Existing M28 declarations with a valid authoritative delegated identity SHOULD be mapped to the M30 adapter model without changing current truth, activation generations, work, ownership, or history.

Their default scope mode is `GLOBAL`.

### 12.3 Metadata-only M28 declarations

Existing declaration rows without an authoritative runtime identity MUST be preserved with a migration state equivalent to:

```text
LEGACY_METADATA
```

`status` MUST return `attention`, not `deployed`, and provide an exact remediation path:

- deploy through the supported specialized API;
- redeclare through a complete ordinary adapter; or
- remove the obsolete declaration metadata.

The upgrade MUST NOT delete these rows or invent runtime objects for them.

### 12.4 Existing M29 policy sets

Existing M29 policy-set versions MUST be preserved with a runtime state equivalent to:

```text
NEEDS_SCOPE_MIGRATION
```

They remain inspectable as historical applicability metadata.

They MUST NOT affect member lifecycle or work until:

1. each member version has explicit `POLICY_SET_REQUIRED` scope mode and subject keys;
2. the policy set passes M30 validation;
3. a new immutable policy-set version is previewed and deployed;
4. one coordinated run establishes the initial complete scope frontier.

This migration is explicit because enabling runtime gating may create or close many activations.

### 12.5 Preservation requirements

The populated direct-upgrade fixture MUST preserve:

- rule, decision, derivation, temporal, effective, parameter, and policy-set identities;
- active matches and decision winners;
- activation generations and revisions;
- logical supports and provenance;
- frontiers, watermarks, corrections, and finalization;
- pending, leased, retrying, completed, failed, withdrawn, and skipped work;
- attempts and outbox identities;
- ownership, grants, and role boundaries;
- M28 declarations and M29 applicability evidence;
- exact recovery behavior.

---

## 13. Security model

M30 MUST grant no caller more authority than the corresponding authoritative specialized operation.

The following requirements remain release-blocking:

- `PUBLIC` receives no façade or private-catalog access.
- Every `SECURITY DEFINER` routine uses a fixed safe `search_path`.
- Applicability-source access is validated under the documented owner and runtime roles.
- Member ownership and policy-set ownership are checked independently.
- A user who may inspect set status is not automatically entitled to see subject evidence.
- Bounded subject evidence remains separately role-checked.
- Unauthorized or unavailable applicability fails closed.
- RLS-protected applicability and member sources remain unsupported unless M30 separately freezes and tests one exact evaluation-role model.
- M30 must not evaluate arbitrary declaration-supplied SQL text.
- Qualified PostgreSQL object identity remains authoritative.

---

## 14. Public relational inspection

M30 MUST retain and extend:

- `pgreact.policy_sets`
- `pgreact.policy_set_versions`
- `pgreact.policy_set_members`
- `pgreact.policy_set_eligible_subjects`

It SHOULD add stable views equivalent to:

- `pgreact.policy_set_member_status`
- `pgreact.policy_set_runtime_barriers`
- `pgreact.match_scope_supports`
- `pgreact.declaration_migrations`

The exact names are contract decisions, but the public relational model MUST make it possible to query:

- which subjects are eligible;
- which member matches are raw but out of scope;
- which matches are effectively active;
- which policy sets support one activation;
- which policy set supplied the final support that disappeared;
- which work was withdrawn or skipped because eligibility changed;
- which declarations require migration;
- which runtime barrier is preventing progress.

Fleet-wide inspection MUST not require invoking one function per target.

---

## 15. Required implementation artifacts

The M30/M31 program is incomplete without all of the following repository artifacts:

1. `docs/m30-contract.md`
2. `docs/m30-support-matrix.md`
3. `docs/m30-independent-review.md`
4. `docs/m30-evidence.md`
5. `docs/m30-readiness.md`
6. `docs/m30-upgrade.md`
7. `docs/m30-release-notes.md`
8. `docs/m30-api-inventory.json`
9. `tests/m30.sql`
10. `tests/m30.sh`
11. populated `tests/m30-upgrade-before.sql`
12. populated `tests/m30-upgrade-after.sql`
13. exact recovery, concurrency, security, and usability fixtures
14. `sql/m30.sql`
15. `sql/pg_react--0.26.0--0.27.0.sql`
16. complete `sql/pg_react--0.27.0.sql`
17. updated `ROADMAP.md`, README, support statement, release-state fixture, and API classification

Every SQL and command example in ordinary M30 documentation MUST execute in CI.

From M30 implementation onward, CI MUST maintain one continuous v1 qualification lane covering fresh installation, the populated direct upgrade from `0.26.0`, rollback-by-restore and recovery, role isolation, packaged-artifact execution, and the current performance budgets. M30 records the foundation evidence, M31 completes the runtime and release evidence, M32 continues it, and M33 consolidates it; M33 MUST NOT be the first milestone to exercise any of these matrices.

---

## 16. Milestones and implementation sequence

M30 MUST complete before M31 begins. Each milestone requires a committed contract, exact fixtures, evidence, and an independently reviewable record; façade-level or assumed behavior is not acceptable evidence.

### M30: Applicability foundation

Before authoritative runtime implementation begins:

1. freeze the v1 kind-disposition matrix, match identity, subject identity, scope mode, support semantics, schemas, indexes, limits, and migration states;
2. record the exact `0.26.0` façade and M29 behavior;
3. add the failing, then passing, applicability fixtures with exact identity, transition, support, inspection, and barrier output;
4. create the relational eligibility and scope-support stores, indexes, public views, fingerprints, bounded evidence rendering, and migration classification;
5. prove that one eligibility-row change does not rewrite a complete set snapshot.

No implementation shortcut may weaken exact expected outputs into count-only assertions.

### M31: Authoritative runtime

Implement the runtime-adapter registry and strict kind validation so unsupported kinds fail before mutation; status never infers deployment from metadata; explain and doctor delegate to authoritative implementations; referenced PostgreSQL-object rename or drift is resolved or blocked explicitly; replacement and removal close runtime, lifecycle, and work state; and target-based run has one documented global scope.

Route applicability refresh, raw and effective truth, decisions, derivations, lifecycle, work revalidation, attempts, and frontiers through the existing global coordinator with one frozen total lock order. Complete the command-rule vertical slice using `order_id` as match identity and `customer_id` as subject identity, including activation, change, deactivation, pending, retrying and leased work, overlapping sets, expiry, removal, source drift, claimed-work invalidation, crash boundaries, and repair. Then complete exact lifecycle, provenance, work, recovery, explanation, role-isolation, packaged-artifact, performance, direct-upgrade, and release-qualification fixtures for every supported member kind in the frozen matrix.

Before M31 closes, at least one reviewer who did not implement the reviewed subsystem and has PostgreSQL extension, transaction, locking, and migration expertise MUST approve the eligibility data model, total lock order, policy-set atomicity, referenced-object rename/drift behavior, replacement and removal closure, failure recovery, and direct-upgrade behavior. Publish the support matrix, limits, known cliffs, migration steps, review record, and evidence artifacts before tagging `v0.27.0`.

---

## 17. Required executable scenarios

### 17.1 Ineligible match

Given:

- order `100` belongs to customer `10`;
- the rule condition contains order `100`;
- customer `10` is absent from applicability;
- the rule is `POLICY_SET_REQUIRED`;

after `run()`:

- raw match count is `1`;
- effective match count is `0`;
- activation count is `0`;
- lifecycle-event count is `0`;
- work count is `0`;
- explanation returns `SUBJECT_NOT_ELIGIBLE`.

### 17.2 Eligibility entry

After customer `10` enters applicability and `run()` commits:

- order `100` becomes effectively active;
- activation generation is `1`;
- one activation event exists;
- the declared activation consequence creates exactly one episode;
- explanation identifies the supporting policy-set version.

### 17.3 Eligibility exit

After customer `10` leaves applicability:

- the generation closes;
- one deactivation event exists;
- pending or retrying activation work requiring current truth is withdrawn;
- a declared deactivation consequence is scheduled under the existing contract;
- completed activation work remains historical evidence.

### 17.4 Eligibility return

After customer `10` reenters applicability:

- order `100` enters generation `2`;
- refraction does not suppress the new generation;
- one new activation event and eligible work item are created.

### 17.5 Claimed-work race

A worker claims activation work.

Before invocation, the subject loses its final scope support and the coordinator commits.

Execution MUST:

- revalidate the lease;
- revalidate scope eligibility;
- skip the episode;
- invoke no consequence;
- record the exact skip reason.

### 17.6 Multiple policy sets

Two effective sets admit the same subject and member match.

The engine MUST create:

- two scope supports;
- one effective activation;
- one activation lifecycle;
- one episode per declared lifecycle consequence.

Removing one set creates no lifecycle transition. Removing the final set deactivates the match.

### 17.7 Match and subject identity differ

Two orders for one customer share one subject identity but have distinct match identities.

Eligibility entry creates two activations, one for each order. Eligibility exit closes both.

### 17.8 Valid empty source

Replacing the applicability contents with a valid empty result closes all supports through normal lifecycle semantics.

### 17.9 Invalid source

Dropping or incompatibly changing the applicability relation creates a runtime barrier.

The engine MUST:

- retain the last complete lifecycle frontier;
- execute no affected work;
- create no fabricated deactivation;
- report the exact blocker through status and doctor.

### 17.10 Decision scope

An excluded decision subject reports `OUT_OF_SCOPE`.

After entering scope, the existing candidate-selection and ambiguity semantics apply unchanged.

### 17.11 Derivation scope

A derived fact with two supports remains true when one scoped support disappears and retracts only when its final support disappears.

### 17.12 Authoritative removal

Removing a rule, decision, or policy set through the generic façade changes authoritative runtime state. Updating only declaration metadata fails the test.

### 17.13 Unsupported declaration kind

Generic deployment of an advanced-only kind returns a stable blocker and leaves the complete authoritative checksum unchanged.

### 17.14 Upgrade

A populated `0.26.0` database upgrades to `0.27.0` with:

- no lost data;
- no new activation;
- no withdrawn work;
- no policy-set gating activated automatically;
- explicit migration findings for legacy metadata and M29 sets.

---

## 18. Concurrency and recovery gates

M30 MUST test at least these races:

- eligibility insertion racing with member-match insertion;
- eligibility deletion racing with activation-work claim;
- policy-set removal racing with execution;
- two policy sets concurrently adding support for the same match;
- removal of one support racing with creation of another;
- member replacement racing with policy-set deployment;
- applicability drift racing with a coordinator cycle;
- restart after eligibility rows commit but before lifecycle state commits;
- lease expiry racing with scope invalidation;
- standby promotion with blocked and active policy sets.

The tests MUST prove atomic agreement among:

- eligibility rows;
- scope supports;
- effective truth;
- activation state;
- lifecycle events;
- derived supports;
- decision winners;
- agenda episodes;
- attempts;
- frontiers;
- public explanations.

Crash, restore, failover, and upgrade MUST either preserve that agreement or establish the existing explicit reconciliation barrier before normal work resumes.

---

## 19. Performance and storage gates

M30 makes no universal throughput claim.

The release MUST publish measurements for the exact supported hardware, PostgreSQL configuration, pg_trickle version, member count, raw match count, eligible-subject count, support count, and change pattern.

The implementation MUST demonstrate:

- indexed subject lookup;
- indexed member-to-subject matching;
- no authoritative JSON-array containment scan;
- no single-row JSON rewrite for an eligibility delta;
- deterministic bounded evidence;
- bounded coordinator memory;
- bounded failure diagnostics;
- no duplicate materialization of member predicates;
- no second evaluation engine;
- no full recomputation for a one-subject change when the underlying maintained relations provide a usable delta.

The existing **64-member**, **100,000-subject**, and **1-to-1,000 evidence-page** limits remain publication limits until the release evidence records an intentional replacement.

The M30 support statement MUST also publish the measured maximum active scope-support count. Deployment or runtime maintenance MUST fail with an actionable resource finding before crossing that bound.

---

## 20. Documentation and usability gates

A PostgreSQL developer unfamiliar with pg-react internals MUST be able to complete this task using only ordinary documentation:

1. create a condition view;
2. create a typed action function;
3. declare a rule matched by `order_id` and scoped by `customer_id`;
4. create an eligibility table;
5. deploy the scoped rule and policy set;
6. run the coordinator;
7. inspect one admitted and one excluded order;
8. explain why the excluded order produced no work;
9. remove the customer from scope;
10. verify the resulting lifecycle and work state.

The reference workflow MUST:

- require no private catalog access;
- require no UUID as author input;
- require no milestone-specific terminology;
- use one global `run()`;
- contain copy-and-run SQL;
- complete without maintainer interpretation;
- execute in CI with exact expected output.

Before M31 closes, the project MUST recruit at least five PostgreSQL developers who did not implement the API for the M32 usability cohort. At least two SHOULD review the M32 golden-path transcript or an executable prototype during M31 so conceptual feedback can change the interface before it freezes. M31 records that design feedback and the measurement method; M32 and final v1 qualification own their release thresholds.

---

## 21. Explicit non-goals

M30 does not add:

- hypothetical fact simulation;
- arbitrary deployment-impact comparison;
- historical replay;
- comparative backtesting;
- why-changed comparison across arbitrary frontiers;
- nested policy sets;
- Boolean or hierarchical gate expressions;
- ordered policy-set precedence;
- cross-database applicability;
- RLS support without a separate frozen contract;
- a custom rule or policy DSL;
- generated SQL predicates;
- visual or AI authoring;
- client SDKs;
- synchronous consequence execution;
- new decision-selection semantics;
- new temporal operators;
- unstratified negation;
- recursive aggregation;
- arbitrary tuple lineage;
- exactly-once external effects;
- automatic repair;
- a final `1.0.0` compatibility promise.

---

## 22. Risks and mitigations

### Risk: policy-set deployment unexpectedly suppresses existing rules

**Mitigation:** require immutable `POLICY_SET_REQUIRED` scope mode. Global versions cannot be added to a policy set. Existing M29 sets require explicit migration and cannot change runtime behavior during upgrade.

### Risk: several policy sets create duplicate work

**Mitigation:** represent each set as a scope support for one member activation. Lifecycle transitions occur only when total support crosses zero.

### Risk: source failure causes mass deactivation

**Mitigation:** distinguish a valid empty population from an invalid source. Invalid sources establish a runtime barrier and preserve the last complete lifecycle frontier.

### Risk: scope filtering breaks derivation correctness

**Mitigation:** apply scope at logical-support production, not as a filter over final derived facts. Require exact multi-support and retraction fixtures.

### Risk: façade cleanup breaks pre-v1 callers

**Mitigation:** preserve historical rows, expose migration status, retain specialized APIs, and provide a populated direct upgrade. Do not continue reporting metadata-only objects as deployed merely for compatibility.

### Risk: M30 becomes too broad

**Mitigation:** prohibit simulation and new reasoning semantics. Implement one command-rule vertical slice first, then require every remaining adapter to prove equivalence through shared internal primitives.

### Risk: composite identity introduces another codec

**Mitigation:** reuse the existing M15 codec v2 without adding new scalar types, nullable components, or key arity.

### Risk: target-based `run` remains ambiguous

**Mitigation:** restore global `run(sampled_time)` as the only ordinary coordinator operation. Mark the target overload as global compatibility behavior or remove it from ordinary documentation.

---

## 23. Release-blocking exit gates

M31 may publish as `v0.27.0` only when every gate below passes.

### 23.1 Runtime gating gate

An ineligible subject cannot create or retain effective member truth, a winner, scoped derived support, or executable work.

### 23.2 Identity gate

Composite match and subject identities work independently for all supported key types and arities.

### 23.3 Multi-set gate

Several sets supporting one match create one lifecycle and no duplicate work.

### 23.4 Work-safety gate

Pending, retrying, leased, skipped, withdrawn, completed, and failed work follow the exact inherited recheck semantics after eligibility changes.

### 23.5 Façade-truth gate

Every ordinary kind has a complete runtime adapter. Unsupported kinds are rejected before mutation. No operation reports runtime state from declaration metadata alone.

### 23.6 Removal gate

Generic removal retires authoritative runtime behavior and applies required scope, lifecycle, and work transitions atomically.

### 23.7 Inspection gate

Status, explanation, doctor, and public views agree exactly on raw truth, effective truth, subject eligibility, scope supports, lifecycle, work, barriers, and migration state.

### 23.8 Read-only gate

Validation, preview, status, explanation, and doctor preserve the exact authoritative checksum.

### 23.9 Security gate

No generic operation widens authority, bypasses object ownership, leaks protected evidence, uses an unsafe search path, or accepts unsupported RLS.

### 23.10 Concurrency gate

All required eligibility, member, claim, replacement, and removal races preserve atomic runtime agreement.

### 23.11 Recovery gate

Crash, restart, physical restore, logical restore, standby promotion, reconciliation, and retention preserve or explicitly restore eligibility, scope, lifecycle, provenance, work, and frontier agreement.

### 23.12 Upgrade gate

The populated direct `0.26.0 -> 0.27.0` upgrade preserves all existing state and performs no silent scope activation.

### 23.13 Performance gate

The measured supported envelope is published, single-subject changes use indexed relational state, and no authoritative JSON-array scan remains.

### 23.14 Documentation gate

Every ordinary example executes in CI, and an independent PostgreSQL developer can complete the scoped-rule workflow without private knowledge.

### 23.15 Independent-review gate

The required PostgreSQL extension, transaction, locking, migration, lifecycle, recovery, and direct-upgrade review is complete, every blocking finding is resolved, and the M32 usability cohort is recruited.

### 23.16 Continuous-qualification gate

Fresh install, populated direct upgrade, rollback-by-restore and recovery, role-isolation, packaged-artifact, and performance-budget evidence has remained green from M30 through every applicable M31 gate.

### 23.17 Inherited-evidence gate

Every M0 through M29 release gate passes unchanged against the exact `0.27.0` artifact.

---

## 24. Roadmap after M31

Approval of this proposal changes the immediate sequence to:

1. **M30: Applicability Foundation**<br>
   Freeze and implement the identity model, scope semantics, disposition matrix, relational eligibility and support schema, migrations, inspection primitives, and exact applicability fixtures.

2. **M31: Authoritative Runtime**<br>
   Complete policy-set execution, authoritative adapters, global coordination, lock ordering, lifecycle and support transitions, claimed-work revalidation, frontier and barrier semantics, race and recovery testing, and release qualification.

3. **M32: PostgreSQL-Native Interface**<br>
   Add typed constructors, relational diagnostics, final vocabulary, one public schema strategy, richer preview, migration-oriented export, and copy-and-run workflows.

4. **M33: V1 Qualification and Compatibility Freeze**<br>
   Freeze the v1 compatibility matrix, documentation, upgrade path, packaging, performance envelope, deprecations, and external usability evidence in `0.29.0`.

5. **Version 1.0.0 release-candidate cycle**<br>
   Publish at least one exact `1.0.0-rc.N` packaged artifact and qualify both fresh installation and populated upgrade from `0.26.0`; any fix requires a new candidate and affected evidence rerun.

6. **Version 1.0.0**<br>
   Promote only a fully qualified release candidate, with no capability or semantic change.

7. **Post-v1 simulation sequence**<br>
   Introduce hypothetical facts, deployment comparison, replay, backtesting, and why-changed analysis on top of the frozen runtime model.

---

## 25. First implementation change

The first M30 change MUST be a failing applicability fixture, not a catalog migration.

The test must establish:

```text
one raw rule match
+ one ineligible subject
= zero effective activations
+ zero lifecycle events
+ zero work
```

It must then add eligibility and prove generation `1`, remove eligibility and prove deactivation plus work withdrawal, restore eligibility and prove generation `2`, and finally invalidate eligibility after claim to prove a skipped execution.

M30 implementation begins only after the exact expected transcript for that fixture is reviewed and frozen. M31 begins only after the M30 contract, schema, migration, inspection, and fixture evidence is complete.

---

## 26. Approval criterion

This proposal should be approved only if maintainers agree to the following priority:

> **Before pg-react learns to simulate hypothetical worlds, its ordinary API and policy sets must describe the real world exactly.**

Approval authorizes replacing the current M30 roadmap entry with M30 and M31, creating the normative foundation and runtime contracts, and beginning with the failing applicability fixture defined above.

# Evidence, provenance, and unresolved inputs

> Prepared 9 September 2026. Repository information was read through the connected GitHub source. No PostgreSQL integration test was run while preparing these plans.

## How to read the documents

**Source requirement** means the attached proposal requires the behavior. **Verified baseline** means an inspected repository document reports it; this is not an independent runtime verification. **Proposed design** means the release sequence, budgets, tasks, acceptance-test design, file layout, or scope choice introduced by these documents. Future APIs remain proposals until their owning project publishes and qualifies them.

All roadmap versions and all 30-person-day estimates are proposed. The six releases are not statements about commitments already made in GitHub. Test names and new repository paths are intended implementation targets, not claims that files or tests exist today.

## S0 — User-supplied integration proposal

[pg-react: MDM Stewardship Policy Integration Plan](sources/PLAN_PG_REACT_MDM_STEWARDSHIP.md), dated 7 September 2026. The original supplied filename was `PLAN_PG_REACT_MDM_STEWARDSHIP(1).md`; the copy included here is byte-for-byte unchanged.

SHA-256: `2f6e90e7ba1403936cad3768a417d07e9560f68b7cf9c38c81d1d9e8e7675598`.

Sections 1–3 establish ownership, optional packaging, the upstream start gate, local-table inputs, the proposed MDM contract, bigint case identity, and the initial non-RLS scope. Sections 4–5 define policies and R0–R5. Sections 6–8 define transactional delivery, immutable request identity, domain outcomes, replacement, anti-feedback behavior, and rollout evidence.

**Missing companion:** `PLAN_PG_MDM_STEWARDSHIP_INTEGRATION.md` was not supplied. Retrieval at the checked `trickle-labs/pg-mdm` repository root returned not found; the older `grove/pg-mdm` paths did not return readable content. This does not establish that the companion exists nowhere. The copied source intentionally retains its original unresolved relative companion link. Acquire the approved companion or an explicitly superseding contract before implementing the client.

## S1 — pg-react release manifest

[Current release manifest at v0.45.0](https://github.com/trickle-labs/pg-react/blob/v0.45.0/docs/current-release.json).

Observed content blob: `eb2a2cdde2b583d1838aadfb577e39f3f48351c9`.

It reports extension `0.45.0`, PostgreSQL `18.4`, pg_trickle `0.98.0`, pgrx `0.18.0`, Rust `1.89.0`, Linux/amd64, `READ COMMITTED`, trigger CDC, scheduler off and explicit pg-react coordination. Graph V1 and Delta V1 are discovered but disabled and unused. The pinned runtime digest reports PostgreSQL 18.3, with 18.4 image identity unresolved. Treat this as an open qualification issue, not a new proven support claim.

## S2 — pg-react supported boundary

[Support matrix at v0.45.0](https://github.com/trickle-labs/pg-react/blob/v0.45.0/docs/support-matrix.md).

Observed content blob: `f253832215788b3deaf542641f268c13b61bdd81`.

The matrix rejects RLS evaluated sources, limits ordinary rule comparison to one unique non-null bigint key, distinguishes supported runtime acceptance from qualification, and excludes Graph V1, Delta V1, WAL CDC and scheduler execution from the current qualified integration. Coordinated differential refresh requires `pg_trickle.differential_max_change_ratio=1.0`.

## S3 — pg-react compatibility fixture

[pg_trickle compatibility fixture at v0.45.0](https://github.com/trickle-labs/pg-react/blob/v0.45.0/tests/fixtures/v0.45.0/pgtrickle-compatibility.json).

Observed content blob: `fed304c07822d26ba3d724b2f558f6d6647e2017`.

Both `external_graph_refresh` and `output_delta_consumer` have major 1, minor 0, `enabled=false`, and experimental status. The fixture identifies the 0.98 FULL-refresh fallback/row-trigger interaction and the qualified change-ratio setting. Preserve the associated lifecycle regression when the upstream artifact changes.

## S4 — pg_trickle 0.98 containment plan

[Roadmap v0.98.0](https://github.com/trickle-labs/pg-trickle/blob/main/roadmap/v0.98.0.md), marked released when inspected.

Observed content blob: `580fc98ac5c0fd716e7da2ca36881af3209ee48c`.

The plan keeps trigger capture stable and disables Graph V1 and Delta V1 throughout 0.98.x. Admission must fail before mutation. It explicitly defers graph execution repairs and complete extension conformance to later versions. A function's presence is not permission to use it.

## S5 — pg_trickle extension conformance plan

[Roadmap v0.104.0](https://github.com/trickle-labs/pg-trickle/blob/main/roadmap/v0.104.0.md), marked planned when inspected.

Observed content blob: `4ab7385dd6ad4e9e00febb84f9b513f0487f55cb`.

The plan requires independent Graph V1 and Delta V1 conformance suites, public-contract-only reference implementations, and rollback, replay, invalidation, retention, restore, clone, ownership and upgrade evidence. It permits stable admission only after the corresponding suite passes; otherwise the disabled status remains. No release date or enabled capability is established by this plan.

## S6 — MDM readiness and graph ownership

[pg-mdm V1 roadmap](https://github.com/trickle-labs/pg-mdm/blob/main/ROADMAP.md), first 90 lines inspected.

Observed content blob: `9a8983fe8dd833488e7332165291823c563ccf55`.

The repository is described as design-only. The V1 roadmap develops a full-reference resolver and publication model before gated live graph integration. It explicitly excludes Delta V1 from V1 and expects disabled 0.98 capabilities. Its proposed graph integration uses public contracts, external orchestration and disabled initialization. This roadmap does not establish delivery of the separate `MDM-STEWARDSHIP/1` intent API or the proposal's M3 approval milestone.

## S7 — Existing React semantics and versioning

[Concepts at v0.45.0](https://github.com/trickle-labs/pg-react/blob/v0.45.0/docs/concepts.md). Observed content blob: `e476f5d32bed9ef201ddab95a4acc32e7593c548`.

The inspected concepts describe typed declarations, generation/revision identity, watched-column control, transactional database consequences, lowest-numeric-priority decisions with `WINNER`/`AMBIGUOUS`/`NO_CANDIDATE`, installed advanced temporal/deadline APIs, and bounded read-only comparison. Comparison does not create lifecycle state, work, attempts, delivery, or frontier advancement; its selected-state checksum is not a complete system-state proof.

[Versioning at v0.45.0](https://github.com/trickle-labs/pg-react/blob/v0.45.0/docs/versioning.md). Observed content blob: `ac27f6d2f6320d526a0ed5d704746f00a1bdfd06`.

Adjacent 0.x releases preserve valid ordinary calls by project policy. Incompatible ordinary changes require an explicit compatibility decision and migration path. The extension version, release manifest, container defaults and documentation must agree. Version 1.0 is postponed indefinitely.

## Decisions that must not be guessed

| Unresolved input | Required owner and resolution | Deadline |
|---|---|---|
| Exact `MDM-STEWARDSHIP/1` contract | MDM owner supplies normative revision, SQL types/signatures, version negotiation and fixtures | Before 0.46.0 completion |
| Released enabled Graph V1 artifact | Upstream owner supplies artifact and conformance evidence; React/MDM rerun independent cases | Before implementation under the retained source start policy |
| Effective PostgreSQL image/version | Release owner resolves 18.3/18.4 discrepancy, then qualifies exact stack | Before 0.46.0 completion |
| Case occurrence and action-driving revision | MDM owner defines stable identity, recurrence, revision changes and token invalidation | Before immutable request-key codec is frozen |
| Idempotency scope and audit horizon | Joint owners define duplicate behavior, key retention and restore/clone policy | Before 0.48.0 live admission |
| Binding replacement/pause linearization | MDM owner supplies transactional authorization/precondition semantics | Before 0.48.0 race tests can pass |
| Supported managed temporal entry point | React runtime owner maps installed API and proves time-only reevaluation | Before 0.49.0 implementation is committed beyond its audit task |
| Approval semantics and M3 evidence | MDM owner publishes independently qualified approval capability | Before 0.51.0 starts |
| Named cohort and numerical operating budgets | Operator and release owner approve representative workload and limits | Before 0.50.0 qualification begins |

A required unresolved input is a blocked gate. The plans describe what to do when it becomes available; they do not replace the missing contract with plausible SQL.

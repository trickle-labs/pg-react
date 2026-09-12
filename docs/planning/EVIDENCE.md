# Evidence, provenance, and unresolved inputs

> Updated 12 September 2026 from the local `pg-react`, `../pg-trickle1`, and `../pg-mdm` repositories. S1–S7 retain the earlier baseline where identified. S8–S9 record the released dependency sources. No PostgreSQL integration suite was run for this documentation update; downloaded release logs and joint runtime evidence remain R0 deliverables.

## How to read the documents

**Source requirement** means the attached proposal requires the behavior. **Verified baseline** means an inspected repository document reports it; this is not an independent runtime verification. **Proposed design** means the release sequence, budgets, tasks, acceptance-test design, file layout, or scope choice introduced by these documents. Future APIs remain proposals until their owning project publishes and qualifies them.

All roadmap versions and all 30-person-day estimates are proposed. The six releases are not statements about commitments already made in GitHub. Test names and new repository paths are intended implementation targets, not claims that files or tests exist today.

## S0 — User-supplied integration proposal

[pg-react stewardship plan](../../plans/PLAN_PG_REACT_MDM_STEWARDSHIP.md) and [MDM companion plan](../../plans/PLAN_PG_MDM_STEWARDSHIP_INTEGRATION.md), originally dated 7 September and updated with this roadmap. These are the maintained plans, not immutable copies of the original proposal.

Sections 1–3 establish ownership, optional packaging, the upstream start gate, local-table inputs, the proposed MDM contract, bigint case identity, and the initial non-RLS scope. Sections 4–5 define policies and R0–R5. Sections 6–8 define transactional delivery, immutable request identity, domain outcomes, replacement, anti-feedback behavior, and rollout evidence.

The companion is present in `plans/`. Its section 4 supplies the proposed shared contract. Exact SQL signatures, types, permissions, and fixtures still require MDM M0 agreement and M1/M2 implementation. The old `docs/planning/` plan path redirects to the maintained React plan.

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

## S5 — Historical pg_trickle extension conformance plan

[Roadmap v0.104.0](https://github.com/trickle-labs/pg-trickle/blob/main/roadmap/v0.104.0.md), marked planned when inspected.

Observed content blob: `4ab7385dd6ad4e9e00febb84f9b513f0487f55cb`.

The plan requires independent Graph V1 and Delta V1 conformance suites, public-contract-only reference implementations, and rollback, replay, invalidation, retention, restore, clone, ownership and upgrade evidence. This September 9 observation is historical. Use S8 for released capability availability and rerun the applicable cases for the joint stack.

## S6 — MDM readiness and graph ownership

[pg-mdm V1 roadmap](https://github.com/trickle-labs/pg-mdm/blob/main/ROADMAP.md), first 90 lines inspected.

Observed content blob: `9a8983fe8dd833488e7332165291823c563ccf55`.

The earlier design-only assessment is superseded by the released `0.11.0` implementation in S9. MDM owns its graph, full-entity resolver, stewardship validation, and publication. The separate `MDM-STEWARDSHIP/1` intent API and M3 approval work are still absent.

## S7 — Existing React semantics and versioning

[Concepts at v0.45.0](https://github.com/trickle-labs/pg-react/blob/v0.45.0/docs/concepts.md). Observed content blob: `e476f5d32bed9ef201ddab95a4acc32e7593c548`.

The inspected concepts describe typed declarations, generation/revision identity, watched-column control, transactional database consequences, lowest-numeric-priority decisions with `WINNER`/`AMBIGUOUS`/`NO_CANDIDATE`, installed advanced temporal/deadline APIs, and bounded read-only comparison. Comparison does not create lifecycle state, work, attempts, delivery, or frontier advancement; its selected-state checksum is not a complete system-state proof.

[Versioning at v0.45.0](https://github.com/trickle-labs/pg-react/blob/v0.45.0/docs/versioning.md). Observed content blob: `ac27f6d2f6320d526a0ed5d704746f00a1bdfd06`.

Adjacent 0.x releases preserve valid ordinary calls by project policy. Incompatible ordinary changes require an explicit compatibility decision and migration path. The extension version, release manifest, container defaults and documentation must agree. Version 1.0 is postponed indefinitely.

## S8: pg-trickle 0.105.2 release

Inspected tag `v0.105.2`, commit `33df4cc91fda4fbadba79470347a714c8509703a`, in `../pg-trickle1`. Inspect release-tag files rather than assuming later `main` changes shipped.

| Source at the tag | Finding and planning consequence |
|---|---|
| [Capability manifest](https://github.com/trickle-labs/pg-trickle/blob/33df4cc91fda4fbadba79470347a714c8509703a/docs/capability-manifest.json) | `external_graph_refresh`, `output_delta_consumer`, `trigger_cdc`, and `wal_cdc` advertise major 1, minor 0, stable, enabled. Remove the old release-availability wait. |
| [Release SQL](https://github.com/trickle-labs/pg-trickle/blob/33df4cc91fda4fbadba79470347a714c8509703a/sql/archive/pg_trickle--0.105.2.sql) and [integration implementation](https://github.com/trickle-labs/pg-trickle/blob/33df4cc91fda4fbadba79470347a714c8509703a/src/api/integration.rs) | `pgtrickle.refresh_graph_strict(regclass[], bytea, text)` returns graph identity, source boundary/digest, and node results within the caller transaction. MDM owns this operation. |
| [SQL reference](https://github.com/trickle-labs/pg-trickle/blob/33df4cc91fda4fbadba79470347a714c8509703a/docs/SQL_REFERENCE.md) | EXTERNAL graph members reject ordinary manual refresh and IMMEDIATE mode. Member ownership and source ownership or delegated USAGE/SELECT/MAINTAIN are required. Locks survive to caller commit/rollback. |
| [Refresh operations](https://github.com/trickle-labs/pg-trickle/blob/33df4cc91fda4fbadba79470347a714c8509703a/src/api/refresh_ops.rs) | Ordinary refresh can report a concurrent skip as NOTICE. `write_and_refresh` is not a guaranteed write-visibility barrier; `freshness()` and NOTIFY are not durable completion receipts. |
| [Changelog](https://github.com/trickle-labs/pg-trickle/blob/33df4cc91fda4fbadba79470347a714c8509703a/CHANGELOG.md) and [qualification contract](https://github.com/trickle-labs/pg-trickle/blob/33df4cc91fda4fbadba79470347a714c8509703a/tests/release/v0.105.2-qualification.json) | `.1` to `.2` changes packaging, qualification, and upgrade metadata, with no `src/` changes. The contract lists expected results; retain actual release logs before claiming they passed. 72-hour soak and seven-day longevity remain deferred. |

Shared source CDC is an upstream buffer implementation, not an independent public raw-source consumer contract. Test the committed policy-table path and refresh interleavings; do not add a private buffer consumer. Keep trigger CDC and scheduler off as the initial joint profile even though upstream supports additional profiles.

Reproduce tag identity with `rtk git -C ../pg-trickle1 rev-parse 'v0.105.2^{commit}'`. Compare `.1` and `.2` with `rtk git -C ../pg-trickle1 diff --stat v0.105.1 v0.105.2`. The links above pin the inspected release commit; use `rtk git -C ../pg-trickle1 show v0.105.2:<path>` when the checkout advances.

## S9: pg-mdm 0.11.0 foundation and missing contract

Inspected tag `v0.11.0`, commit `97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d`, in `../pg-mdm`. The local checkout has a later cleanup commit; the release SQL and implementation cited below are unchanged.

| Source at the tag | Finding and planning consequence |
|---|---|
| [Dependencies](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/DEPENDENCIES.md) | Qualifies pg-trickle `0.105.1`, commit `5bfdea89bbcca2bf6d606ddbf034b62eddf3b2ae`, on PostgreSQL 18.4 runtime. The documented build `pg_config` is 18.6. Record build and runtime identities separately and rerun against `0.105.2`. |
| [Release SQL](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/sql/archive/pg_mdm--0.11.0.sql) | Ships `mdm.describe`, `mdm.explain`, `mdm.preview`, `mdm.refresh`, `mdm_steward.decide`, and golden-override operations. No policy projection, intent, binding, receipt, or approval-proposal API exists. |
| [Output schemas](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/src/output.rs) and [review reconciliation](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/src/review.rs) | `mdm_out.<entity>_review` has UUID identity, occurrence, status, masked facts, and concurrency/publication revisions. Recurrence allocates a new UUID. M1 must add the persistent bigint mapping and administrative fields. |
| [Description API](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/src/api/describe.rs) | Public definition versions, decision epoch, publication revision, and `pending_stewardship` are available. Pending state includes no-change publication observations. M0 must define the policy-specific token mapping. |
| [Steward APIs](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/src/api/steward.rs) and [role checks](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/src/catalog.rs) | Bind actual database roles by name and OID, reject superuser/BYPASSRLS application identities, and audit accepted directives. No caller request-key deduplication exists. M2 needs a distinct restricted automation role/API. |
| [Graph specification](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/src/graph_spec.rs) | Candidate-pair nodes deliberately use FULL because of multi-row pair-insert loss on `0.105.1`. Preserve this workaround on `0.105.2` until exact-output equivalence proves it unnecessary. |
| [Qualification plan](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/plans/v0.11.md), [E2E runner](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/scripts/run_e2e_tests.sh), and [roadmap](https://github.com/trickle-labs/pg-mdm/blob/97b78c82c0310cf750cd3e1b783a3ed35a2c9f1d/ROADMAP.md) | Reuse cumulative Graph, publication, roles, concurrency, restore, upgrade, and package checks. Numbered plans stop at `0.11`; M0–M4 are additional work, with no promised later MDM version. |

Reproduce tag identity with `rtk git -C ../pg-mdm rev-parse 'v0.11.0^{commit}'`; read pinned sources with `rtk git -C ../pg-mdm show v0.11.0:<path>`. Local source inspection establishes what shipped, not that this new three-extension stack passed qualification.

## Decisions that must not be guessed

| Unresolved input | Required owner and resolution | Deadline |
|---|---|---|
| Exact `MDM-STEWARDSHIP/1` contract | MDM owner supplies normative revision, SQL types/signatures, version negotiation and fixtures | Before 0.46.0 completion |
| Joint `0.105.2` artifact qualification | Release availability is established; upstream liaison archives release assets/logs and joint owners rerun independent cases | R0 starts now; conformance precedes dependent integration implementation |
| Effective PostgreSQL image/version | Release owner resolves 18.3/18.4 discrepancy, then qualifies exact stack | Before 0.46.0 completion |
| MDM post-0.11 delivery | MDM owner estimates and schedules M0/M1/M2/M4 separately from React; M1 is absent in the base release | M1 before R0/R1 completion, M2 before R2/R3 live qualification |
| Case occurrence and action-driving revision | MDM owner defines stable identity, recurrence, revision changes and token invalidation | Before immutable request-key codec is frozen |
| Idempotency scope and audit horizon | Joint owners define duplicate behavior, key retention and restore/clone policy | Before 0.48.0 live admission |
| Binding replacement/pause linearization | MDM owner supplies transactional authorization/precondition semantics | Before 0.48.0 race tests can pass |
| Supported managed temporal entry point | React runtime owner maps installed API and proves time-only reevaluation | Before 0.49.0 implementation is committed beyond its audit task |
| Approval semantics and M3 evidence | MDM owner publishes independently qualified approval capability | Before 0.51.0 starts |
| Named cohort and numerical operating budgets | Operator and release owner approve representative workload and limits | Before 0.50.0 qualification begins |

A required unresolved input is a blocked gate. The plans describe what to do when it becomes available; they do not replace the missing contract with plausible SQL.

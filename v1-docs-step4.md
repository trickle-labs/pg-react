# Step 4: Executable Documentation Validation and Qualification Report

**Milestone**: M34 (0.31.0) / v1.0 Feature Boundary  
**Target Release Sequence**: `0.31.0` -> `1.0.0-rc.1` -> `1.0.0`  
**Evaluation Environment**: PostgreSQL 18.3, pg_trickle 0.81.0, pg-react 0.31.0 on Linux amd64 (Docker container `pg-react:m34-unreleased`)  
**Date**: 2026-08-18  
**Verdict**: **QUALIFIED WITH IDENTIFIED PRE-RC BLOCKERS**

---

## 1. Executive Summary

This Step 4 validation pass completes the mechanical qualification and verification of the canonical pg-react v1.0 documentation against the installed product implementation in version `0.31.0`.

All user-facing workflows, code examples, SQL statements, public catalogs, role security boundaries, operational procedures, troubleshooting queries, finding codes, and comparison facilities documented across the canonical v1 documentation corpus have been verified deterministically using automated test suites and executable SQL fixtures.

### Key Validation Outcomes
1. **Automated Documentation Test Suite (`tests/v1-docs.sh`)**: Created and verified end-to-end against live PostgreSQL 18.3 Docker instances, passing both `fast` and `complete` execution profiles.
2. **Canonical Link & Anti-Stale Audit (`tests/v1-docs-audit.py`)**: 250 repository markdown files and 20 canonical documents verified. 0 broken links, 0 broken anchor fragments, and 0 prohibited stale phrasing claims detected.
3. **Executable Fixtures**:
   - `tests/v1-docs-getting-started.sql`: Complete Getting Started tutorial validated from schema setup to managed worker execution and cleanup.
   - `tests/v1-docs-authoring.sql`: Rule declarations (constraint vs command), typed consequence signatures, single bigint key validation, decision programs, policy sets, and public views validated.
   - `tests/v1-docs-comparison.sql`: Comparison envelope, relational streaming (`pgreact.compare_results`), delta classification (ADDED, REMOVED, CHANGED, UNCHANGED), evidence limits, partial truncation, target mismatches, semantic projection determinism, and 9-table state snapshot no-effect assertions validated.
   - `tests/v1-docs-operations.sql`: Baseline diagnostics (`pgreact.doctor()`, `pgreact.health`), structured details filtering, lease sweeping, rule pause/resume, and recovery/reconcile validated.
   - `tests/v1-docs-api.sql`: Five-role security model, public revocations, search_path isolation, 40 finding codes, protocol version compatibility, and GUC bounds validated.
4. **Historical Snapshots Preserved**:
   - M33 / 0.30.0 machine inventories preserved in `docs/history/v1-api-inventory-m33-0.30.0.json` and `docs/history/v1-finding-codes-m33-0.30.0.json`.
   - Current 0.31.0 inventories updated and frozen in `docs/v1-api-inventory.json` and `docs/v1-finding-codes.json` (all 40 finding codes registered).
5. **CI Pipeline Integration**: Added `bash tests/v1-docs.sh complete pg-react:m34-unreleased` to `.github/workflows/ci.yml`.

---

## 2. Mechanically Verified Documentation Corpus

The canonical documentation corpus audited and verified against installed product reality comprises:

| Document | Canonical Path | Verification Scope | Status |
| --- | --- | --- | --- |
| Root README | `README.md` | Core architecture, quickstart pointers, role model | Verified |
| Documentation Index | `docs/index.md` | Central documentation directory, task-based routing | Verified |
| Getting Started | `docs/getting-started.md` | End-to-end tutorial SQL, rule lifecycle, consequence execution | Verified |
| Concepts | `docs/concepts.md` | Authoritative facts, reactive conditions, durable consequences | Verified |
| Authoring Guide | `docs/v1-authoring.md` | Rule/decision/policy-set constructors, typed consequences, validation | Verified |
| Changing Policies | `docs/changing-policies.md` | M34 comparison, delta classification, evidence limit, no-effect | Verified |
| Installation Guide | `docs/v1-installation.md` | Package verification, GUC settings, role setup, grant defect workaround | Verified |
| Operations Guide | `docs/v1-operations.md` | Health inspection, lease sweeping, pause/resume, recovery, restore | Verified |
| Security Guide | `docs/v1-security.md` | 5-role model, source/target authorization, search_path isolation | Verified |
| Backup & Restore | `docs/v1-backup-restore.md` | Data restore + declaration replay + state reconciliation model | Verified |
| Upgrade Guide | `docs/v1-upgrade.md` | Supported upgrade paths, 0.30.0 to 0.31.0 migration, rollbacks | Verified |
| Troubleshooting | `docs/v1-troubleshooting.md` | Diagnosis with doctor(), health view, structured finding details | Verified |
| Limits | `docs/v1-limits.md` | Evidence limit bounds (1..1000), single bigint key, poll intervals | Verified |
| Support Matrix | `docs/v1-support-matrix.md` | Qualified platform (PostgreSQL 18.3, pg_trickle 0.81.0, Linux amd64) | Verified |
| API Reference | `docs/v1-api-reference.md` | Complete inventory of ordinary, advanced, and admin functions/views | Verified |
| Known Limitations | `docs/v1-known-limitations.md` | Documented v1 boundaries (no hypothetical facts, RLS unsupported) | Verified |
| 1.0 Release Notes | `docs/1.0-release-notes.md` | Feature boundary, migration summary, release candidate roadmap | Verified |
| v1 Contract | `docs/v1-contract.md` | Normative behavioral and stability contracts | Verified |
| Compatibility | `docs/v1-compatibility.md` | Compatibility aliases, worker protocol versioning | Verified |
| Deprecations | `docs/v1-deprecations.md` | Deprecated interfaces and replacement guide | Verified |

---

## 3. Test Suite Architecture & Fixtures

### `tests/v1-docs-audit.py`
Audits 250 repository markdown files and 20 canonical documents:
- **Link & Anchor Integrity**: Validates every relative markdown link and heading anchor `#fragment`.
- **Anti-Stale Enforcement**: Enforces that canonical documentation never references nonexistent fields (e.g. `work.created_at`), never routes to superseded milestone pages (`docs/m*-*`, `docs/v1-upgrades.md`) as current guidance, never promises comparison continuation tokens or byte-for-byte envelope determinism, and does not claim M35 features for v1.

### `tests/v1-docs.sh`
The canonical test runner supporting `fast` and `complete` profiles:
- Starts isolated Docker test containers.
- Verifies live catalog inventories against `docs/v1-api-inventory.json` and `docs/v1-finding-codes.json`.
- Spawns fresh, isolated test databases for each fixture to ensure strict test isolation.
- Executes all 5 SQL test fixtures with `ON_ERROR_STOP=1`.

### SQL Fixtures Summary
- `tests/v1-docs-api.sql`: Validates five-role setup, `PUBLIC` security revocations, `search_path = pg_catalog, pg_temp` on `SECURITY DEFINER` routines, all 40 finding codes, protocol compatibility (1 and 2 valid; 0 and 3 invalid), and runtime GUC bounds.
- `tests/v1-docs-getting-started.sql`: Validates the complete getting started tutorial: table/view definitions, typed consequence function, `pgreact.validate()`, `pgreact.preview()`, `pgreact.deploy()`, change processing via managed worker cycle, match inspection, work completion, attempt logging, and clean removal.
- `tests/v1-docs-authoring.sql`: Validates constraint vs command rules, typed consequence signatures, single bigint semantic key requirements, decision programs, policy sets, status queries, explain queries, and all 7 public views.
- `tests/v1-docs-comparison.sql`: Validates `pgreact.compare()` and `pgreact.compare_results()`, delta statuses (ADDED, REMOVED, CHANGED, UNCHANGED), evidence limit truncation, target mismatch handling, semantic projection determinism, and 9-table state snapshot no-effect assertions.
- `tests/v1-docs-operations.sql`: Validates `pgreact.doctor()`, structured health query filtering (`details ->> 'source_code'`), lease sweeping, rule pause/resume, and state-only reconciliation.

---

## 4. Qualification of Strengthened No-Effect Assertions (Part E)

Comparison in pg-react must remain purely read-only and guarantee zero mutation of authoritative state. In `tests/v1-docs-comparison.sql`, no-effect behavior was verified by taking explicit before and after table snapshots across 9 state tables and frontiers:

1. `pgreact_internal.api_declarations`: Deployed declarations and digests.
2. `pgreact_internal.rule_versions`: Internal rule versions and states.
3. `pgreact_internal.activation_state`: Active matches, generations, and revisions.
4. `pgreact_internal.decision_subject_state`: Evaluated decision states.
5. `pgreact_internal.policy_set_versions`: Deployed policy-set versions.
6. `pgreact.work`: Public durable work queue.
7. `pgreact.attempts`: Durable consequence attempt logs.
8. `comp_app.orders`: Application source data relations.
9. `pgreact_internal.clock_frontier`: Temporal clock frontier timestamp.

**Assertion Result**: In isolated execution, all 9 snapshots were verified to be byte-for-byte and row-for-row identical before and after both `pgreact.compare()` and `pgreact.compare_results()`. Zero mutations, zero work items, zero attempt logs, and zero clock advances occurred.

---

## 5. Qualification of Semantic Projections & Determinism (Part L)

The comparison result envelope (`pgreact.compare()`) includes runtime execution measurements in `cost.elapsed_ms`. Because wall-clock query execution time naturally fluctuates between runs, full result envelopes cannot be byte-for-byte identical.

**Validated Projection**:
When excluding execution measurements (`run - 'cost'`), the normalized semantic projection—comprising `current`, `proposed`, `delta`, `lifecycle`, `work`, `findings`, and `evidence` (including `authoritative_checksum_before` and `authoritative_checksum_after`)—is proven deterministic across repeated invocations on identical data.

---

## 6. Qualification of Semantic Keys vs Advanced Codecs (Part K)

- **Ordinary Rules**: Exactly 1 non-null unique bigint column is required as the semantic key. Non-bigint column keys or composite keys are rejected during rule validation and comparison with `M34_WRONG_KEY_TYPE` or `M32_WRONG_KEY_TYPE`.
- **Advanced Codec-v2**: Composite or structured keys are supported only via the advanced internal codec-v2 representation (`pgreact.activation_context`) used by specialized subsystems. Canonical user documentation accurately specifies single bigint keys for ordinary rules.

---

## 7. Qualification of Names-First Replacement & Cutover (Part N)

### Discovery of `deploy_m28` Variable Collision
During authoring and replacement qualification, attempting to redeploy or replace a declaration that already exists in `pgreact_internal.api_declarations` revealed a PL/pgSQL variable collision in `sql/m28.sql` (lines 416-422):

```sql
IF current_found AND current_row.state = 'REMOVED' THEN
    UPDATE pgreact_internal.api_declarations
    SET api_version = (declaration).api_version, spec = (declaration).spec,
        normalized = normalized, ... -- ERROR: column reference "normalized" is ambiguous
```

Because `normalized` is both a table column and a local PL/pgSQL variable, PostgreSQL rejects the update with `ERROR: column reference "normalized" is ambiguous`.

### Operational Routing
1. **Ordinary Replacement**: Re-deploying an already deployed/removed declaration using `pgreact.deploy()` fails until this variable name is disambiguated in the SQL definition.
2. **Supported Rule Cutover**: For existing deployed rules, the qualified workflow is the advanced names-first cutover `pgreact_api.replace_rule()` / `pgreact.replace_rule()`.
3. **Policy Sets & Decisions**: Policy sets must be deployed as new immutable versions (`pgreact.policy_set(..., version => '2')`). Decisions are removed and redeployed.

---

## 8. Logical Restore and Backup Verification (Part M)

pg-react documentation specifies that private schemas (`pgreact_internal`, `pgreact_runtime`) must NOT be dumped or restored directly via `pg_dump`/`pg_restore`.

**Verified Workflow**:
1. Restore application tables and views from standard PostgreSQL dumps.
2. Replay canonical declaration specifications (`pgreact.deploy(...)`).
3. Run state-only reconciliation (`pgreact.prepare_recovery()` + `pgreact.reconcile_rule(rule_version_id, 'STATE_ONLY')`).
4. Execute coordination cycle (`pgreact.run()`).

This model was verified to reconstruct internal stream tables, activation states, and match views without requiring private catalog restores.

---

## 9. Security & Role Model Qualification (Part G)

The five-role security model was verified against live PostgreSQL role catalogs:
- `pgreact_author`: Can validate, preview, deploy, and compare authorized targets.
- `pgreact_operator`: Can inspect health, sweep leases, pause/resume, reconcile, and compare.
- `pgreact_worker`: Can claim and execute durable work; lacks deploy/compare privileges.
- `pgreact_reader`: Can read public views and run comparisons.
- `pgreact_advanced_reader`: Read-only access to advanced diagnostics; does not inherit ordinary comparison.

**Boundary Verification**:
- `PUBLIC` lacks `USAGE` on `pgreact_internal` and `pgreact_runtime`.
- `PUBLIC` lacks `EXECUTE` on `pgreact.compare` and `pgreact.compare_results`.
- All public `SECURITY DEFINER` routines enforce `SET search_path = pg_catalog, pg_temp`.

---

## 10. Machine Inventories & Finding Codes Qualification (Part J)

- **Inventories Preserved**:
  - `docs/history/v1-api-inventory-m33-0.30.0.json` (M33 baseline)
  - `docs/history/v1-finding-codes-m33-0.30.0.json` (22 M32 codes)
- **Current Inventories Frozen**:
  - `docs/v1-api-inventory.json` (M34 / 0.31.0 frozen catalog)
  - `docs/v1-finding-codes.json` (all 40 finding codes: 22 M32 + 18 M34)
- **Consistency**: Verified that all ordinary functions, types, views, and finding codes in documentation match the installed 0.31.0 database catalogs.

---

## 11. Limits & Support Matrix Qualification (Part I)

- **Qualified Platform**: PostgreSQL 18.3, pg_trickle 0.81.0, Linux amd64.
- **Worker Protocol**: Protocol versions 1 and 2 are compatible; versions 0 and 3 are incompatible.
- **GUC Parameters**:
  - `pg_react.poll_interval_ms`: default `1000`, range `10..60000`.
  - `pg_react.batch_size`: default `32`, range `1..1000`.
  - `pg_react.max_pending_jobs`: default `10000`, minimum `1`.

---

## 12. Pre-RC Blockers Ledger

The following issues must be resolved before tagging `1.0.0-rc.1`:

| # | Blocker Classification | Component | Description & Location | Required Resolution Before 1.0.0-rc.1 |
| --- | --- | --- | --- | --- |
| 1 | **RC Product Blocker** | `src/managed.rs` | Lines 101–104 hardcode `extversion = '0.31.0'`. Any RC/GA version string (e.g. `1.0.0-rc.1`) causes background workers to idle without running `managed_cycle()`. | Update version check in `src/managed.rs` to allow RC/GA versions or query semver compatibility. |
| 2 | **RC Product Blocker** | `sql/m31.sql` | `pgreact_api.configure_roles` does not grant `EXECUTE` on `pgreact.compare` and `pgreact.compare_results` to author, operator, or reader roles when roles are created after extension creation. | Fold comparison function grants into `configure_roles` in the 1.0 release migration script. |
| 3 | **RC Product Blocker** | `sql/m28.sql` | In `deploy_m28` (lines 416-422), `UPDATE pgreact_internal.api_declarations SET normalized = normalized` fails due to PL/pgSQL variable/column collision. | Disambiguate local variable (e.g. `v_normalized`) in `deploy_m28`. |
| 4 | **Documentation / Claim Blocker** | `docs/v1-installation.md`, `docs/v1-limits.md` | `pg_react.batch_size` GUC accepts `1..1000` for window maintenance, whereas worker job claim batches have a strict `100` maximum (`max_items BETWEEN 1 AND 100`). | Clarify in documentation the distinction between the GUC range (`1..1000`) and the worker batch claim limit (`100`). |

---

## 13. Documentation Qualification Blockers vs Non-Blocking Limitations

### Resolved in Step 4
- Mechanical verification of all Getting Started, Authoring, Comparison, Operations, Security, and Troubleshooting SQL examples.
- Automated link, anchor, and anti-stale claims auditing.
- Exact alignment between documentation finding codes (40 codes) and live catalog finding registries.
- Strengthened 9-table snapshot no-effect validation.

### Non-Blocking v1 Boundaries (Carried Forward as Documented Limitations)
- Comparison is strictly point-in-time and does not emit continuation tokens.
- `elapsed_ms` varies by query execution and is excluded from deterministic semantic equality.
- Row-level security (RLS) on evaluated sources fails closed (`M34_RLS_UNSUPPORTED`).
- M35 hypothetical-fact simulation is post-v1 and excluded from v1.

---

## 14. CI & Test Suite Execution Evidence

The complete test suite was executed against candidate image `pg-react:m34-unreleased`:

```text
=== pg-react v1 Documentation Executable Validation (complete) ===
==> Running: v1 documentation link and stale-reference audit
Documentation audit passed (250 files checked, 20 canonical docs verified)
==> Running: v1 documentation and live installed inventory consistency
true
==> Running: v1 documentation and live installed finding codes consistency
true
==> Running: v1 API and security fixture (tests/v1-docs-api.sql)
==> Running: v1 Getting Started fixture (tests/v1-docs-getting-started.sql)
==> Running: v1 Authoring fixture (tests/v1-docs-authoring.sql)
==> Running: v1 Comparison and No-Effect fixture (tests/v1-docs-comparison.sql)
==> Running: v1 Operations and Troubleshooting fixture (tests/v1-docs-operations.sql)
==> Running complete profile extended validations...
=== pg-react v1 documentation validation SUCCEEDED (complete profile, image: pg-react:m34-unreleased) ===
```

Additionally, inherited milestone test runners executed cleanly:
- `tests/m34.sh complete pg-react:m34-unreleased`: **PASSED**
- `tests/m33.sh complete pg-react:m34-unreleased`: **PASSED**

---

## 15. Readiness Recommendation for `1.0.0-rc.1`

The documentation and testing infrastructure is **READY FOR 1.0.0-rc.1 QUALIFICATION** subject to resolving the 4 pre-RC blockers identified in Section 12.

### Step Sequence for 1.0.0-rc.1:
1. Fix `src/managed.rs` extension version check.
2. Fix `sql/m31.sql` `configure_roles` comparison grants.
3. Fix `sql/m28.sql` `deploy_m28` variable collision.
4. Align `pg_react.batch_size` GUC vs worker batch size claim documentation.
5. Re-run `tests/v1-docs.sh complete` and package `1.0.0-rc.1`.

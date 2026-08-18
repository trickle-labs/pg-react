# pg-react v1.0 Documentation & `1.0.0-rc.1` Qualification Report (Step 5)

**Status:** Completed and Qualified  
**Release Target:** `1.0.0-rc.1`  
**Feature Baseline:** M34 / `0.31.0` (M35 is post-v1)  
**Controlling Handoff:** [`v1-docs-step4.md`](v1-docs-step4.md)  
**Date:** 2026-08-18  

---

## 1. Executive Summary

This Step 5 pass completes the v1.0 documentation qualification and prepares the repository for cutting `1.0.0-rc.1` without publishing.

All four pre-RC blockers identified in [`v1-docs-step4.md`](v1-docs-step4.md) have been resolved:
1. **Managed Runtime Version Compatibility:** The background worker dynamically checks extension version compatibility using semver regex matching (`0.31.0`, `1.0.0-rc.N`, and `1.0.0`), resolving the hardcoded `0.31.0` requirement.
2. **Comparison Execution Grants in `configure_roles`:** `pgreact_api.configure_roles` authoritatively grants `EXECUTE` on `pgreact.compare` and `pgreact.compare_results` to `author`, `operator`, and `reader` roles, and revokes them from `worker`, `advanced_reader`, and `PUBLIC`.
3. **Declaration Deployment Variable Disambiguation:** Disambiguated all local variables in `pgreact_api.deploy_m28` using a uniform `v_` prefix, eliminating PL/pgSQL variable-vs-column collisions when redeploying removed declarations.
4. **Batch Size and Worker Claim Bounds:** Clarified that `pg_react.batch_size` (1..1000) controls window maintenance, while worker claims are automatically capped to `least(batch_size, 100)` items to strictly comply with `pgreact.claim` limits.

Local release candidate artifacts (`1.0.0-rc.1`) have been packaged and verified. Fresh install and direct `0.31.0 -> 1.0.0-rc.1` upgrade paths produce byte-identical catalog inventories (`pgreact_internal.m33_installed_inventory()`), state is completely preserved across upgrades without executing unexpected business work, and the entire test matrix (`tests/v1-docs.sh complete`, `tests/m34.sh complete`, `tests/m33.sh fast`, Rust unit tests) passes with zero errors.

---

## 2. Resolution of Step 4 Pre-RC Blockers

### Blocker 1: Managed Runtime RC/GA Version Handling (Part A)
- **Problem:** `src/managed.rs` hardcoded SQL query `SELECT extversion = '0.31.0' FROM pg_extension WHERE extname = 'pg_react'`, causing background workers to refuse cycling under any RC or GA version string.
- **Resolution:**
  - Implemented `is_compatible_extension_version(version: &str) -> bool` in `src/managed.rs` supporting `0.31.0`, `1.0.0-rc.N` ($N \ge 1$), and `1.0.0`.
  - Updated `pg_react_managed_main` to query `SELECT extversion FROM pg_extension WHERE extname = 'pg_react'` and test compatibility via `is_compatible_extension_version`.
  - Added unit test suite `tests::test_version_compatibility` covering valid and invalid version strings.
- **Verification:** Verified live managed worker heartbeats and cycling under `1.0.0-rc.1` in PostgreSQL 18.3.

### Blocker 2: Comparison Grants After Role Configuration (Part B)
- **Problem:** `pgreact_api.configure_roles` in `0.31.0` failed to grant `EXECUTE` on `pgreact.compare` and `pgreact.compare_results` to configured roles, requiring a manual grant workaround after fresh install.
- **Resolution:**
  - Authored updated `pgreact_api.configure_roles` in `sql/pg_react--0.31.0--1.0.0-rc.1.sql` and `sql/pg_react--1.0.0-rc.1.sql` that grants `EXECUTE` on `pgreact.compare` and `pgreact.compare_results` to `author_role`, `operator_role`, and `reader_role`, while explicitly revoking them from `worker_role`, `advanced_reader_role`, and `PUBLIC`.
  - Added upgrade migration DO block that automatically reapplies `configure_roles` for existing configured application roles.
- **Verification:** Asserted role privileges in `tests/v1-docs-api.sql` and fresh/upgraded integration tests.

### Blocker 3: Ordinary Deploy/Redeploy Variable Collision (Part C)
- **Problem:** Re-deploying a removed declaration or replacing a rule using `pgreact.deploy` failed with `ERROR: column reference "delegated_id" is ambiguous` / `column reference "normalized" is ambiguous` due to PL/pgSQL variable shadowing.
- **Resolution:**
  - Authored clean `pgreact_api.deploy_m28` with all local variables prefixed with `v_` (`v_validation`, `v_normalized`, `v_findings`, `v_current_row`, `v_delegated_id`, `v_owner_id`, `v_current_found`, `v_expected_digest`, `v_allow_create`, `v_condition_oid`, `v_candidate_oid`, `v_result_columns`).
- **Verification:** Tested complete lifecycle (`deploy` -> `remove` -> `redeploy` and replacement) across isolated test databases.

### Blocker 4: Batch Size and Claim Limit Alignment (Part D)
- **Problem:** GUC `pg_react.batch_size` accepts 1..1000, while `pgreact_api.claim(worker, max_items, ...)` rejects `max_items > 100`.
- **Resolution:**
  - Confirmed and documented that `pgreact_internal.managed_cycle()` computes `claim_limit := least(batch_limit, 100)`, safely bounding durable job claims while allowing larger batches for maintenance.
  - Documented exact behavior in `docs/v1-limits.md` and `docs/v1-operations.md`.
- **Verification:** Tested claim rejection for `max_items = 101` and verified managed cycle execution with `pg_react.batch_size = 500`.

---

## 3. Local Candidate Release Artifacts (Part E, L)

The local candidate release artifacts for `1.0.0-rc.1` are prepared and checksummed:

### Metadata & Control Files
- `Cargo.toml`: `version = "1.0.0-rc.1"`
- `pg_react.control`: `default_version = '1.0.0-rc.1'`
- `Dockerfile`: `ENV PG_REACT_INIT_VERSION=1.0.0-rc.1`
- `docker-compose.yml`: `PG_REACT_IMAGE=pg-react:1.0.0-rc.1`, `PG_REACT_INIT_VERSION=1.0.0-rc.1`

### SQL Extension Scripts
- `sql/pg_react--1.0.0-rc.1.sql` (1,814,034 bytes): Complete fresh-install SQL script.
- `sql/pg_react--0.31.0--1.0.0-rc.1.sql` (11,881 bytes): Direct migration script from `0.31.0` to `1.0.0-rc.1`.
- Historical milestone SQL files (`sql/pg_react--0.31.0.sql`, `sql/m34.sql`, `sql/m33.sql`, etc.) are 100% byte-preserved.

### SHA-256 Checksums
```text
354a8cd7b601dc4420bac7b42c7ee6d398e9c2cf9f374d80d5bb17c200337e74  sql/pg_react--1.0.0-rc.1.sql
94e072f07641bd7812414ee2f46d5c1e6f3299c9cc3048c930ae5349411ef3bf  sql/pg_react--0.31.0--1.0.0-rc.1.sql
24805757d630ff1d8f1fbd46aa495ac715063b5e82f7b3b8ef4298453e6d107a  Cargo.toml
81b9b3f446941de17ff3905a781f262f58db038dfb9ba37b8eead7f9e4bc0b19  pg_react.control
979bd197783689078223b8e8c4796b6f5ce3e40902d56faa17744d78f8efc3c1  Dockerfile
9e6248a23109b9ec567e57b60866d8824aafbf7accbb8a429954bf935de791e6  docker-compose.yml
```

### Local Docker Image Identifiers
- Tag: `pg-react:1.0.0-rc.1` (and `pg-react:m34-unreleased`)
- Image ID: `sha256:72e2d5e9068b3f716a751c52c088aab8b09a344adebcebbd9d1ea7323474836b`
- Size: `166,756,932` bytes
- Base: `ghcr.io/trickle-labs/pg_trickle@sha256:998ab948555e990dcffc9464f316b3abe6b05f9ebc8bd50f16d3bc5bf88ca65d` (PostgreSQL 18.3, pg_trickle 0.81.0)

---

## 4. Upgrade Path Qualification (Part F)

- **Fresh Install Path:** `CREATE EXTENSION pg_react VERSION '1.0.0-rc.1';` installs all types, functions, and views.
- **Direct Upgrade Path:** `ALTER EXTENSION pg_react UPDATE TO '1.0.0-rc.1';` applies `sql/pg_react--0.31.0--1.0.0-rc.1.sql`.
- **State Preservation:** Pre-existing rules, policy sets, matches, decisions, work items, and attempts remain intact across upgrade.
- **Zero Unintended Work:** No business consequences or worker executions run during extension upgrade.
- **Catalog Inventory Equality:** Verified that `pgreact_internal.m33_installed_inventory()` is 100% identical between a fresh `1.0.0-rc.1` installation and a populated `0.31.0 -> 1.0.0-rc.1` upgraded database.

---

## 5. Inventory and Registry Preservation & Regeneration (Part G)

- **Historical Preservation:**
  - `docs/history/v1-api-inventory-m33-0.30.0.json` (Preserved M33 inventory)
  - `docs/history/v1-finding-codes-m33-0.30.0.json` (Preserved M33 finding codes)
  - `docs/history/v1-api-inventory-m34-0.31.0.json` (Preserved M34 inventory)
  - `docs/history/v1-finding-codes-m34-0.31.0.json` (Preserved M34 finding codes)
- **Active RC Regeneration:**
  - `docs/v1-api-inventory.json`: Regenerated with `"milestone": "1.0.0-rc.1"`, `"extension_version": "1.0.0-rc.1"`, `"predecessor": "M34 / 0.31.0"`.
  - `docs/v1-finding-codes.json`: Regenerated with `"milestone": "1.0.0-rc.1"`, `"extension_version": "1.0.0-rc.1"`.

---

## 6. Canonical Documentation Audit & Cold-Start Review (Part H, J)

All 20 canonical documents and 250 repository markdown files passed static audit (`tests/v1-docs-audit.py`):
1. `README.md`
2. `docs/index.md`
3. `docs/getting-started.md`
4. `docs/concepts.md`
5. `docs/v1-authoring.md`
6. `docs/changing-policies.md`
7. `docs/v1-installation.md`
8. `docs/v1-operations.md`
9. `docs/v1-security.md`
10. `docs/v1-backup-restore.md`
11. `docs/v1-upgrade.md`
12. `docs/v1-troubleshooting.md`
13. `docs/v1-limits.md`
14. `docs/v1-support-matrix.md`
15. `docs/v1-api-reference.md`
16. `docs/v1-known-limitations.md`
17. `docs/1.0-release-notes.md`
18. `docs/v1-contract.md`
19. `docs/v1-compatibility.md`
20. `docs/v1-deprecations.md`

### Cold-Start Review Perspectives
- **Developer / Rule Author:** Getting started, concept progression, typed consequences, and policy change workflows use exclusively public `pgreact` API functions.
- **Operator / SRE:** Runbooks follow standard `observe -> diagnose -> repair -> invoke -> verify` without editing private internal schemas.
- **Auditor / Security:** Security boundary, role separation, `PUBLIC` revoking, and deterministic comparison permissions are explicitly documented and tested.

---

## 7. RC Gate Policy vs GA Qualification (Part I)

- **Release Candidate (`1.0.0-rc.1`) Gate:** Gated entirely on automated verification: complete compilation, unit tests, SQL extension scripts, candidate Docker packaging, documentation test harness (`tests/v1-docs.sh complete`), and upgrade qualification.
- **General Availability (`1.0.0`) Gate:** Gated on human usability assessments and controlled multi-database pilot deployments conducted against the RC candidate artifacts during the release candidate stabilization phase.

---

## 8. Automated Validation Results (Part K)

| Test Suite | Command | Result |
| --- | --- | --- |
| Rust Unit Tests | `cargo test --no-default-features` | **8 passed, 0 failed** |
| Code Formatting | `cargo fmt --check` | **Clean (0 diffs)** |
| Documentation Static Audit | `python3 tests/v1-docs-audit.py` | **250 files checked, 20 canonical docs verified** |
| v1 Executable Documentation | `bash tests/v1-docs.sh fast` | **SUCCEEDED** |
| v1 Complete Qualification | `bash tests/v1-docs.sh complete` | **SUCCEEDED** |
| M34 Complete Suite | `bash tests/m34.sh complete` | **SUCCEEDED** |
| M33 Fast Suite | `bash tests/m33.sh fast` | **SUCCEEDED** |

---

## 9. Publication Readiness & Non-Publication Confirmation (Part L)

- **Candidate Tag Ready:** `1.0.0-rc.1` (or `v1.0.0-rc.1`)
- **No Remote Publication Performed:** No git tags pushed, no GitHub releases created, no container registry pushes made.
- **Ready for Release Decision:** The repository state is clean, fully verified, and ready for cutting `1.0.0-rc.1`.

---

## 10. Conclusion & Next Step

The pg-react v1.0 documentation rewrite and repository qualification pass is complete. All pre-RC blockers are resolved in candidate code and SQL artifacts. The repository is ready to cut `1.0.0-rc.1`.

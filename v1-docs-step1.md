# pg-react v1 documentation audit — step 1

**Outcome:** no documentation files were changed during the audit. M34/`0.31.0`
is demonstrably installed and released, but the documentation is not yet a
deterministic v1 source set.

## 1. Decision record

- **v1 feature boundary:** M34 / extension `0.31.0`.
- **Release sequence:** `0.31.0 -> 1.0.0-rc.1 -> later RCs if needed -> 1.0.0`.
- **M35:** post-v1; it neither blocks RC nor GA.
- **Scope:** documentation, packaging, qualification fixes, and
  semantics-preserving corrections only. No M35 functionality.

`v0.31.0` is published, and the packaged M34 installation/comparison tests
pass.

## 2. Effective authority found

1. **Executable product:** `sql/pg_react--0.31.0.sql`, its
   `0.30.0 -> 0.31.0` migration, `sql/m34.sql`, installed-catalog behavior,
   tests, `src/managed.rs`, Docker configuration, and release workflow.
2. **Normative v1 contract:** `docs/v1-contract.md` and its normative
   companions—but these currently lag M34 and lose authority wherever
   executable behavior disagrees.
3. **Current user guidance:** README and `docs/v1-*`; several are mutually
   inconsistent.
4. **Delivery/history:** living `ROADMAP.md`; M33/M34 contracts, readiness,
   release notes, checklists, inventories, and published artifacts.
5. **Planning checklist:** `pg-react-v1-documentation-plan.md`.

`DESIGN.md` claims semantic authority but is explicitly an M13-era document and
contradicts the managed runtime. Until relabeled, it must be treated as
historical architecture, not current v1 authority.

**Document roles**

- **Normative:** v1 contract, support matrix, limits, security, compatibility,
  upgrade/recovery/operations policies.
- **Current end-user:** README and current `v1-*` task guides.
- **Qualification evidence:** `m33-*`, `m34-*`, their tests, workflow, and
  release artifacts.
- **Immutable history:** older milestone inventories and records, plus
  `v1-release-notes.md` and `v1-upgrades.md`, which already identify themselves
  as historical M4 material.

## 3. Documentation change ledger

| File | Required treatment |
|---|---|
| `README.md` | Change release boundary; add `kind => 'COMMAND'` to the first-rule declaration; correct worker and key-scope wording; remove stale “reasoning is future” claims. |
| `ROADMAP.md` | Make M34 the RC gate; move M35 post-v1; remove hypothetical facts from v1 success criteria; correct comparison determinism wording. |
| `DESIGN.md` | Add a strong historical/M13 banner and remove its effective authority over current runtime behavior. |
| `docs/v1-contract.md` | Move baseline to M34/`0.31.0`; add comparison APIs and semantics; clarify per-database coordination and scheduler wording; exclude M35. |
| `docs/v1-api-inventory.json` | Preserve the M33 snapshot under a historical name, then regenerate the current inventory from the RC artifact. |
| `docs/v1-finding-codes.json` | Preserve the M33 snapshot and regenerate with M34 findings. |
| `docs/v1-authoring.md` | Replace legacy rule APIs with declaration constructors and ordinary verbs; correct supported-feature claims. |
| `docs/v1-installation.md` | Document `pg_trickle,pg_react` preload, managed worker GUCs, five-role configuration, restart, protocol 2, and `pg-reactd` compatibility status. |
| `docs/v1-operations.md` | Add executable managed-runtime procedures and comparison operations; stop linking users to M3 operations. |
| `docs/v1-troubleshooting.md` | Fix invalid `work.created_at`; add exact managed-runtime and M34 findings/remediation. |
| `docs/v1-security.md` | Document the advanced reader and exact five-role grants; add comparison authorization/redaction. |
| `docs/v1-support-matrix.md` | Clarify managed polling versus unsupported pg_trickle scheduling; add comparison/key boundaries. |
| `docs/v1-limits.md` | State exact comparison limits and remove the unsupported continuation claim. |
| `docs/v1-backup-restore.md` | Define the exact logical-restore model and managed-worker stop/reconcile/resume commands. |
| `docs/v1-upgrade.md` | Replace `UPDATE TO '0.30.0'`; document only RC paths proven by an actual RC artifact; do not run business work during pre-resume verification. |
| `docs/v1-compatibility.md` | Add M34 and classify every installed public surface accurately. |
| `docs/v1-deprecations.md` | Align with the regenerated classification and historical-document policy. |
| `docs/v1-release-notes.md`, `docs/v1-upgrades.md` | Keep historical bodies; remove from current navigation and point to real v1 documents. |
| `docs/m33-{release-notes,readiness,evidence,final-checklist}.md` | Historical/superseded banner only; repair the nonexistent security-test reference without rewriting history. |
| `docs/m34-{release-notes,readiness,final-checklist}.md` | Add a supersession banner stating M35 moved post-v1; do not rewrite published historical text. |
| `docs/m34-{contract,api-reference,examples,benchmark}.md` | Add historical/current-reference pointers; benchmark needs an erratum noting unmeasured cost fields. |

**Create:** `docs/index.md`, `getting-started.md`, `concepts.md`,
`changing-policies.md`, `v1-api-reference.md`, `v1-known-limitations.md`,
`1.0-release-notes.md`, and `history.md`.

## 4. Contradiction ledger

| Conflict | Claims | Authority and fix |
|---|---|---|
| **M35 gates v1** | README lines 8–9 and 287–289; ROADMAP lines 315, 1993–1995, 2027, 2103, 2114, 2141, 2145, 2153; M34 release notes 27–30; M34 readiness 13–16. | Decision record controls. Edit living files; add supersession banners to historical M34 records. |
| **M33 versus M34 boundary** | M33 readiness/release/evidence say RC follows `0.30.0`; M34 records say RC follows M35. | Both are historical sequencing. Current boundary is `0.31.0`. |
| **README example is invalid** | README supplies `on_activate` but omits `kind => 'COMMAND'`. `pgreact.rule` defaults to `CONSTRAINT`, and installed SQL rejects consequences on constraints. | Installed SQL lines 2914–2922 and 35602 resolve it. Add `kind` to all three declarations. |
| **v1 contract omits M34** | Contract and v1 inventories identify `0.30.0`; installed `0.31.0` adds `compare` and `compare_results`. | Regenerate from `0.31.0`/RC and add M34 to the normative contract. |
| **Inventory is not exact** | Contract calls `v1-api-inventory.json` generated installed reality. Installed comparison found 34 `pgreact` functions absent from it and 30 listed names absent or in the wrong schema. It omits `decision`, `policy_set`, `compare`, `compare_results`, `export`, and `import`. | Installed catalog controls. M33 tests check inclusion, not equality; M34 tests check only two names. Replace qualification with exact artifact equality. |
| **Finding inventory is stale** | v1 registry contains only 22 M32 codes; M34 installs 18 additional codes. | Preserve historical M33 registry and generate a complete current registry. |
| **Canonical API conflict** | README/contract use declaration constructors and ordinary verbs; `v1-authoring.md` teaches `preview_rule`, `validate_rule`, `create_rule`, UUID-driven operations. | Ordinary API in installed SQL and v1 contract controls; legacy APIs move to compatibility guidance. |
| **Supported-feature conflict** | `v1-authoring.md` says derivations and reusable conditions are post-GA; README says reasoning is future, while installed `0.31.0` and inventory expose extensive advanced derivation, temporal, provenance, and decision features. | Document them as supported advanced surfaces, not ordinary defaults or future behavior. |
| **Worker model conflict** | README/support/Docker/runtime use PostgreSQL-managed workers; installation and M3 operations teach `pg-reactd`; DESIGN says no background worker/preload requirement. | `src/managed.rs`, Docker Compose, and M15 executable contract control. |
| **Coordinator topology conflict** | `v1-contract.md` says one global coordinator; runtime starts one worker per configured database. | Change to one managed coordinator/worker per configured database. |
| **Scheduling wording conflict** | Contract broadly rejects “automatic scheduling,” while managed workers poll automatically. | Narrow the unsupported claim to pg_trickle automatic/uncoordinated refresh. |
| **`pg-reactd` behavior conflict** | README says it only drains pending work during migration; the script invokes `pgreact_api.run()` before claiming and can create new work. | Describe its actual compatibility behavior or stop claiming drain-only semantics. |
| **Role conflict** | v1 security documents four roles; installed `configure_roles` and M15 require four application roles plus an advanced reader. | Document the exact five-role model; no distinct deployer exists in installed behavior. |
| **Broken troubleshooting SQL** | `v1-troubleshooting.md` orders `pgreact.work` by nonexistent `created_at`. Installed view exposes `updated_at`. | Change to `updated_at`. |
| **Upgrade conflict** | `v1-upgrade.md` claims RC/GA paths but executes `UPDATE TO '0.30.0'`; no RC SQL/workflow exists. | Publish only paths exercised by the eventual RC artifact. |
| **Upgrade no-work conflict** | Upgrade policy says no business work; verification calls `pgreact.run()`, which can create and execute coordinated work. | Keep pre-resume verification read-only; make resumption explicit. |
| **Semantic-key conflict** | README/DESIGN describe composite keys; v1 limits say one bigint; M15 supports typed codec-v2 keys; M34 comparison rejects non-bigint rule keys. | Document the narrower comparable-v1 boundary and separately classify advanced typed-key support. |
| **Comparison version restriction omitted** | M34 docs allow a normal target; installed comparison accepts only deployed version `1` for non-policy declarations. | Add the exact target-version restriction. |
| **Continuation invented** | `v1-limits.md` says continuation is explicit; M34 exposes no continuation token, and `compare_results` expands the same truncated arrays. | Document rerunning with a higher `evidence_limit` up to 1000; do not promise continuation. |
| **Byte determinism impossible** | ROADMAP requires byte-for-byte identical comparison output; installed output contains measured `cost.elapsed_ms`. | Define determinism over semantic fields, excluding runtime measurements, or change the contract. |
| **Cost evidence overstated** | M34 benchmark says fan-out, reevaluation, cascade, memory, and temporary storage are reported. SQL returns constant `0` values and `memory_bytes = NULL`; only counts and elapsed time are measured. | Label unavailable/placeholders accurately in current docs. |
| **Checksum scope overstated** | Docs call it an authoritative/no-effect checksum covering attempts, delivery, and effects. The function hashes selected pg-react state but excludes source tables, lifecycle history, attempts, and outbox delivery state. | Describe its exact scope; rely separately on the additive SQL no-DML audit. |
| **Shared-evaluator claim unproven** | ROADMAP/plan say comparison reuses the production evaluator; installed M34 uses separate `m34_*` row-evaluation helpers, though it calls ordinary validation. Tests compare a bounded fixture, not isolated production execution. | Narrow documentation to evidenced equivalence unless shared-evaluator behavior is proven. |
| **M33 evidence overclaims** | `m33-evidence.md` cites nonexistent `tests/m33-security.sql` and says `m33.sh` checks the upgrade pair/direct lane; the script does neither. Its final checklist remains unchecked while M34 readiness claims inherited completion. | Historical erratum/banner; define what qualification evidence is actually required for RC. |
| **Speculative milestone collision** | The explicitly noncanonical vision document assigns M35 both hypothetical simulation and bounded why-not; M29 inventory calls M30 hypothetical simulation. | Treat as immutable speculative/history material; exclude from current navigation and authority. |

**Competing guides:** README versus `v1-authoring`; README/Docker/M15 versus
`v1-installation`; `v1-operations` versus linked M3 operations;
`v1-upgrade` versus historical `v1-upgrades` and milestone migrations;
historical `v1-release-notes` versus missing real 1.0 notes; fragmented
M32/M34/v1 API references.

## 5. Unresolved contract questions

1. What is the exact v1 classification of every installed public function,
   including `export`, `import`, legacy worker/recovery functions, and
   incorrectly schemed advanced entries?
2. Does v1 support codec-v2 UUID/text/composite rules generally while limiting
   M34 comparison to one bigint key, or is the whole v1 rule promise
   intentionally bigint-only?
3. Which exact upgrade paths will the RC package and tests support? No
   `0.31.0 -> 1.0.0-rc.1` artifact exists yet.
4. How should `src/managed.rs` handle RC/GA versions? It currently runs managed
   cycles only when `extversion = '0.31.0'`.
5. Is comparison determinism defined over semantic output excluding measured
   cost, and are placeholder cost fields contractual?
6. Is “same production evaluator” an intended product guarantee or merely
   semantic-equivalence intent?
7. What exact database state does the no-effect checksum promise to cover?
8. Does “logical restore supported” mean declaration/data replay only, or
   restoration of live pg-react catalogs followed by reconciliation?
9. Does M34 qualification for starting RC require the unchecked human
   usability and pilot evidence, or only the published automated release lane?

# pg-react v1 canonical documentation rewrite — step 3

## 1. Inputs and repository state

- `v1-docs-step1.md` and `v1-docs-step2.md` were read completely.
- `pg-react-v1-documentation-plan.md` was used as a completeness checklist.
- Repository product state had not materially changed since Step 2. The
  worktree contained the expected Step 2 documentation restructuring; no
  conflicting runtime, installed-SQL, test, Docker, or release-workflow change
  was found.
- M34 / extension `0.31.0` is the v1 feature boundary. The intended sequence is
  `0.31.0 -> 1.0.0-rc.1 -> later RCs if required -> 1.0.0`. M35 is post-v1.

## 2. Canonical files rewritten

| File | Substantive rewrite and verified claims |
| --- | --- |
| `README.md` | Replaced milestone chronology with the current product path, one valid `COMMAND` rule, managed-runtime wording, current advanced-capability classification, comparison-before-deployment, and links to the canonical guides. Verified ordinary constructor/verb names, consequence-kind requirement, M34 boundary, bounded current-fact comparison, and external at-least-once semantics. |
| `docs/index.md` | Retained the Step 2 task router as the single documentation home and verified that it routes current users away from milestone evidence. |
| `docs/getting-started.md` | Added one end-to-end order-review workflow: environment check, `doctor`, source table and condition view, typed consequence, declaration, validate, preview, deploy, managed processing, inspection, explanation, and removal. Verified public calls and views against installed `0.31.0`. |
| `docs/concepts.md` | Replaced the skeleton with a milestone-free mental model covering facts, conditions, declarations, semantic identity, matches, lifecycle, generations/revisions, work/attempts, consequences, derived facts, decisions, policy sets, bounded evidence, and comparison. Ordinary, advanced, and unsupported/post-v1 concepts are separated. |
| `docs/v1-authoring.md` | Replaced the legacy UUID-driven workflow with `rule`, `decision`, `policy_set`, `validate`, `preview`, `deploy`, and `remove`; documented constraint/command behavior, typed consequences, semantic keys, lifecycle, immutable versions, decisions, policy sets, advanced surfaces, and compatibility APIs. General typed-key support is kept separate from M34's bigint-only comparable rule key. |
| `docs/changing-policies.md` | Added the complete current/proposed/delta/lifecycle/work workflow, all four delta states, relational `compare_results` examples, bounded evidence and rerun behavior, sampled-time/frontier restrictions, authorization, no-effect limits, proposal/target/version restrictions, would-be work, and the revise/deploy/stop decision. |
| `docs/v1-contract.md` | Moved the normative baseline to M34 / `0.31.0`, added the evidenced comparison contract, excluded M35, corrected per-configured-database coordination and pg_trickle scheduling language, and narrowed determinism, evaluator, checksum, cost, upgrade, and restore claims. |
| `docs/v1-installation.md` | Rewrote installation for PostgreSQL 18.3, pg_trickle 0.81.0, Linux amd64, `pg_trickle,pg_react` preload, restart, extension order, managed GUCs, configured databases, five roles, protocol 2, diagnostics, and supported coordinated refresh. Documented `pg-reactd` as a one-shot compatibility bridge and exposed the fresh-install comparison-grant and hard-coded-version RC blockers. |
| `docs/v1-operations.md` | Replaced abstract guidance with executable observe/diagnose/repair/invoke/verify procedures for health, managed workers, work/attempts, requeue, leases, pause/resume, tested rule cutover, comparison, drift, barriers, reconciliation, retention, and worker recovery. Corrected health-code filtering to use `details.source_code`. |
| `docs/v1-security.md` | Replaced the four-role account with author, operator, worker, reader, and advanced reader; documented `PUBLIC`, fixed search paths, ownership, source access, RLS rejection, comparison authorization, fail-closed disclosure, private-schema prohibition, and the fresh-install comparison-grant defect. |
| `docs/v1-backup-restore.md` | Added executable stop, backup/restore, doctor/health, barrier, reconciliation, verification, and resume procedures. Physical recovery is described to its qualified scope; logical restore is limited to application/reference data plus declaration replay and rebuild/reconciliation. |
| `docs/v1-upgrade.md` | Removed stale and invented target versions. The page now states upgrade policy without claiming an RC artifact, keeps pre-resume checks read-only, separates reconciliation from verification, and uses restore-based rollback. |
| `docs/v1-troubleshooting.md` | Replaced invalid `work.created_at` usage with actual public columns and added executable diagnosis/remediation for environment, managed runtime, drift, failed work, stale leases, barriers, authorization, RLS, target/version errors, stale source/frontier, partial evidence, and limits. |
| `docs/v1-limits.md` | Added installed comparison bounds, kind/name/version/key restrictions, truncation without continuation, GUC and work bounds, the batch-size/claim mismatch, and current retention/recovery boundaries. General rule keys are not conflated with comparable rule keys. |
| `docs/v1-support-matrix.md` | Narrowed support to the installed PostgreSQL/pg_trickle/platform/preload/runtime tuple and qualified recovery scope. Managed polling is supported; automatic uncoordinated pg_trickle refresh is not. Comparison and RLS restrictions are explicit. |
| `docs/v1-api-reference.md` | Populated a role/use-case reference for ordinary constructors and verbs, public views, comparison signatures/results, and acknowledged advanced and compatibility families. It is explicitly a classified human reference, not a false exhaustive installed inventory. |
| `docs/v1-known-limitations.md` | Consolidated current platform, RLS, external-effect, comparison, cost-evidence, hypothetical-fact, historical-replay, workflow/BPM, and restore limitations without importing obsolete milestone limits. |
| `docs/v1-compatibility.md` | Defined ordinary, advanced, compatibility, administrative, historical, and private surface classes only to installed-evidence scope; left exhaustive classification to RC inventory qualification. |
| `docs/v1-deprecations.md` | Aligned deprecation/removal policy with the surface classes and kept historical documents distinct from callable compatibility commitments. |
| `docs/1.0-release-notes.md` | Retained a truthful skeleton with no unproduced RC/GA artifact claims. |
| `docs/history.md` | Retained the Step 2 history gateway so milestone evidence remains available without becoming current instruction. |
| `ROADMAP.md` | Kept milestone history intact while narrowing M34 comparison requirements: semantic rather than byte-identical determinism, measured versus placeholder cost evidence, exact checksum scope, and semantic-equivalence rather than shared-evaluator implementation claims. |

Historical M33/M34 records and the superseded `v1-release-notes.md` and
`v1-upgrades.md` retain the Step 2 banners; their immutable bodies were not
rewritten.

## 3. User journey now supported

| Task | Canonical path |
| --- | --- |
| Evaluate fit | `README.md` -> `docs/index.md` -> `docs/v1-known-limitations.md` -> `docs/v1-support-matrix.md` |
| Install | `docs/v1-installation.md` |
| First rule | `docs/getting-started.md` |
| Author and deploy | `docs/v1-authoring.md` |
| Operate | `docs/v1-operations.md` |
| Inspect and explain | `docs/v1-operations.md` -> `docs/v1-api-reference.md` |
| Compare a policy change safely | `docs/changing-policies.md` |
| Troubleshoot | `docs/v1-troubleshooting.md` |
| Recover | `docs/v1-backup-restore.md` |
| Upgrade | `docs/v1-upgrade.md` |

## 4. Legacy/current conflicts resolved

- M34 / `0.31.0`, not M35, is now the v1 boundary in current documentation.
- The README first rule explicitly uses `kind => 'COMMAND'` with a consequence.
- The ordinary path consistently uses declaration constructors and
  `validate`, `preview`, `deploy`, `remove`, `run`, `status`, `explain`, and
  `doctor`; legacy rule functions are compatibility-only.
- Installed derivation, decision, policy-set, provenance, temporal, and related
  capabilities are classified as supported advanced surfaces rather than
  future promises.
- PostgreSQL-managed per-database workers replace `pg-reactd` as the primary
  runtime. `pg-reactd` is accurately described as able to call `run`, create
  work, claim, execute, and exit.
- "One global coordinator" was replaced with one managed worker/coordinator per
  configured database.
- Supported PostgreSQL-managed polling is distinguished from unsupported
  automatic/uncoordinated pg_trickle scheduling.
- The installed five-role model replaces the stale four-role/deployer model.
- Troubleshooting uses `pgreact.work.updated_at`, not nonexistent
  `work.created_at`.
- Current upgrade guidance no longer targets `0.30.0`, claims an unproduced RC
  path, or calls `run` during read-only pre-resume verification.
- General typed semantic-key support and M34's one-bigint comparable rule key
  are documented as separate scopes.
- Comparison kind/name/version restrictions and current-only sampled-time
  semantics are explicit.
- Partial comparison evidence is no longer described as having continuation;
  users rerun within the installed `1..1000` bound.
- Current documentation no longer claims byte-identical full comparison
  envelopes, fully measured cost fields, a broader checksum than implemented,
  or a shared production-evaluator implementation path.
- Logical restore is no longer presented as proven portable restoration of live
  pg-react private catalogs.

The stale machine-readable API and finding inventories were not "resolved" by
hand; they remain deliberately deferred to packaged-artifact qualification.

## 5. Claims deliberately narrowed

- **Determinism:** stable semantic results are the intended review boundary;
  elapsed runtime fields prevent a byte-for-byte full-envelope guarantee.
- **Cost evidence:** row counts, affected subjects, would-be work, and elapsed
  time are measured; fan-out, reevaluation, cascade, temporary storage, and
  memory fields are placeholder or unavailable where installed SQL says so.
- **Checksum scope:** the M34 checksum covers selected pg-react frontier,
  declaration, rule-version, activation, decision-subject, public-work, and
  policy-set-version state. It does not hash source tables, lifecycle history,
  attempts, outbox delivery, or all external state.
- **Evaluator equivalence:** tests support bounded semantic outcomes for their
  fixtures. Documentation does not promise the same implementation path as
  production evaluation.
- **Semantic keys:** installed advanced typed-key capabilities are acknowledged;
  rule comparison is promised only for one non-null unique `bigint` key.
- **Logical restore:** the proven model restores application/reference data and
  replays durable declarations, then rebuilds, reconciles, and verifies.

## 6. Unresolved contract questions

| Question | Why repository evidence does not settle it | Affected docs | Classification |
| --- | --- | --- | --- |
| What is the exhaustive classification of every installed public function? | Existing inventories are M33 snapshots and installed `0.31.0` contains additional, moved, legacy, and administrative surfaces. | Contract, API reference, compatibility, deprecations, later API inventory | DOC QUALIFICATION BLOCKER |
| What typed semantic-key scope is an ordinary v1 commitment outside comparison? | Installed advanced codec-v2 surfaces accept broader keys, while ordinary-contract and qualification evidence do not freeze one general promise. | Concepts, authoring, limits, support matrix, API reference | DOC QUALIFICATION BLOCKER |
| Which exact RC/GA upgrade paths are supported? | No `1.0.0-rc.1` SQL/control/package artifact or exercised migration exists. | Upgrade, installation, release notes, support matrix | RC BLOCKER |
| How will the managed runtime recognize RC/GA versions? | `src/managed.rs` invokes managed cycles only when `extversion = '0.31.0'`. | Installation, operations, upgrade, release qualification | RC BLOCKER |
| How are fresh-install comparison grants made durable? | M34 grants comparison only to roles already configured while its SQL runs; a later `configure_roles(...)` call does not grant `compare` or `compare_results`. The docs include the required explicit grant, but the package defect remains. | Installation, security, upgrade qualification | RC BLOCKER |
| What managed batch bound is supported? | `pg_react.batch_size` accepts up to `1000`, but the installed public claim path rejects batches above `100`. Documentation recommends at most `100`; runtime/configuration still disagree. | Installation, limits, operations | RC BLOCKER |
| Which comparison fields are contractual for deterministic repetition? | Runtime measurement fields vary and several cost fields are placeholders. Current prose documents only proven semantics. | Contract, changing policies, limits, roadmap | DOC QUALIFICATION BLOCKER |
| Is shared evaluator implementation a future guarantee? | Installed comparison uses dedicated helpers; tests show bounded semantic agreement, not implementation sharing. | Contract, changing policies, roadmap | NON-BLOCKING FOLLOW-UP |
| Should the no-effect checksum cover more database state? | The installed checksum has a defined narrower selection; broader source, attempt, delivery, and effect coverage is not implemented. | Contract, changing policies, API reference | NON-BLOCKING FOLLOW-UP |
| Is live-catalog logical restore support intended? | Tests prove data/specification replay and reconciliation only. | Backup/restore, operations, support matrix | DOC QUALIFICATION BLOCKER |
| Does RC require the unchecked human usability and pilot records? | Historical readiness records and the automated release lane do not establish one controlling release gate. | Release qualification and future release notes | RC BLOCKER |
| When will names-first ordinary replacement be qualified? | Tests prove create deploy, replacement preview metadata, and stale-digest rejection, but not successful `pgreact.deploy()` replacement for an already deployed rule or decision. A tested advanced names-first rule cutover exists. | Authoring, changing policies, operations | DOC QUALIFICATION BLOCKER |

## 7. Stale API/runtime references remaining

No stale reference remains as a current recommended path.

- `create_rule`, `preview_rule`, and `validate_rule` remain only in an explicit
  compatibility warning.
- `pg-reactd` remains only in accurate compatibility descriptions.
- "No continuation token" remains as the installed comparison limitation.
- Bannered historical documents and historical ROADMAP milestone bodies retain
  their original API/version language.

## 8. Files intentionally not finalized

- `docs/v1-api-inventory.json`
- `docs/v1-finding-codes.json`
- `docs/1.0-release-notes.md`
- exact `0.31.0 -> 1.0.0-rc.N -> 1.0.0` upgrade commands
- exhaustive installed public-function classification
- packaged-RC support, checksum, and qualification records
- names-first ordinary rule/decision replacement
- executable canonical documentation fixtures and CI validation

## 9. Readiness for executable documentation validation

READY FOR STEP 4

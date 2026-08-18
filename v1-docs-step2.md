# pg-react v1 documentation restructuring — step 2

## 1. Inputs and assumptions

- `v1-docs-step1.md` was read completely and used as the required input. Its
  decision record, authority order, change ledger, contradiction ledger,
  competing-guide list, and unresolved questions control this pass.
- Repository state had not materially changed since Step 1. Before these
  edits, every file named in the Step 1 change ledger existed, no tracked
  documentation file had an uncommitted change, and `v1-docs-step1.md` itself
  was the only untracked file.
- M34 / extension `0.31.0` is the v1 feature boundary.
- The release sequence is
  `0.31.0 -> 1.0.0-rc.1 -> later RCs if required -> 1.0.0`.
- M35 is post-v1 and does not block RC or GA.
- This pass changes documentation structure and classification only. It does
  not change product semantics, regenerate inventories, or assert an
  unproduced RC artifact.

## 2. Final documentation architecture

```text
docs/
  index.md
  getting-started.md
  concepts.md
  v1-authoring.md
  changing-policies.md
  v1-installation.md
  v1-operations.md
  v1-security.md
  v1-backup-restore.md
  v1-upgrade.md
  v1-troubleshooting.md
  v1-limits.md
  v1-support-matrix.md
  v1-api-reference.md
  v1-known-limitations.md
  1.0-release-notes.md
  history.md

  v1-contract.md
  v1-compatibility.md
  v1-deprecations.md
  v1-api-inventory.json
  v1-finding-codes.json
```

| Page | Purpose |
| --- | --- |
| `docs/index.md` | Concise documentation home and only primary navigation hub. |
| `docs/getting-started.md` | Route a new PostgreSQL user through fit, install, verification, first rule, and first operational check. |
| `docs/concepts.md` | Explain the pg-react mental model without milestone chronology. |
| `docs/v1-authoring.md` | Canonical rule, decision, and policy-set authoring and deployment guide. |
| `docs/changing-policies.md` | Canonical safe-change, M34 comparison, and comparison-output interpretation guide. |
| `docs/v1-installation.md` | Canonical installation, configuration, and environment-verification procedure. |
| `docs/v1-operations.md` | Canonical production operations runbook. |
| `docs/v1-security.md` | Canonical roles, grants, authorization, redaction, and security policy. |
| `docs/v1-backup-restore.md` | Canonical backup, restore, promotion, reconciliation, and recovery policy. |
| `docs/v1-upgrade.md` | Canonical version-upgrade runbook; RC paths remain unpublished until exercised. |
| `docs/v1-troubleshooting.md` | Canonical symptom, finding, diagnosis, and remediation guide. |
| `docs/v1-limits.md` | Normative safety and resource bounds. |
| `docs/v1-support-matrix.md` | Exact tested environment and unsupported boundaries. |
| `docs/v1-api-reference.md` | Canonical human API lookup and routing page. |
| `docs/v1-known-limitations.md` | Current v1 fit and limitation summary. |
| `docs/1.0-release-notes.md` | Real 1.0 release-note destination; remains an explicit skeleton until an RC exists. |
| `docs/history.md` | Gateway to milestone history and qualification evidence. |
| `docs/v1-contract.md` | Normative v1 semantic and compatibility contract. |
| `docs/v1-compatibility.md` | Normative public-surface classification and compatibility policy. |
| `docs/v1-deprecations.md` | Normative deprecation and removal policy. |
| `docs/v1-api-inventory.json` | Future exact RC API inventory; current M33 snapshot must first be preserved and later regenerated. |
| `docs/v1-finding-codes.json` | Future exact RC finding inventory; current M33 snapshot must first be preserved and later regenerated. |

Normative companions remain separate from tutorials. Milestone documents are
reachable through `docs/history.md`, not through the beginner path.

## 3. File classification

The grouped rows below are exhaustive for milestone families. Within a
milestone family, evidence-like suffixes are classified separately so every
tracked documentation file receives one deterministic classification.

| File or exhaustive group | Classification | Canonical/superseded status | Intended audience | Required later action |
| --- | --- | --- | --- | --- |
| `README.md` | CANONICAL USER DOC | Current overview; not a task runbook | New users | Step 3 correct remaining worker, semantic-key, and supported-feature prose. |
| `CONTEXT.md` | NORMATIVE CONTRACT | Supporting vocabulary; `docs/concepts.md` is the user explanation | Authors, operators, implementers | Reconcile terminology only if Step 3 finds installed-language drift. |
| `DESIGN.md` | HISTORICAL | Superseded M13 architecture; banner added | Maintainers and auditors | Preserve body. |
| `ROADMAP.md` | INTERNAL / PLANNING | Living delivery plan; v1 sequence corrected | Maintainers and release managers | Step 3 reconcile remaining comparison targets with installed evidence and open contract decisions. |
| `AGENTS.md` | INTERNAL / PLANNING | Current repository instruction, outside user docs | Contributors and agents | None for v1 docs. |
| `pg-react-v1-documentation-plan.md` | INTERNAL / PLANNING | Planning input, not authority | Documentation maintainers | Retain for traceability. |
| `v1-docs-step1.md` | INTERNAL / PLANNING | Audit input | Maintainers and auditors | Retain for traceability. |
| `v1-docs-step2.md` | INTERNAL / PLANNING | This restructuring record | Maintainers and auditors | Carry its open questions into later work. |
| `vision/*.md` | HISTORICAL | Noncanonical product vision | Maintainers and product-history readers | Keep outside current user navigation. |
| `docs/index.md` | CANONICAL USER DOC | Canonical documentation home | All users | Keep links current as pages are rewritten. |
| `docs/getting-started.md` | CANONICAL USER DOC | Canonical first-run route | New PostgreSQL users | Step 3 add the exact executable walkthrough. |
| `docs/concepts.md` | CANONICAL USER DOC | Canonical mental model | Evaluators and new users | Step 3 expand only with settled v1 semantics. |
| `docs/v1-authoring.md` | CANONICAL USER DOC | Canonical but materially stale | Rule and policy authors | Major Step 3 rewrite. |
| `docs/changing-policies.md` | CANONICAL USER DOC | Canonical structural skeleton | Authors and operators | Major Step 3 rewrite after comparison questions are settled. |
| `docs/v1-installation.md` | CANONICAL USER DOC | Canonical but materially stale | Installers and operators | Major Step 3 rewrite. |
| `docs/v1-troubleshooting.md` | CANONICAL USER DOC | Canonical but materially stale | Operators and support | Major Step 3 rewrite. |
| `docs/v1-api-reference.md` | CANONICAL USER DOC | Canonical routing skeleton | Authors, operators, integrators | Populate after exact installed-surface classification; do not regenerate inventories in this pass. |
| `docs/v1-known-limitations.md` | CANONICAL USER DOC | Canonical current limitation destination | Evaluators and operators | Expand from settled contract and qualification evidence. |
| `docs/1.0-release-notes.md` | CANONICAL USER DOC | Canonical skeleton; no RC/GA claims | All users and release readers | Populate only from an actual qualified RC/GA artifact. |
| `docs/history.md` | CANONICAL USER DOC | Canonical history gateway | Maintainers, auditors, release-history readers | Keep historical groups linked without rewriting them. |
| `docs/v1-contract.md` | NORMATIVE CONTRACT | Canonical but stale at M33 / `0.30.0` | All contract consumers | Major Step 3 rewrite to M34 / `0.31.0`. |
| `docs/v1-operations.md` | NORMATIVE CONTRACT | Canonical policy/runbook but materially stale | Production operators | Major Step 3 rewrite. |
| `docs/v1-security.md` | NORMATIVE CONTRACT | Canonical policy but materially stale | Security reviewers, DBAs, operators | Major Step 3 rewrite. |
| `docs/v1-backup-restore.md` | NORMATIVE CONTRACT | Canonical policy but incomplete | DBAs and operators | Rewrite after logical-restore scope is decided. |
| `docs/v1-upgrade.md` | NORMATIVE CONTRACT | Canonical policy but contains unproved paths | DBAs and release managers | Rewrite only with exercised artifact paths. |
| `docs/v1-limits.md` | NORMATIVE CONTRACT | Canonical policy but materially stale | Authors, operators, capacity planners | Major Step 3 rewrite. |
| `docs/v1-support-matrix.md` | NORMATIVE CONTRACT | Canonical policy but materially stale | Evaluators, installers, operators | Major Step 3 rewrite without broadening support. |
| `docs/v1-compatibility.md` | NORMATIVE CONTRACT | Canonical companion but incomplete | Integrators and maintainers | Align with exact public-surface classification. |
| `docs/v1-deprecations.md` | NORMATIVE CONTRACT | Canonical companion but incomplete | Integrators and maintainers | Align with exact public-surface classification and history policy. |
| `docs/v1-api-inventory.json` | SUPERSEDED | Stale M33 snapshot, not installed `0.31.0` reality | Qualification tooling and auditors | Preserve under a historical name, then regenerate from the exact RC artifact in a later qualification step. |
| `docs/v1-finding-codes.json` | SUPERSEDED | Stale M33 snapshot missing M34 codes | Qualification tooling and auditors | Preserve under a historical name, then regenerate in a later qualification step. |
| `docs/v1-release-notes.md` | SUPERSEDED | Historical M4 `0.1.1` record; banner updated | Release-history readers | Preserve body; use `docs/1.0-release-notes.md` for v1. |
| `docs/v1-upgrades.md` | SUPERSEDED | Historical M4 `0.1.1` record; banner updated | Release-history readers | Preserve body; use `docs/v1-upgrade.md` for current guidance. |
| `docs/m0-*` through `docs/m32-*` ending in `-entry.md`, `-preentry.md`, `-evidence.md`, `-readiness.md`, `-benchmark.md`, `-performance.md`, `-scale-baseline.md`, `-pilot.md`, `-usability.md`, or `-independent-review.md` | RELEASE / QUALIFICATION EVIDENCE | Retained evidence outside primary navigation | Maintainers, auditors, release-history readers | Preserve. |
| All remaining `docs/m0-*` through `docs/m32-*`, including contracts, compatibility, operations, release notes, upgrades, migrations, tasks, examples, API references, support matrices, and JSON inventories | HISTORICAL | Superseded milestone documentation | Maintainers, auditors, release-history readers | Preserve; do not use as current instructions. |
| `docs/m33-{benchmark,evidence,final-checklist,pilot,readiness,usability}.md` | RELEASE / QUALIFICATION EVIDENCE | Retained `0.30.0` evidence; banners added | Maintainers, auditors, release managers | Preserve; resolve whether human evidence gates RC. |
| `docs/m33-{known-limitations,migration,release-notes}.md` | HISTORICAL | Superseded `0.30.0` user/delivery records; banners added | Maintainers and release-history readers | Preserve body. |
| `docs/m34-{benchmark,evidence,final-checklist,readiness}.md`, `docs/m34-api-inventory.json`, `docs/m34-finding-codes.json` | RELEASE / QUALIFICATION EVIDENCE | Retained `0.31.0` evidence outside primary navigation | Maintainers, auditors, release managers | Preserve; benchmark erratum added. |
| `docs/m34-{api-reference,contract,examples,known-limitations,migration,release-notes}.md` | HISTORICAL | Versioned `0.31.0` records; canonical pointers added | Maintainers, auditors, release-history readers | Preserve body; absorb current facts into canonical v1 pages in Step 3. |

No file is classified `REMOVE`. Immutable evidence and historical release
records remain retained.

## 4. Canonical task routing

| Normal user task | Exactly one canonical document |
| --- | --- |
| Understanding pg-react | `docs/concepts.md` |
| Determining whether pg-react is a good fit | `docs/v1-known-limitations.md` |
| Installation | `docs/v1-installation.md` |
| Environment verification | `docs/v1-installation.md` |
| First rule | `docs/getting-started.md` |
| Rule/policy authoring | `docs/v1-authoring.md` |
| Deployment | `docs/v1-authoring.md` |
| Safe policy change | `docs/changing-policies.md` |
| M34 comparison | `docs/changing-policies.md` |
| Interpreting comparison output | `docs/changing-policies.md` |
| Concepts / mental model | `docs/concepts.md` |
| Production operation | `docs/v1-operations.md` |
| Security and roles | `docs/v1-security.md` |
| Backup and restore | `docs/v1-backup-restore.md` |
| Recovery | `docs/v1-backup-restore.md` |
| Upgrade | `docs/v1-upgrade.md` |
| Troubleshooting | `docs/v1-troubleshooting.md` |
| Limits | `docs/v1-limits.md` |
| Support matrix | `docs/v1-support-matrix.md` |
| API lookup | `docs/v1-api-reference.md` |
| Known limitations | `docs/v1-known-limitations.md` |
| Release notes | `docs/1.0-release-notes.md` |

## 5. Structural changes made

**Files created**

- `docs/index.md`
- `docs/getting-started.md`
- `docs/concepts.md`
- `docs/changing-policies.md`
- `docs/v1-api-reference.md`
- `docs/v1-known-limitations.md`
- `docs/1.0-release-notes.md`
- `docs/history.md`
- `v1-docs-step2.md`

**Files updated**

- `README.md`: points to the documentation home, states the M34 boundary,
  removes milestone guides from primary navigation, and fixes the immediately
  invalid first-rule declarations by adding `kind => 'COMMAND'`.
- `ROADMAP.md`: changes authority away from historical `DESIGN.md`, records
  the M34 boundary and release sequence, removes M35 from v1 success criteria,
  and moves M35 to post-v1 planning.
- `docs/v1-installation.md`: replaces the competing M3 operations link with
  `docs/v1-operations.md`.
- `docs/v1-authoring.md`: removes links to the M5 contract and M3 operations
  guide from the current authoring path.

**Banners added or updated**

- `DESIGN.md`
- `docs/v1-release-notes.md`
- `docs/v1-upgrades.md`
- all nine `docs/m33-*.md` records
- all ten `docs/m34-*.md` records

The `docs/m33-evidence.md` banner records the nonexistent
`tests/m33-security.sql` reference without rewriting the historical body. The
`docs/m34-benchmark.md` banner records that several advertised cost fields are
placeholders or unavailable, not measured evidence. M33/M34 sequencing bodies
remain preserved.

**Links/navigation changed**

- `docs/index.md` is the only primary task navigation.
- README routes current users to `docs/index.md` and milestone readers to
  `docs/history.md`.
- Qualification evidence is reachable through the history page, not exposed
  as a beginner workflow.
- Current installation no longer routes operators to `docs/m3-operations.md`.
- Current authoring no longer routes users to M5 or M3 milestone guides.
- Historical M34 API/examples route current users to
  `docs/v1-api-reference.md` or `docs/changing-policies.md`.

**Removed from primary navigation**

- M0-M34 contracts, evidence, readiness, and milestone API pages
- `docs/m3-operations.md`
- `docs/m32-api-reference.md`
- `docs/m34-api-reference.md`
- `docs/v1-release-notes.md`
- `docs/v1-upgrades.md`
- `DESIGN.md` as current semantic authority

**Intentionally left untouched**

- Runtime code, SQL, tests, Docker configuration, and release workflow
- `docs/v1-api-inventory.json` and `docs/v1-finding-codes.json`
- M0-M32 historical bodies and inventories
- M33/M34 historical bodies apart from concise banners
- Unproved RC artifacts, checksums, upgrade paths, support results, and
  qualification results

## 6. Major rewrites required in Step 3

| Canonical file | Key corrections required |
| --- | --- |
| `README.md` | Correct managed-worker and `pg-reactd` behavior, semantic-key scope, and stale claims that installed advanced reasoning features are future work. |
| `ROADMAP.md` | Reconcile M34 determinism, cost evidence, checksum scope, and evaluator-equivalence targets with installed evidence without guessing open contract decisions. |
| `docs/getting-started.md` | Add one exact executable path for installation verification and a first command rule using the ordinary API. |
| `docs/concepts.md` | Expand the current managed-runtime, lifecycle, declaration, policy, comparison, and support mental model without milestone chronology. |
| `docs/v1-contract.md` | Move the baseline to M34 / `0.31.0`; add comparison APIs and installed restrictions; fix per-database worker topology and scheduling wording; exclude M35. |
| `docs/v1-authoring.md` | Replace legacy UUID-driven APIs with declaration constructors and ordinary verbs; document installed advanced surfaces accurately; correct key-scope wording after that question is settled. |
| `docs/changing-policies.md` | Add exact M34 target restrictions, output fields, completeness/truncation interpretation, limits, authorization, and no-effect wording after the open comparison questions are settled. |
| `docs/v1-installation.md` | Document `pg_trickle,pg_react` preload, managed-worker GUCs, per-database workers, the five-role configuration, restart, protocol 2, and truthful `pg-reactd` compatibility behavior. |
| `docs/v1-operations.md` | Replace abstract procedures with executable managed-runtime and M34 comparison operations; remove M3-era assumptions. |
| `docs/v1-security.md` | Replace the four-role description with four application roles plus the advanced reader; add exact comparison authorization and redaction. |
| `docs/v1-backup-restore.md` | Define the exact logical-restore model and executable managed-worker stop, reconcile, verify, and resume sequence after the restore question is settled. |
| `docs/v1-upgrade.md` | Remove the false `UPDATE TO '0.30.0'` and invented RC paths; keep pre-resume verification read-only; publish only exercised artifact paths. |
| `docs/v1-troubleshooting.md` | Replace nonexistent `work.created_at` with `updated_at`; add exact managed-runtime and M34 findings and remediation. |
| `docs/v1-limits.md` | Add exact comparison bounds and target restrictions; remove the unsupported continuation claim; settle ordinary versus comparable semantic-key scope. |
| `docs/v1-support-matrix.md` | Distinguish managed polling from unsupported pg_trickle scheduling and add exact comparison/key boundaries without broadening the tested tuple. |
| `docs/v1-api-reference.md` | Add complete human-readable signatures and classifications only after the installed public surface is classified; keep generated inventories separate. |
| `docs/v1-known-limitations.md` | Consolidate qualified current limitations, including comparison restrictions and unavailable evidence, without importing post-v1 M35 scope. |
| `docs/v1-compatibility.md` | Classify every installed public function accurately, including export/import, legacy worker/recovery, advanced, compatibility, and incorrectly schemed entries. |
| `docs/v1-deprecations.md` | Align with the exact classification and the historical-document policy. |
| `docs/1.0-release-notes.md` | Remain a skeleton until an actual RC exists; then populate only exact artifact, support, upgrade, qualification, checksum, and limitation facts. |

API and finding-code inventories are deliberately excluded from Step 3 prose
rewrites. Their preservation and regeneration belong to a later
implementation/qualification step.

## 7. Unresolved contract questions carried forward

| Unresolved question | Future documentation or release decision blocked |
| --- | --- |
| What is the exact v1 classification of every installed public function, including `export`, `import`, legacy worker/recovery functions, and incorrectly schemed advanced entries? | `docs/v1-contract.md`, `docs/v1-api-reference.md`, `docs/v1-compatibility.md`, `docs/v1-deprecations.md`, and later inventory regeneration. |
| Does v1 generally support codec-v2 UUID/text/composite rules while M34 comparison is limited to one bigint key, or is the entire v1 rule promise bigint-only? | `docs/concepts.md`, `docs/v1-authoring.md`, `docs/changing-policies.md`, `docs/v1-limits.md`, `docs/v1-support-matrix.md`, and API reference wording. |
| Which exact upgrade paths will the RC package and tests support? | `docs/v1-upgrade.md`, `docs/1.0-release-notes.md`, and RC qualification. |
| How must the managed runtime handle RC/GA version strings when it currently runs cycles only for `extversion = '0.31.0'`? | `docs/v1-installation.md`, `docs/v1-operations.md`, `docs/v1-upgrade.md`, and RC/GA release readiness. |
| Is comparison determinism defined over semantic output excluding measured cost, and are placeholder cost fields contractual? | `ROADMAP.md`, `docs/changing-policies.md`, `docs/v1-limits.md`, `docs/v1-api-reference.md`, and M34/RC qualification criteria. |
| Is “same production evaluator” a contractual implementation guarantee or only an evidenced semantic-equivalence requirement? | `ROADMAP.md`, `docs/v1-contract.md`, `docs/changing-policies.md`, and RC comparison qualification. |
| What exact database state does the comparison no-effect checksum cover? | `docs/v1-contract.md`, `docs/changing-policies.md`, `docs/v1-api-reference.md`, and no-effect qualification. |
| Does logical restore mean declaration/data replay only, or restoration of live pg-react catalogs followed by reconciliation? | `docs/v1-backup-restore.md`, `docs/v1-operations.md`, `docs/v1-support-matrix.md`, and recovery qualification. |
| Must unchecked human usability and pilot evidence be completed before RC, or is the published automated release lane sufficient? | RC readiness, `docs/1.0-release-notes.md`, and release qualification records. |

No question above was resolved by prose invention.

## 8. Readiness for Step 3

READY FOR STEP 3

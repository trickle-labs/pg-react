# Common implementation and release gates

> Applies to proposed pg-react `0.46.0` through `0.51.0`. These are proposed engineering requirements derived from the supplied integration contract and the current release boundary. Source identifiers resolve in [EVIDENCE.md](EVIDENCE.md).

## 1. Estimation and admission rules

Every version has a 30-person-day budget, including integration coding, review, tests, documentation and two days of contingency. A person-day is an effort unit, not elapsed pipeline time. External upstream/MDM implementation and waiting are dependencies, not unpriced React tasks. Required upstream behavior must already exist at the relevant entry gate.

Respect the source's specification-only start policy until the agreed upstream gate passes. Do not treat fixture development as authorized production implementation without an explicit policy amendment. Fixture success never counts as a joint integration pass.

Record the actual predecessor version, source commit, extension versions, PostgreSQL runtime version, image digest, platform, isolation, CDC mode, coordinator ownership and capability response. Re-run admission after upgrades or a capability change. A lost required capability prevents new adapter effects and leaves inspectable blocked state. Delta V1 stays unused in this sequence.

## 2. One authority model

The core extension works without MDM installed. The optional adapter uses only approved public MDM relations and functions; no MDM private catalogs, direct review writes, identity changes, human approval calls, or nested refreshes are allowed. Generic pg-react internals must not become an MDM-specific rule language.

Start with one administrative scope, one active routing binding, a non-RLS policy projection and explicit grants. Prove negative permissions as ordinary roles, including indirect source exposure and hostile `search_path`. No `BYPASSRLS`, superuser evaluation as a convenience, or a view that disguises an RLS-backed source.

Contract/interface installation may need an installer role. Runtime submission must use the least privileged identity capable of the signed intent operation. Prove that this identity cannot approve reviews or alter MDM identity decisions. Do not infer capability from successful function lookup alone. [S0 §§1–3, S2]

## 3. Delivery and immutable identity

For every real work item persist, before the first attempt, its canonical encoding version, stable request key, complete body, public policy/work identity, and the MDM review/concurrency identities needed by the signed contract. Preserve the source key recipe:

```text
binding ID + policy revision + case occurrence + lifecycle generation
+ action-driving revision + consequence identity + escalation level
```

Specify typed and unambiguous encoding, null handling, normalization and stable test vectors. A different request body cannot share a key. A retry cannot recompute its payload from current tables. Operator-requested reevaluation creates new work when an intended action changes; it does not edit old attempted work.

MDM intent submission, receipt association and React database-work completion must share one PostgreSQL transaction. Inject failures between each step and prove the entire local operation rolls back. Replayed attempts after an uncertain commit must reuse the same identity and reconcile against MDM's idempotency response. This is not a claim of exactly-once delivery outside PostgreSQL.

Treat `APPLIED_CONTROL` as control delivery only; `ACCEPTED_PENDING_PUBLICATION` remains separate from `APPLIED_PUBLICATION` and business resolution. Stale/superseded work is terminal and triggers explicit reevaluation. Denied, invalid and idempotency-conflict outcomes stop work and require correction. Only contract-classified transient failures use bounded retry. Unknown outcomes fail closed. [S0 §6]

## 4. Lifecycle, policy replacement and pause

Version policy packages and bind their digest to the MDM automation binding. In a supported single local transaction, change the policy and corresponding binding together. Otherwise keep the binding disabled across the transition, validate both sides, and activate explicitly. Incompatible queued work must be held or withdrawn; completed attempted payloads remain immutable.

A pre-check in React alone cannot prevent a replacement race. MDM must validate the expected active binding/digest within the same atomic action that applies the intent, or supply an equivalent documented locking contract. Test both lock orders and both outcomes.

Define pause at a precise linearization point: no new intent may be accepted after the acknowledged pause barrier. An intent accepted before that point is not undone. A persisted pause flag without handling in-flight work is insufficient evidence. Reversal is an explicit separately authorized MDM action, never a compensating action invented by React. [S0 §7]

## 5. Required evidence matrix

| Gate ID | Suite | Minimum evidence |
|---|---|---|
| C01 | Exact stack and capability admission | Real versions/digests; enabled/disabled/missing/unsupported-major cases; rejection before side effects |
| C02 | Core isolation | Fresh core install without MDM; adapter disabled/absent leaves ordinary policies functional |
| C03 | Authorization | Installer, author, runtime, observer and unauthorized-role cases; fixed search path; rejected RLS sources; no human approval privileges |
| C04 | Ordinary compatibility | Existing valid authoring/review/deploy/replace/inspect calls remain valid; expected errors and stale-review rejection retained |
| C05 | Fresh and adjacent install | Deterministic fresh artifact; populated predecessor upgrade; schema/API inventory agrees; adapter installed and absent variants |
| C06 | Atomicity and retry | Duplicate requests, concurrent claims, same-key/different-body conflict, deadlock/rollback and uncertain-commit replay |
| C07 | Concurrent stewardship | Human changes, case closure/reopening, source/evidence revision changes, binding replacement and pause races |
| C08 | Feedback and time | Audit-only updates do not create work; time-only expiry does; recurrence and every bounded escalation level tested |
| C09 | Comparison | Fixed population with exact coverage; partial results not accepted as complete; no effect calls or selected/unselected state mutations |
| C10 | Recovery and clones | Restart, coherent populated backup/restore, failed upgrade recovery, disabled-effect clone boot, explicit resumption |
| C11 | Resource bounds | Representative load, queue growth, backlog drain, database writes/WAL/storage and retained receipt/key horizon measured; unavailable metrics labeled |
| C12 | Packaged qualification | Exact artifact under test is the artifact published; full logs and structured failures retained; no required skips |

Apply a gate to the behavior present in a release. Before real delivery exists, C06/C07 must still prove no-effect boundaries and applicable deployment races; absence of delivery is not evidence that future delivery semantics pass. Record later tests as deferred to their named owning version. The rollout release reruns every applicable earlier gate against the final joint stack.

## 6. Evidence format and numeric limits

Write a machine-readable release evidence record containing release and source identities, contract digest, environment, test ID, command, expected result, actual result, status, artifact/log references and required/optional classification. Proposed location: `tests/integrations/pg-mdm/evidence/<version>/` for schema and manifests; retain generated logs as release artifacts rather than committing large mutable logs.

Record numeric limits before qualification: cohort size, case churn, queue/level bounds, poll interval, time-only response budget, backlog drain budget, receipt/key retention horizon, database storage/WAL growth and recovery time budget. These documents do not invent achieved throughput or latency. Freeze workload-specific numbers in the signed qualification manifest after baseline measurements and before acceptance; blank thresholds block qualification.

Correctness budgets are already fixed: zero unauthorized controls, zero same-request duplicate controls, zero controls from stale/disabled bindings, zero unexplained population omissions, zero clone effects before activation, and zero required tests silently skipped. Ordinary compatibility and safety cannot be traded for throughput. [S0 §8; S3, S5]

## 7. Upgrade, restore and clone protocol

Append adjacent migration SQL; never edit published install/upgrade history. Preserve valid ordinary calls. Version the optional adapter explicitly and qualify it with the matching core release. A planning-only merge must not bump the released version.

Before a live upgrade, pause adapter acceptance and reach its barrier, preserve a consistent whole-database recovery point and exact matching binaries, inventory pending/leased/retry work, request snapshots, bindings, MDM receipts and publication references. Upgrade the tested sequence. Start with adapter effects disabled, verify integrity and capability admission, then resume deliberately.

On migration failure, roll back the transaction where supported. If binary/runtime recovery is required, restore the coherent database and matching prior artifacts; do not promise reverse `ALTER EXTENSION` migrations. Do not restore React request state independently of corresponding MDM receipts/control state. Already accepted business directives are not undone by an adapter pause.

A byte-for-byte clone cannot be assumed to identify itself from copied database rows. The supported restore/clone deployment procedure must prevent adapter execution before an environment-specific operator activation check, for example through a validated startup configuration or equivalent agreed external guard. A copied persisted `enabled` flag is not sufficient. Prove the actual launch procedure in CI. Deployments that bypass it are outside the qualified clone-safety contract; do not claim automatic detection of arbitrary clones. Clone activation cannot rewrite an existing attempted request key. [S0 §§6–8]

## 8. Completion and scope control

Release qualification requires code installed and exercised, independent review, complete source/evidence links, updated support/limits/recovery documentation and no open critical correctness or authorization defect. A fixture-only deliverable is labeled fixture-only; a blocked upstream gate remains blocked.

If a plan exceeds 30 person-days, first remove optional sample variety, dashboards, convenience helpers or performance polish that is not required for the named workload. Re-estimate or split newly discovered semantics into another approved version. Never silently omit idempotency, authorization, transactional boundaries, temporal liveness, immutable work, or restore evidence.

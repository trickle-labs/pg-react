# pg-react: detailed project assessment

**Assessment date:** 7 September 2026  
**Project:** [trickle-labs/pg-react](https://github.com/trickle-labs/pg-react)  
**Reviewed revision:** [`3807329e3a6c6ff44087b715867d6455bc907390`](https://github.com/trickle-labs/pg-react/commit/3807329e3a6c6ff44087b715867d6455bc907390), `main`, 1 September 2026  
**Release:** [0.43.1, M54](https://github.com/trickle-labs/pg-react/releases/tag/v0.43.1)  
**Scope:** correctness, authorization, deployment safety, operational recovery, performance, API ergonomics, maintainability, documentation, tests, and release engineering.

## 1. Overall assessment

pg-react is a PostgreSQL extension for reactive rules, decisions, policy sets, and durable consequence execution. Despite its name, it is not a React frontend library. Its architecture combines SQL and PL/pgSQL state machines with a comparatively small Rust/pgrx extension and a managed background worker. The supported release configuration is PostgreSQL 18.3, pg_trickle 0.81.0, pgrx 0.18.0, and Linux amd64, with READ COMMITTED execution. These constraints are explicit in the [current project documentation](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/README.md).

The project has substantial strengths: durable lifecycle state, explicit leases and retries, reviewed deployment concepts, ownership checks, bounded evidence interfaces, a broad SQL test corpus, and unusually careful release artifact qualification. It also has important implementation gaps in exactly the areas on which users must rely: permission boundaries, what a review actually approves, whether comparison holds facts constant, and whether recovery evidence proves recoverability.

**My recommendation is to prioritize a hardening release before broad production adoption by multiple application roles.** A controlled evaluation is reasonable. Treat the authorization findings, comparison execution context, deployment preconditions, and backup qualification as release gates. Performance work should follow with measured workloads; several expensive algorithms can already be identified from source without inventing throughput estimates.

This is a risk-focused source assessment, not a certification or an exhaustive audit of every historical migration. Eighteen findings are detailed below. The source mechanisms were inspected at the pinned revision, but PostgreSQL execution scenarios were not reproduced locally because the required runtime was unavailable. The report distinguishes local checks, analytical examples, and existing upstream CI evidence throughout.

### Priority summary

P1 means address before relying on the affected behavior in production. P2 means schedule in the next hardening cycle, or sooner if the affected feature is central to a deployment. Priorities account for exposure and operational impact; they are not CVSS scores.

| ID | Priority | Finding | Main consequence |
| --- | --- | --- | --- |
| F01 | P1 | Fresh role configuration omits M54 API grants | Ordinary application roles cannot use new reviewed deployment and recovery APIs |
| F02 | P1 | Renaming and recreating functions restores default PUBLIC execution | Configured reader/operator roles can cross the intended author API boundary |
| F03 | P1 | Comparison executes source views as a definer and checks RLS only on the top relation | Caller-visible data can differ from data exposed through comparison |
| F04 | P1 | Ordinary deployment ignores existing JSON replacement preconditions | Stale updates can overwrite a newer declaration |
| F05 | P1 | Old-work consent depends on the proposed rule kind | COMMAND-to-CONSTRAINT replacement silently chooses to drain old work |
| F06 | P1 | Reviewed plan fingerprints omit executable and transitive definitions | A reviewed token can survive a meaningful code or dependency change |
| F07 | P1 | Comparison mixes stored current results with live proposed facts | Data changes can be reported as policy changes |
| F08 | P2 | Retry backoff casts to integer before applying its cap | Valid retry settings can fail inside error handling |
| F09 | P1 | A pre-dispatch error can roll back a complete managed cycle | One damaged job can prevent unrelated work from making progress |
| F10 | P1 | Package dependency walks enumerate paths exponentially | A small valid package can exhaust time and temporary storage |
| F11 | P1 | Backup/rollback qualification copies live PGDATA and makes weak assertions | Passing qualification overstates recovery assurance |
| F12 | P2 | Name-based lease recovery omits draining rule versions | Expired old-version leases can remain stranded |
| F13 | P2 | Managed status can report ready after a blocked run | Liveness is mistaken for successful progress |
| F14 | P2 | Package preview can say KEEP for a changed child that deployment rejects | Reviewed plans are not reliably executable |
| F15 | P2 | Work view misstates claimability and update time | Operator queries and integrations make incorrect decisions |
| F16 | P2 | Typed constructors serialize identifiers using search_path-dependent text | Valid typed inputs can produce invalid declarations |
| F17 | P2 | Bounded comparison performs global checksums and repeated full scans | Small evidence requests become expensive as unrelated state grows |
| F18 | P2 | Obsolete scheduled workflows build current source against historical expectations | Predictable CI failures obscure useful signals |

## 2. Architecture and project health

### What the implementation is optimizing for

The principal layers are:

| Layer | Responsibility | Assessment |
| --- | --- | --- |
| Public declaration API | Construct, validate, preview, deploy, inspect, compare, and remove named declarations | A useful application-facing model, but contracts and grants have diverged across wrappers |
| SQL runtime | Maintain rule versions, activations, lifecycle events, work, decisions, dependencies, and barriers | Most correctness and performance risk lives here |
| Managed worker | Coordinate refresh, claim durable work, and execute consequences | Simple operational model; transaction scope creates a large failure domain |
| Rust extension | PostgreSQL integration, identity/lifecycle helpers, query-tree inspection, and worker startup | Small enough to review independently; PostgreSQL integration still needs runtime tests |
| Release system | Build and qualify an image, archive evidence, and publish the qualified artifact | Strong foundation that should be retained while fixing the meaning of individual gates |

The major maintenance issue is cumulative layering. Current behavior often requires tracing a public wrapper through several renamed milestone functions. Merely reading the latest `CREATE FUNCTION` or the newest milestone file is insufficient.

### Size and complexity measured locally

| Area | Measured size | Interpretation |
| --- | --- | --- |
| Tracked repository | 888 files; 62,944,491 bytes | Much of the volume is historical/generated SQL |
| Rust source | 6 files; 1,167 lines | SQL dominates the implementation |
| SQL files | 105 files; 1,244,443 lines; 59,373,260 bytes | Repeated cumulative installation versions inflate the count |
| Current 0.43.1 installation SQL | 49,196 lines; 2,358,723 bytes | Large enough that final effective behavior is difficult to inspect manually |
| Function creation statements in current installation SQL | 896 statements; 620 distinct function names | These are source counts, not the number of installed function OIDs or overloads |
| Tests directory | 311 files; 38,225 lines | Extensive evidence infrastructure exists |
| Markdown documentation | 394 files; 26,512 lines | Strong documentation investment, with considerable historical material |

For example, the cumulative installation script contains 22 creation statements named `pgreact_api.configure_roles`. This includes redefinitions and overloads, but still illustrates how easily final grants can diverge from newly added APIs. [Current installation SQL](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql)

### Strengths worth preserving

- **Explicit state and ownership.** Rule versions, work states, leases, consequence digests, owner checks, and recovery operations are first-class concepts rather than incidental application conventions.
- **Careful release artifact handling.** Qualification builds and exercises a candidate, and release publication uses the qualified artifact with digest and identity checks. Pinned dependencies, image metadata, an SBOM, and attestations are valuable foundations. [Qualification workflow](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/.github/workflows/qualification.yml), [release workflow](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/.github/workflows/release.yml)
- **Good user-facing concepts.** Named declarations, reviewed previews, explicit old-work policies, structured findings, and names-based operations can make a complex database runtime approachable.
- **A substantial regression corpus.** SQL, concurrency, failure, installation, and historical compatibility fixtures already exist. The right next step is to improve the coverage and assertions of the current release gate.
- **Clear support boundaries.** Documenting supported PostgreSQL versions, isolation, source restrictions, and bounded evidence is preferable to implying universal support.
- **Current documentation consistency checks.** The local current-release audit passed; a separate check found no broken relative links in the 21 current documentation files examined.

## 3. Detailed findings

All reproduction scenarios in this section are proposed regression tests unless explicitly labeled as locally checked. “Source confidence: high” means the cited control flow or expression is present and its relevant call path was inspected; it does not claim that the complete scenario was executed against PostgreSQL in this assessment.

### F01 — Fresh role configuration omits new API grants

**Priority:** P1. **Source confidence:** high. **Affected scenario:** install 0.43.1 into a fresh database, then configure non-superuser application roles.

M54 revokes PUBLIC access to `review_token(jsonb)`, the token-taking deploy overloads, and three recovery functions. It grants them in an installation-time `DO` block by reading `pgreact_internal.application_roles`. A fresh installation has no configured application roles at that point. The final `configure_roles` definition delegates to `configure_roles_m43` and adds package constructors and views; it does not grant the M54 functions.

The resulting behavior depends on installation history. An upgrade with roles already configured receives the new grants, while fresh configuration does not. Later role changes have the same synchronization problem. This makes the documented normal workflow fail for the roles intended to use it. [M54 revokes and one-time grants](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L944-L974), [final role configuration](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m53.sql#L2377-L2394)

**Recommended change:** centralize current API grants in one idempotent routine called by both migrations and `configure_roles`. Define intended behavior when configured roles change, including revocation from superseded roles where appropriate.

**Regression test:** use fresh databases and actual separate login sessions for author, operator, reader, and worker roles. Assert effective privileges for every supported signature, then call the public workflow. Repeat for adjacent upgrade, repeated configuration, and role rotation. Running everything as `postgres` cannot detect this defect.

### F02 — Recreated functions regain PUBLIC EXECUTE

**Priority:** P1. **Source confidence:** high. **Affected scenario:** configured application roles have schema access but should not have author privileges.

M54 renames `remove`, `validate`, `preview`, and the JSON-taking `deploy` function to historical names, then creates new functions with the original names. The earlier explicit revokes remain attached to the renamed function OIDs. The new functions receive PostgreSQL's default PUBLIC EXECUTE privilege, and M54's final revocation block does not revoke these four signatures. There is no extension-local default-privilege change in the installation script that closes the gap. [Rename/recreate sequence](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L758-L826), [previous explicit revokes](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m53.sql#L2360-L2369), [PostgreSQL function security rules](https://www.postgresql.org/docs/18/sql-createfunction.html)

This is not anonymous access to every database: schema USAGE and underlying ownership checks still matter. However, configured readers and operators receive schema access. A reader who owns an otherwise valid source can reach a SECURITY DEFINER deployment entry point through PUBLIC EXECUTE, bypassing the intended author-only API grant. Existing target ownership checks do not substitute for checking permission to author new targets. [Schema grants](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L35420-L35440)

**Recommended change:** revoke PUBLIC access to every recreated public entry point in the same migration transaction, then grant the exact intended role matrix. Generate these statements from a canonical API inventory if practical.

**Regression test:** assert both allowed and forbidden calls. In particular, a reader with SELECT and ownership of a valid source must still be unable to deploy or remove through an author-only API. Inspect effective privileges with `has_function_privilege`; a catalog checksum alone can faithfully record an incorrect ACL.

### F03 — Comparison evaluates views with a different security context

**Priority:** P1. **Source confidence:** high for the mechanism; the tenant-data scenario needs database confirmation. **Affected scenario:** comparison of caller-accessible views, particularly views over RLS-protected relations.

`m34_require_source` checks `relrowsecurity` only on the supplied relation OID and checks that `session_user` has SELECT. `m34_rule_rows` then executes dynamic SELECTs inside a SECURITY DEFINER function. For a view, the top relation's `relrowsecurity` does not establish whether its dependencies use RLS. The declaration validation path checks shape and relation existence, rather than invoking the full source-registration security validator before these reads. [Source checks and dynamic execution](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m34.sql#L93-L203), [comparison path](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m34.sql#L715-L795), [declaration validation](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m32.sql#L218-L356)

For a `security_invoker` view, underlying permission and RLS checks follow the user executing the query. Here that can be the extension function owner, commonly a privileged installation role, rather than the application caller. Functions evaluated inside a view also require careful treatment of this execution context. Checking that the caller may SELECT the view does not make definer-context evaluation equivalent to a direct caller SELECT. [PostgreSQL view security semantics](https://www.postgresql.org/docs/18/sql-createview.html)

**Recommended change:** enforce the declared unsupported-RLS boundary transitively before source evaluation. Establish an explicit execution identity for ad hoc comparison, validate relevant function dependencies, and avoid evaluating arbitrary caller-selected views under the extension owner's broader privileges. Reuse a shared source-safety policy across deploy, compare, simulation, and explanation paths.

**Regression test:** start with a benign view returning `current_user` and compare direct SELECT against evidence output. Then use two tenant rows, a non-superuser application login, RLS on the base relation, and a `security_invoker` view. The comparison must either reject the unsupported source or preserve the caller's authorized visibility. Test nested views as well as direct relations.

### F04 — Ordinary deployment ignores legacy replacement preconditions

**Priority:** P1. **Source confidence:** high. **Affected scenario:** clients using the existing JSON precondition API for intentional replacement.

The earlier deployment implementation validates `allow_create` and requires an exact `expected_current_digest` for replacement when `allow_create=false`. M54 replaces the ordinary rule/decision path with `m54_deploy`, which checks a reviewed token when supplied and checks `preview_digest`, but never reads `allow_create` or `expected_current_digest`. An ordinary JSON `plan_digest` is also not checked on this path. [Earlier replacement guard](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m28.sql#L358-L385), [M54 replacement path](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L534-L756)

Consequently, a caller can explicitly provide a stale expected digest and still replace the target. The advisory lock serializes writers, but does not establish that the second writer approved the state left by the first. This is a lost-update problem. The new reviewed-token overload has real checks; its existence does not make silently ignored compatibility preconditions safe.

**Recommended change:** preserve supported precondition semantics in a common validator, or reject unsupported keys with a clear migration error. Distinguish a declaration digest, a source fingerprint, and a plan digest in the API contract. Do not imply that an accepted field was enforced when it was ignored.

**Regression test:** deploy A, capture its digest, replace it with B, then attempt C with `allow_create=false` and A's digest. C must fail without changing B. Add explicit tests for malformed precondition fields and every accepted digest field. The historical name `allow_create` is confusing: do not reinterpret it without a documented compatibility decision.

### F05 — COMMAND-to-CONSTRAINT replacement guesses the old-work policy

**Priority:** P1. **Source confidence:** high. **Affected scenario:** a command rule has outstanding work and is replaced with a constraint rule.

`m54_preview` requires an old-work policy only when the **proposed** declaration's kind is COMMAND. If the currently deployed rule is COMMAND but the proposal is CONSTRAINT, the requirement is false even when old work is pending, leased, or waiting to retry. Deployment then passes `COALESCE(old_work, 'DRAIN_OLD')` to replacement. [Requirement predicate](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L281-L299), [replacement default](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L650-L684)

This conflicts with the documented promise that outstanding work requires an explicit DRAIN_OLD or CANCEL_OLD choice. A user converting a rule into a constraint can unintentionally allow old effects to continue. The predicate was checked locally with a small analytical model; the PostgreSQL transition itself was not executed. [Replacement contract](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/docs/m54-api-reference.md)

**Recommended change:** derive the requirement from the deployed version and its outstanding effect-bearing work, independent of the proposed kind. Return the exact affected old version and work counts in the reviewed plan.

**Regression test:** cover COMMAND→COMMAND, COMMAND→CONSTRAINT, and CONSTRAINT→COMMAND with PENDING, LEASED, RETRY_WAIT, and drained old versions. Missing consent must fail whenever old work will survive or be canceled.

### F06 — Reviewed fingerprints omit meaningful executable changes

**Priority:** P1. **Source confidence:** high. **Affected scenario:** a source dependency or consequence function changes between preview and deployment.

The M54 source fingerprint covers directly named relations and either their top-level `pg_get_viewdef` output or a row-shape signature. The plan digest includes normalized declaration text, current declaration state/digest, that source fingerprint, and a summary work state. It does not include consequence function bodies or recursively fingerprint nested view definitions. [Source fingerprint](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L123-L156), [plan digest inputs](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L273-L299)

A consequence function can keep its name/signature while its body changes. An ADD or REPLACE token can therefore remain valid while deployment binds the new executable definition. Likewise, replacing a nested view can change behavior without changing the top view's textual definition. Direct source-view changes are checked and tested; the gap is the incomplete dependency closure.

**Recommended change:** define precisely what a review freezes. Include the executable consequence/dispatcher definitions and a bounded, canonical dependency closure, with relevant ownership/security properties. Recheck those dependencies under an appropriate locking or version-validation strategy before mutation. If function-body changes are intentionally outside review scope, state that explicitly and provide a separate executable approval mechanism.

**Regression test:** preview, replace a consequence body without changing its signature, and deploy with the old token. Repeat for a nested view and a security-property change. Each material change must invalidate the review or be covered by an explicit documented alternative. A token need not be a secret or authorization credential; that is a separate concern.

### F07 — Comparison does not hold current facts constant

**Priority:** P1. **Source confidence:** high. **Affected scenario:** source facts change after the latest runtime refresh but before comparison.

Ordinary rule comparison reads the proposal from the live source using `m34_rule_rows`, while the current model comes from `m34_current_rule_rows`, which reads stored `pgreact.matches`. Validating a requested sampled time against the runtime frontier does not freeze the live source at that frontier. [Current/proposed evaluation](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m34.sql#L779-L795), [stored current rows](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m34.sql#L205-L242)

After an insert, update, or delete during a normal polling gap, comparing an unchanged declaration can produce a difference caused by data freshness. That undermines the guide's promise to vary the declaration while holding authoritative facts constant. [Documented comparison model](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/docs/changing-policies.md#L5-L15)

**Recommended change:** evaluate both declarations against one consistent fact snapshot, or reject comparison when the stored state cannot be shown to represent that snapshot. If comparing observed runtime state to a live proposal is also useful, expose it as a separately named mode with explicit freshness metadata. Preserve the read-only contract; an implicit refresh inside comparison is not a harmless implementation detail.

**Regression test:** pause the managed worker after a successful refresh, mutate authoritative facts, and compare an identical declaration. A same-facts comparison must not attribute those mutations to a declaration change. Cover inserts, deletions, changed values, and nested source views.

**Related semantic issue:** proposed rule rows hard-code `would_be_work=true`, and the work output is assembled from proposed matches. This needs a lifecycle-aware contract: an unchanged CONSTRAINT match is not necessarily a new consequence. Add a regression requiring work projections to distinguish matches, lifecycle transitions, and executable consequences. [Proposed work annotation](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m34.sql#L181-L203), [comparison work assembly](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m34.sql#L875-L918)

### F08 — Retry backoff overflows before it is capped

**Priority:** P2; raise priority for high-retry workloads. **Source confidence:** high. **Affected scenario:** permitted retry settings with enough repeated failures.

The retry handler computes:

```sql
LEAST(episode.retry_max_seconds,
      (episode.retry_initial_seconds
       * power(episode.retry_multiplier, attempt - 1))::integer)
```

The cast happens before `LEAST`. With initial delay 1, multiplier 2, maximum delay 60, and more than 32 permitted attempts, attempt 32 computes 2,147,483,648 and overflows PostgreSQL's signed integer before the result can be capped at 60. The authoring path allows up to 100 attempts. [Retry handler](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L1887-L1906), [retry bounds](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L1620-L1635)

The numeric example was checked locally as arithmetic. The failure occurs inside the exception handler, so it can escape the normal retry bookkeeping and interact with F09.

**Recommended change:** cap in a sufficiently wide numeric type before narrowing to integer. Also guard exponentiation itself for extreme permitted multipliers; moving the cast alone is not a complete saturation strategy.

**Regression test:** use a failing consequence with 40 attempts and verify attempts 31, 32, and later retain the configured capped delay and persist their attempt state. Include boundary multipliers and maximum delays. Default single-attempt workloads do not exercise this case.

### F09 — One pre-dispatch failure can roll back unrelated jobs

**Priority:** P1. **Source confidence:** high. **Affected scenario:** a managed batch contains a job with source, consequence, dispatcher, or lease drift.

The Rust worker invokes `pgreact_api.managed_cycle()` inside one transaction. The SQL cycle refreshes, claims a batch, and executes jobs within a block with one outer exception handler. Several checks in the execution path raise before the inner consequence exception block, including source-row-signature and consequence/dispatcher drift. [Worker transaction](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/src/managed.rs#L139-L153), [managed cycle](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L21341-L21419), [pre-dispatch checks](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L1816-L1868)

An escaping error rolls back the block's earlier database changes, including successful work earlier in the cycle. The outer handler records a process error, but the damaged work can be selected again. This creates a potentially persistent progress failure for unrelated rules, not just a failed individual consequence. The latest execution wrapper does not introduce per-job exception isolation. [Current execution wrapper](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L35196-L35258)

**Recommended change:** make the transaction boundary explicit. Isolate each job's validation and execution with durable blocked/failure bookkeeping; consider committing coordination separately from bounded job transactions. Preserve atomicity between a database consequence and that job's completion state. Do not introduce parallel execution until barriers and conflict leases are tested under the new boundary.

**Regression test:** enqueue healthy A, damaged B, and healthy C; change B's consequence definition after registration. Verify A and C eventually commit, B becomes visibly blocked, and repeated worker cycles do not undo unrelated progress. Also test a lease expiring while earlier jobs run.

### F10 — Package dependency processing has exponential path growth

**Priority:** P1. **Source confidence:** high; complexity demonstrated analytically. **Affected scenario:** valid acyclic packages with converging and diverging dependencies.

Package validation checks cycles with a recursive `UNION ALL` walk carrying paths. Preview computes dependency ranks with another `UNION ALL` walk. These enumerate paths rather than processing each vertex and edge a bounded number of times. The documented limits on members, support objects, edges, and payload bytes do not bound the number of paths. [Cycle validation](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m53.sql#L1452-L1467), [preview rank walk](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m53.sql#L1719-L1743)

A layered acyclic graph with one root and 30 layers of two nodes has only 61 nodes and 118 edges. Each node in a layer depends on both nodes in the previous layer. It has 1,073,741,824 longest paths; the preview walk can produce 2,147,483,647 path rows across all depths. This fits the stated 64-member and 256-edge limits. These counts were calculated locally without attempting to materialize the graph in PostgreSQL.

**Recommended change:** use a topological-sort algorithm such as Kahn's algorithm for ordering and cycle detection, or another implementation with a demonstrated bound on distinct states. Deduplicating whole paths is not enough. Enforce cheap structural limits before expensive graph processing and apply a defensive execution budget.

**Regression test:** add the layered DAG, wide fan-in, disconnected graphs, duplicate edges, and a cycle near the end of an otherwise valid graph. Assert bounded completion and memory behavior, not merely correct output on a small chain.

### F11 — Backup and rollback qualification does not prove the stated recovery case

**Priority:** P1 for release assurance. **Source confidence:** high. **Affected scenario:** reliance on the complete M54 qualification lane as evidence of populated upgrade and rollback safety.

The complete lane creates a 0.43.0 database and a one-row ordinary table, then archives the running database volume using `tar`. It does not stop PostgreSQL, use `pg_basebackup`, or take an atomic filesystem snapshot. A read-only mount for the copying container does not stop the database from changing the source files. Ordinary file copying of a running cluster is not PostgreSQL's supported consistent filesystem-backup procedure. [Qualification implementation](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/tests/m54.sh#L115-L134), [PostgreSQL filesystem backup requirements](https://www.postgresql.org/docs/18/backup-file.html)

There are two additional weaknesses:

- The earlier populated SQL test database is destroyed before this lane. The upgrade fixture contains an application table, not representative extension state such as deployed rules, package ownership, pending work, retries, leases, or configured roles.
- Several checks run `SELECT extversion = ...` or `SELECT * FROM fixture` and only require the command to succeed. `ON_ERROR_STOP` does not turn a false Boolean or missing expected rows into an assertion failure. Version polling adds some checking, but it does not establish fixture contents or runtime invariants.

The test also exercises old SQL installation state using the candidate image. It does not by itself prove restoration with the actual matching previous release artifact. These are gaps in evidence, not proof that a published backup has already been corrupted.

**Recommended change:** use a stopped-cluster copy or a supported physical backup with the required WAL. Restore into an isolated instance using the correct previous artifact. Seed representative extension state before backup and use assertions that fail on wrong versions, row counts, digests, ownership, queue state, or inability to resume safely.

**Regression test:** restore a fixture with active rules, package-owned members, pending/retry/leased work, and distinct application roles. Verify exact pre-backup invariants, then perform controlled recovery and prove no lost work or duplicate committed database effects. Include a failed-upgrade rollback case rather than only the successful adjacent upgrade.

### F12 — Name-based sweeping misses old draining versions

**Priority:** P2. **Source confidence:** high. **Affected scenario:** DRAIN_OLD replacement after a worker has leased old-version work.

Replacement can leave the old version DRAINING with PENDING, LEASED, or RETRY_WAIT work. `sweep_expired_leases(rule_name)` resolves only ACTIVE or PAUSED versions. The global claim loop discovers candidate versions through PENDING/RETRY_WAIT jobs and invokes per-version claim logic, where sweeping occurs. An old draining version containing only expired LEASED jobs can therefore be missed by both the name-based operation and normal candidate discovery. [Draining replacement](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L513-L530), [name-based sweep](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L891-L913), [global claim selection](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L13979-L14006)

UUID-based recovery remains available, so this is not an assertion that recovery is impossible. It is a gap in the ordinary names-based recovery workflow and automatic progress.

**Recommended change:** resolve all recoverable versions of the named rule, authorize each, and report per-version results. Discover expired leases independently of whether another pending job exists for the same version.

**Regression test:** claim old work, simulate worker loss, replace with DRAIN_OLD, allow the lease to expire, and recover using only the public rule name. Verify the old version eventually drains and can reach its terminal state.

### F13 — Managed health can say ready when coordination is blocked

**Priority:** P2. **Source confidence:** high. **Affected scenario:** `run()` returns a structured BLOCKED result instead of raising.

The current run wrapper converts certain failures into a JSON result with `runtime_state=BLOCKED`. Managed cycle stores that result in `run_result`, but does not inspect it when setting process state. It can finish with `state=ready` and clear `detail`. The Rust `Spi::run` invocation also does not inspect the returned JSON. [Blocked run result](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L34925-L34984), [managed state handling](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L21378-L21408)

The process may be alive while the authoritative frontier cannot advance. Other doctor output can expose problems, but a ready managed status is still misleading to operators and monitoring integrations.

**Recommended change:** separate process liveness, successful coordination, and work execution health. Propagate blocked/error state and cause, retain last successful frontier/time, and expose progress lag. Define how partial progress is represented.

**Regression test:** force a supported structured BLOCKED response and assert managed status is degraded with a durable explanation. Then resolve the cause and verify recovery clears the right fields while preserving useful history.

### F14 — Package preview and deployment disagree about changed members

**Priority:** P2. **Source confidence:** high. **Affected scenario:** a typed member declaration changes while the same logical member already belongs to the deployed package.

Package preview assigns KEEP based on deployed identity and membership, without comparing the proposed child declaration digest in that decision. Deployment later checks the existing child's digest against the proposed declaration and raises `M53_POLICY_ADOPTION_DIGEST` if they differ. The preview can therefore be ready with a KEEP action even though the same proposal cannot deploy. [Preview action selection](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m53.sql#L1747-L1764), [deployment digest check](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m53.sql#L1905-L1942)

M54 separately prohibits editing a package-owned child through ordinary deployment and instructs callers to replace the whole policy set. The package update workflow needs a consistent answer for changing such a child. Immutable package versions can be an intentional design choice; a ready but non-executable preview is still a defect. [Package-owned child restriction](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L638-L648)

**Recommended change:** compare child digests while constructing the plan. Emit a supported REPLACE operation, or return a blocking finding that explains the required version/ownership transition. Ensure preview and deployment use the same action planner.

**Regression test:** change a packaged rule's salience or another declaration field. Preview must either produce an executable reviewed plan or reject the change before deployment. Cover both the existing package version and a proposed new version with the same logical child.

### F15 — Public work fields are operationally misleading

**Priority:** P2. **Source confidence:** high. **Affected scenario:** dashboards or workers use `pgreact.work` to decide what can be claimed or what recently changed.

For rule work, the view defines `claimable` as state in PENDING or LEASED and defines `updated_at` as `completed_at`. Actual claiming selects due PENDING/RETRY_WAIT work and excludes blocked or ineligible versions. [Public work view](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m32.sql#L792-L809), [claim eligibility](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L13979-L13994)

| Example state | Current view | Operational meaning |
| --- | --- | --- |
| LEASED | claimable=true | Already leased; should not advertise as available for a new claim |
| RETRY_WAIT and due | claimable=false | Can be eligible for claiming |
| PENDING but not yet due | claimable=true | Not yet eligible |
| Unfinished work with recent activity | updated_at=NULL | Completion time does not represent the latest state change |

**Recommended change:** share an eligibility definition where feasible, or rename a deliberately broader field to describe outstanding work. Expose separate queued, available, claimed, completed, and state-changed timestamps. If claimability is advisory because locks can race, document that without making its basic state classification incorrect.

**Regression test:** use the state matrix above plus paused/draining versions, barriers, and conflict leases. Test ordering of unfinished work by its actual latest activity.

### F16 — Typed constructors depend on search_path and reject valid identifiers

**Priority:** P2. **Source confidence:** high. **Affected scenario:** application schemas are present in search_path, or schemas/relations use quoted identifiers.

`pgreact.rule` accepts a `regclass`, then serializes it with `$2::text`. PostgreSQL's regclass display can omit the schema when the relation is visible through search_path. The validator then requires an unquoted ASCII `schema.object` pattern. An explicitly typed existing relation can thus produce a declaration that fails validation. The same representation also rejects valid mixed-case or otherwise quoted PostgreSQL identifiers. [Constructor](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L35598-L35637), [identifier validation](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m32.sql#L293-L301)

The rule constructor is declared IMMUTABLE even though this textual representation depends on session/catalog context. Consequence regprocedure serialization deserves the same review.

**Recommended change:** produce canonical schema-qualified identifiers from catalog components using proper identifier quoting, rather than display casts. Parse identifiers with PostgreSQL-aware mechanisms instead of a restrictive regex. Revisit volatility labels for constructors that inspect catalog state.

**Regression test:** construct and validate the same declaration with and without its schema in search_path, with duplicate relation names in different schemas, and with quoted identifiers. Canonical digests should remain stable for the same referenced object and intended declaration.

### F17 — Evidence limits do not bound comparison cost

**Priority:** P2. **Source confidence:** high for query shape; latency impact requires measurement. **Affected scenario:** a small comparison request in a database with large unrelated runtime state.

`m34_authoritative_checksum` builds sorted JSON aggregates over declarations, rule versions, activation state, decisions, public work, and policy sets. Comparison computes it before and after processing, without limiting those tables to the requested target. Separately, proposed rule evaluation performs total-count, null-key, and duplicate-key scans before fetching limited evidence. [Global checksum](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m34.sql#L63-L90), [repeated source scans](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m34.sql#L166-L197), [checksum call sites](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m34.sql#L777-L890)

An `evidence_limit` of one can still serialize and hash large portions of the database and scan the source multiple times. Output boundedness does not imply bounded CPU, memory, reads, or temporary storage. The whole-database checksum is especially hard to justify as a production mechanism for proving a read-only operation had no effects.

**Recommended change:** move whole-state no-effect checks into tests where possible. Use target-specific version/frontier evidence in production. Combine validation scans when their semantics permit it, exploit previously validated uniqueness guarantees, and define execution budgets separately from response-size limits.

**Regression/benchmark:** hold the target constant while increasing unrelated activations and work by orders of magnitude. Measure EXPLAIN buffers, temporary I/O, total memory where available, and p95 latency. A target-local comparison should not scale linearly with unrelated historical work merely to construct its checksum.

### F18 — Historical scheduled workflows fail against current source

**Priority:** P2. **Confidence:** source and observed upstream job logs. **Affected scenario:** scheduled M29/M30 evidence runs.

The scheduled workflows check out the current default branch, build it with historical image tags, and invoke tests expecting historical release identity and documentation. On 7 September 2026, the M29 and M30 jobs built the current extension successfully, then failed in their obsolete evidence lanes. These are reproducible workflow-maintenance failures, not evidence that the current release fails to compile. [M29 workflow](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/.github/workflows/m29-evidence.yml), [M29 identity expectations](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/tests/m29.sh#L40-L62), [M29 failed job](https://github.com/trickle-labs/pg-react/actions/runs/34099036743/job/101668992969), [M30 failed job](https://github.com/trickle-labs/pg-react/actions/runs/34098197251/job/101666427166)

**Recommended change:** pin maintained historical qualification workflows to their matching tags, or disable obsolete schedules and schedule the canonical current qualification lane. Preserve historical evidence without repeatedly testing current source against obsolete identity strings.

**Regression test:** statically assert that each scheduled release-specific lane has a matching checkout revision, expected extension version, image identity, and test profile. A workflow syntax check does not establish those semantic relationships.

## 4. Performance improvement program

F10 and F17 are immediate algorithmic targets. The following additional areas warrant profiling rather than unsupported claims about percentage improvements.

### Reduce work performed on every managed cycle

`sync_semantic_keys` reads active keyed wrapper rows and updates `last_seen_at` on conflict. This can make unchanged cycles scan and write across many identities, with corresponding WAL and vacuum work. Managed cycle also counts outstanding agenda rows before and after processing. Measure how these costs grow when the input changes very little. [Semantic-key synchronization](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L16885-L16935), [pending counts](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L21358-L21404)

Consider delta-driven synchronization, avoiding timestamp rewrites when they do not affect correctness, and cheaper scoped backlog accounting. Any counter cache needs transactional reconciliation and restore tests; replacing exact queries with silently drifting counters would be a poor trade.

### Shorten coordination and execution transaction scope

The managed worker is sequential and combines coordination with consequence execution. Long-running consequences therefore affect both batch duration and lock holding. Address F09 first, then measure whether separating coordination from execution improves tail latency and failure isolation.

Parallelism is a later design change. Before adding worker count, define ordering, fairness, conflict-key serialization, version replacement, lease renewal, and barrier behavior under concurrency. More workers do not solve an unnecessarily global lock or repeated full scans.

### Improve candidate selection using measured plans

The global claim loop selects candidate rule-version IDs from agenda rows, then invokes per-version claim logic. Repeated rows for a version and repeatedly blocked/conflicting candidates can cause redundant work. Investigate selecting concrete eligible work IDs once, reducing repeated per-version scans, and making fairness ordering compatible with the access path.

Do not add a speculative index for every predicate. The schema already has agenda indexes. Collect `EXPLAIN (ANALYZE, BUFFERS)` under realistic backlog distributions, then test a partial or composite index against write amplification and retention cost. [Claim loop](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L13937-L14006)

### Establish a representative benchmark matrix

| Dimension | Suggested cases |
| --- | --- |
| Deployed rules | 1, 10, 100; both shared and independent sources |
| Active matches | 1,000; 10,000; 100,000 per relevant workload |
| Changed fraction per refresh | 0%, 1%, 10% |
| Source complexity | Simple filter, keyed join, nested view, wide row |
| Backlog | Empty, steady state, sustained backlog, retry-heavy |
| Contention | Independent keys, one hot conflict key, mixed agenda groups |
| Consequences | Fast database write, slow database write, failing consequence, outbox |
| Retention | Fresh database and long-lived history with pruning |
| Recovery | Worker crash, expired lease, source drift, replacement while draining |
| Review workloads | Small evidence limit with large target and unrelated state |

Record end-to-end fact-to-result and fact-to-effect latency at p50/p95/p99, refresh duration, throughput, frontier lag, lock waits, WAL bytes, dead tuples, buffer reads, temporary I/O, and recovery time. Publish hardware, configuration, dataset, and exact revision with results. No production capacity or speedup estimate is established by this assessment.

## 5. Ergonomics and maintainability

### Make the public workflow executable by normal roles

The intended sequence—construct, validate, preview, review, deploy, inspect—is good. The permission bugs make the superuser examples an insufficient guide to adoption. Add a complete first-application setup that creates distinct owner/author/operator/reader/worker roles, configures grants, creates application sources under the intended owner, and exercises each step from the correct login.

Document the difference between `session_user`, `current_user`, role membership, and object ownership where it affects real operations. Tests should use separate connections when login identity matters; `SET ROLE` alone does not change `session_user`.

### Keep reviewed declarations stable between steps

The decision constructor defaults `valid_from` to `clock_timestamp()`. Rebuilding what looks like the same declaration in a later statement therefore changes its digest. Prefer examples that materialize the declaration once or pass an explicit effective timestamp through preview and deployment. This behavior can be intentional, but should not surprise users of the reviewed workflow. [Decision constructor](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/pg_react--0.43.1.sql#L35639-L35666)

Use named SQL arguments in examples for the 16-parameter rule constructor. Keep defaults explicit when they change lifecycle or retry behavior. Show the result fields an operator should inspect after deployment, not just a successful function invocation.

### Unify validation, planning, and execution contracts

Several findings arise because preview and deployment independently implement the same decision: child KEEP versus changed digest, reviewed dependency identity, old-work policy requirements, and compatibility preconditions. Introduce a canonical internal plan representation with versioned semantics. Validation should construct it, preview should explain it, and deployment should revalidate and execute it.

This does not require exposing internal IDs throughout the public API. Names can remain the normal interface while the internal plan records exact versions, dependency identities, ownership, and required permissions.

### Make current SQL definitions independently inspectable

Preserve released migrations, but stop relying on cumulative historical wrappers as the only readable representation of the current system. A practical structure would separate current definitions by responsibility: authorization, declaration planning, comparison, lifecycle, queue execution, policy packages, and diagnostics.

Generate the installation artifact deterministically and verify it against those definitions. Keep explicit upgrade transitions with invariant checks. Provide a generated call/rename map for compatibility wrappers, and mark which routines are public, internal, or frozen compatibility surfaces.

M54 also rewrites stored function definitions by `pg_get_functiondef` plus string replacements. This depends on exact historical text and is harder to review than explicit function definitions. Where unavoidable, assert the expected number of substitutions and exact pre/post identities. Prefer generated full definitions for future migrations. [Definition rewriting](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/sql/m54.sql#L4-L24)

### Treat the API inventory as a semantic contract

The existing API inventory is useful for detecting unexpected catalog changes. Extend it to specify allowed roles per exact signature, required SECURITY DEFINER/search_path properties, volatility, result contract version, and compatibility status. Test semantic permissions and behavior in addition to comparing generated inventory output.

A checked-in digest is evidence of stability, not evidence that the stable state is correct. F01/F02 are examples of why positive and negative assertions are necessary.

### Improve operational documentation where consequences are expensive

Expand the backup/restore and security guides with executable procedures verified by CI. Add a recovery decision table for expired leases, changed function definitions, source drift, blocked coordination, draining versions, and failed upgrades. Each procedure should name the required role, scope, expected result, and verification query.

Current documentation checks are useful, but their coverage should include prominent top-level release statements: `ROADMAP.md` still identifies 0.43.0 as the current release while README and release metadata identify 0.43.1. This is a low-severity consistency issue outside the passing current-docs scope. [Roadmap](https://github.com/trickle-labs/pg-react/blob/3807329e3a6c6ff44087b715867d6455bc907390/ROADMAP.md#L1-L8)

## 6. Verification performed and limits

### Local checks

| Check | Result | What it establishes |
| --- | --- | --- |
| Pinned repository checkout and final worktree status | Clean; no project files modified | Findings refer to the stated source revision |
| `bash tests/current-docs.sh` | Passed | Current-release documentation audit accepted the snapshot |
| `bash tests/workflow-syntax.sh` | Passed | Repository workflow syntax audit passed |
| `bash tests/api-inventory.sh` | Static audit passed; installed catalog audit not run | Static API inventory checks passed only |
| `bash -n` on 74 shell files | Passed | Shell parsing succeeded |
| M54 module versus adjacent upgrade SQL | Byte-identical | The two representations agree |
| Reconstructed current installation SQL | Byte-identical to checked-in artifact | Cumulative assembly is consistent |
| Relative links in 21 current documentation files | No broken links found | Checked local documentation destinations exist |
| Retry, layered-DAG, and old-work predicate models | Calculated as described in F05/F08/F10 | Arithmetic and structural examples support those source findings |
| `bash tests/m54.sh fast` | Could not complete | Failed at process-substitution comparison because `/dev/fd/63` was unavailable |

The current installation SQL SHA-256 is:

```text
7eddf1564da63ae37063e460bdeb22c15a0c14c3e1a08e8d9e81d1840601fa61
```

The `/dev/fd` failure is an assessment-environment limitation, not classified here as a project defect. The equivalent assembly comparison passed using ordinary file reads. Docker, PostgreSQL client/server development tools, Cargo, and Rust were unavailable locally, so SQL runtime tests, Rust compilation, installed ACL inspection, exploit scenarios, and performance benchmarks were not rerun.

### Existing upstream evidence inspected

The successful qualification job for the reviewed revision reports eight Rust unit tests passing, PostgreSQL 18 feature compilation, Docker candidate build, installed API catalog audit, inherited SQL suites, M54 fresh-install and concurrency/failure tests, and the complete lane's backup/upgrade/rollback checks. This is meaningful evidence of the exercised cases. It does not invalidate a source finding in a scenario those tests do not cover. [Successful qualification job and logs](https://github.com/trickle-labs/pg-react/actions/runs/33545015188/job/99980248744)

The same log reports `cargo audit` scanning 143 dependencies and completing with one allowed warning. This is evidence about that CI run, not a fresh independent vulnerability assessment as of 7 September. No claim of current dependency freedom from vulnerabilities is made.

The v0.43.1 release includes the image archive, evidence archive, SBOM, checksums, and provenance-related artifacts. The two later failed historical schedules are analyzed separately in F18. It would be inaccurate to describe the current release qualification itself as failing. [Release artifacts](https://github.com/trickle-labs/pg-react/releases/tag/v0.43.1)

### Important boundaries of the assessment

- Review concentrated on effective current call chains, security-sensitive reads/writes, replacement/review logic, queue recovery, package planning, and qualification scripts. It did not inspect all 1.24 million SQL source lines independently.
- Security findings describe reachable mechanisms and proposed verification scenarios. No production system was attacked, and no unauthorized data was accessed.
- The dependency-graph and retry examples are analytical demonstrations, not database benchmarks.
- PostgreSQL behavior was checked against primary PostgreSQL 18 documentation/source, particularly function security, view security, and physical backup requirements.
- The six-file Rust layer and its use of PostgreSQL internals still merit targeted integration testing. This assessment does not claim to prove memory safety of every unsafe query-tree traversal.

## 7. Recommended remediation sequence

### Phase 1 — Restore permission and review guarantees

Address F01–F06 first, with particular urgency on F02/F03. Build the exact effective permission matrix on fresh install and upgrade. Make comparison source execution obey one documented security policy. Enforce accepted preconditions, require explicit old-work consent from deployed state, and define the full reviewed dependency identity.

**Exit criteria:** normal roles complete their intended workflow; reader/worker roles fail author-only calls; RLS sources cannot leak through comparison; stale declarations and changed executable dependencies cannot silently pass a reviewed deployment.

### Phase 2 — Prove progress and recoverability

Address F08, F09, F11, F12, and F13. Isolate per-job failures, make retry calculations saturate safely, recover old draining leases through normal APIs, and distinguish worker liveness from progress. Replace the backup test with a supported procedure and representative extension state.

**Exit criteria:** a damaged job does not indefinitely block unrelated work; expired leases recover after replacement; health reports blocked coordination accurately; backup restoration proves exact state and safe resumption using the appropriate artifact.

### Phase 3 — Make review evidence semantically reliable and bounded

Address F07, F10, F14, F15, F16, and F17. Evaluate comparisons against one fact snapshot, eliminate path enumeration, unify package planning with deployment, fix operator fields, and canonicalize identifiers. Separate output-size bounds from execution-cost bounds.

**Exit criteria:** unchanged declarations do not generate policy deltas solely from refresh lag; valid bounded packages complete within an established resource budget; ready plans are executable; work fields agree with state-machine semantics; identifier handling is independent of search_path.

### Phase 4 — Simplify maintenance and publish measured limits

Address F18, consolidate the canonical release regression suite by behavior rather than milestone identity, and separate current SQL definitions from migration history. Add the benchmark matrix and publish results with exact workload/configuration details. Ensure failed qualification runs retain useful evidence artifacts as well as successful ones.

**Exit criteria:** scheduled CI produces actionable signals, current behavior is inspectable without reconstructing long rename chains, and users can choose deployment sizes using measured latency and recovery behavior.

### Highest-value additions to the current regression gate

| Test family | Required assertion |
| --- | --- |
| Fresh and upgraded role matrix | Each exact API signature permits only intended roles |
| Reviewed deployment races | Stale current digests, changed bodies, and changed nested views fail safely |
| Same-facts comparison | Identical declarations remain equivalent across source-refresh gaps |
| Comparison security | Direct SELECT visibility cannot be widened through a definer-context source read |
| Old-work transitions | Every effect-bearing old version requires explicit drain/cancel handling |
| Retry boundary | Large permitted attempt counts retain capped backoff and durable bookkeeping |
| Damaged job isolation | Healthy jobs commit despite another job's drift failure |
| Package graph stress | Legal DAGs stay within a demonstrable complexity/resource bound |
| Populated physical restore | Exact extension invariants survive supported backup and rollback |
| Operator API consistency | Recovery names include relevant historical versions and work fields match eligibility |

The project already has enough architecture and test infrastructure to support these changes. The immediate need is to make its strongest promises—reviewed changes, role separation, trustworthy evidence, and recoverable durable work—hold at the edge cases where users most need them.

# Capability area 2 ergonomics implementation plan

> Status: ready for implementation
> Release target: M53 / extension `0.42.0`
> Dependency: M44 / extension `0.41.0`
> Scope: additive operator ergonomics over the installed Area 2 semantics
> Excluded: external workload and field-evidence claims

## Outcome

A PostgreSQL operator can move from an unexpected result to a useful
explanation without learning milestone numbers, constructing nested option
JSON, copying private identifiers, or translating several identity formats.

The implementation keeps every installed explanation evaluator and detailed
result contract. It adds names-first task functions, one structured public
reference, one read-only summary projection, and structured next actions.

This work is the first independently testable slice of M53 / `0.42.0`. It does
not create another milestone or an intermediate release. M53 policy-set
packaging uses the improved explanation workflow after this slice passes.

## Success criteria

The implementation is complete only when all of these statements are true:

1. An operator reaches a useful answer within three public SQL statements.
2. Common why-not, causal-path, comparison, semantic-difference, capture, and
   snapshot-read tasks require no hand-written JSON.
3. Common tasks require no private UUID, formatted root identity, milestone
   number, or result-contract version.
4. Every `partial`, `unavailable`, or `unsupported` summary contains at least
   one structured next action or an explicit `stop` action.
5. Generic tooling reads common identity, state, completeness, findings,
   limits, evidence point, and digest fields without branching on the origin.
6. Detailed causes, graphs, comparisons, differences, and retained answers
   keep their installed origin-specific shapes.
7. Existing valid calls return byte-for-byte identical JSON when the caller
   does not use a new function.
8. Existing read-only calls remain read-only. Existing snapshot capture and
   delete calls keep only their documented writes.
9. Live evidence and retained evidence never combine into one current claim.
10. Denied calls reveal no information beyond the installed fail-closed
    contract.

## Current architecture

The ordinary entry point is `pgreact.explain(name, subject, options)`. M40
replaced that function to route `why_not`. M41 replaced it again to route
`causal_path`, then M40, then the ordinary M31 explanation.

Other Area 2 questions use separate operations:

| Question | Installed operation | Detailed result |
|---|---|---|
| What is true now? | `pgreact.explain` | Ordinary result version `14` |
| Why is a result absent? | `pgreact.explain` with `why_not` | M40 result version `26` |
| Which facts led to a result or work item? | `pgreact.explain` with `causal_path` | M41 result version `27` |
| Why did a current comparison row change? | `pgreact.compare` with `why_changed` | M38 nested result version `25` |
| Which modeled declaration fields changed? | `pgreact_api.semantic_diff` | M43 contract version `43` |
| What causal answer was retained? | `pgreact_api.read_evidence_snapshot` | M42 result version `28` with nested M41 |

M44 gives these operations shared meanings for public identity, completeness,
authorization, limits, semantic digests, and retained evidence. M44 does not
give them one machine-readable projection.

## Problems to fix

| Problem | Current behavior | Required behavior |
|---|---|---|
| Conflicting questions | `causal_path` silently wins when both `causal_path` and `why_not` are present | Reject the request with one exact finding |
| JSON construction | Common tasks require nested option objects | Provide names-first task functions |
| Work identity | A causal work root requires several fields that already exist in the work row | Accept the target name and `work_id`, then resolve the rest safely |
| Snapshot lookup | Capture returns `snapshot_identity`, but read and delete require target, root identity, and capture key | Accept the returned `snapshot_identity` directly |
| Result interpretation | Common fields occur at different paths and use origin-specific states | Provide one optional read-only summary |
| Remediation | Findings contain text hints only | Project stable structured next actions |
| Capability discovery | Operators must read several milestone references to find supported questions and limits | Add target-aware capability introspection |
| Comparison target | Common compare and semantic-difference calls require `pgreact_api.target(...)` | Resolve the deployed target from the proposed declaration |
| Documentation | Operator guides expose milestone and result-version history | Put history in historical docs and tasks in canonical docs |

## Design decisions

### Keep one evaluator for each question

The new functions delegate to the installed M31, M38, M40, M41, M42, and M43
implementations. They do not copy evaluator logic or fill one origin's missing
evidence from another origin. Bounded identity resolvers read only the existing
work and snapshot catalogs needed to convert a public handle into installed
function arguments.

### Do not add a universal explanation envelope

`pgreact.explanation_summary(answer)` is an optional projection over an answer
the caller already has. It does not wrap every call by default. The detailed
answer remains authoritative for origin-specific data.

### Centralize question dispatch once

M53 replaces the exact public function identity
`pgreact.explain(text, jsonb, jsonb)` once. The new implementation uses one
internal question parser and one dispatcher. It does not replace or change
`pgreact_api.explain` or any compatibility function. Historical `sql/m40.sql`
and `sql/m41.sql` remain unchanged.

The parser treats absent keys and literal `false` as disabled. It accepts at
most one enabled question. A request with both `why_not` and `causal_path`
returns `M53_EXPLAIN_QUESTION_CONFLICT` and performs no evaluator work.

### Keep compatibility explicit

The following behavior remains byte-for-byte unchanged:

- `pgreact.explain(name, subject)`;
- `pgreact.explain(name, subject, options)` with one valid installed question;
- `pgreact.compare(proposed, deployed, options)`;
- `pgreact_api.semantic_diff(proposed, deployed, options)`;
- the existing three-argument M42 snapshot read and delete calls;
- every nested M41 answer retained by M42.

The conflicting-question case is the only intentional behavior change to an
existing input. The current precedence result is unsafe because it answers a
different question without rejecting the request.

### Ship with M53 without coupling the implementations

All new SQL belongs in the M53 migration and full-install artifact. Internal
ergonomics functions use an `m53_` prefix. Policy-set packaging can call the
new public operations, but the explanation code does not call the package
planner or package catalogs.

If M53 is split later, this slice can move to a patch release without changing
its public contracts. Do not create that release during the initial
implementation.

## Public SQL additions

Common calls use names and business identities. Advanced callers keep the
installed JSON options when they need custom limits.

```sql
pgreact.why_not(
	name text,
	subject jsonb,
	result_kind text,
	result_key jsonb
) RETURNS jsonb

pgreact.trace(
	name text,
	subject jsonb,
	result_key jsonb
) RETURNS jsonb

pgreact.trace(
	name text,
	work_id text
) RETURNS jsonb

pgreact.trace(explanation_ref jsonb) RETURNS jsonb

pgreact.compare(
	proposed pgreact_api.declaration,
	why_changed boolean DEFAULT false
) RETURNS jsonb

pgreact.semantic_diff(
	proposed pgreact_api.declaration
) RETURNS jsonb

pgreact.explanation_summary(answer jsonb) RETURNS jsonb

pgreact.explanation_capabilities(
	name text DEFAULT NULL
) RETURNS jsonb

pgreact.capture_evidence(
	explanation_ref jsonb,
	capture_key text
) RETURNS jsonb

pgreact.read_evidence(snapshot_identity text) RETURNS jsonb

pgreact.delete_evidence(snapshot_identity text) RETURNS jsonb
```

### `pgreact.why_not`

The function builds the installed M40 option object and delegates to the M53
explain dispatcher. Its result must equal the corresponding M40 result
byte-for-byte.

The function accepts the installed M40 result kinds:

- `rule_match`;
- `decision_result`;
- `derived_fact`;
- `policy_eligibility`.

The function does not expose a limit argument. Callers who need a custom
`cause_limit` use the installed `pgreact.explain` option.

### `pgreact.trace`

The three overloads cover the common causal-path tasks:

- The names-first overload traces one decision result.
- The `name, work_id` overload resolves the target kind, subject, generation,
  revision, event kind, and consequence identity from the authorized work
  state. The name disambiguates decision work IDs, which are subject keys, and
  rule work IDs.
- The reference overload repeats a supported causal question from one
  structured public reference.

Each overload delegates to M41 and returns the exact M41 result. Custom graph
limits remain available through the installed `causal_path` option.

If the name matches both a rule and a decision program, the overload returns
an exact ambiguity finding. If a work row is missing, pruned, changed, or
unauthorized, it returns the installed safe state. It does not guess a target
kind or any missing root field.

### Names-first comparison

`pgreact.compare(proposed, why_changed)` constructs
`pgreact_api.target((proposed).kind, (proposed).name, NULL)` and delegates to
the installed compare function. `pgreact.semantic_diff(proposed)` constructs
the same target and delegates to M43.

The null version deliberately invokes the installed current-deployment rule.
Rules and decision programs resolve to declaration version `1`. Policy sets
resolve to the single deployed version selected by the installed M34 or M43
evidence-point rules. A caller that needs to name a specific policy-set
version uses the installed advanced function with an explicit
`pgreact_api.target`. The ergonomic overload never guesses a historical or
removed version. Missing or ambiguous targets keep the delegate's exact
failure behavior.

These overloads do not combine outcome comparison with semantic policy
differences. The two questions remain separate.

## Required delegation map

This map is an implementation constraint, not an example architecture.

| Public call | Resolution | Authoritative operation |
|---|---|---|
| `pgreact.why_not` | Build the installed `why_not` option | M53 dispatcher, then `pgreact_internal.m40_explain` |
| Three-argument `pgreact.trace` | Build a `decision_result` causal root | M53 dispatcher, then `pgreact_internal.m41_explain` |
| Two-argument `pgreact.trace` | Resolve one authorized work row by name and public work ID | `pgreact_internal.m41_explain` |
| One-argument `pgreact.trace` | Validate and expand `explanation_ref` | M40 or M41 according to `question_kind` |
| `pgreact.compare` | Build a null-version target from the proposal | Installed `pgreact.compare(proposed, target, options)` |
| `pgreact.semantic_diff` | Build the same target | `pgreact_api.semantic_diff` |
| `pgreact.capture_evidence` | Validate and expand a decision-result reference | `pgreact_api.capture_evidence_snapshot` |
| `pgreact.read_evidence` | Resolve the primary key without parsing it | M53 identity helper with exact M42 read semantics |
| `pgreact.delete_evidence` | Resolve and lock the primary key without parsing it | M53 identity helper with exact M42 delete semantics |
| `pgreact.explanation_summary` | Validate the supplied result contract | Pure projection only |
| `pgreact.explanation_capabilities` | Resolve authorized target metadata | Bounded metadata projection only |

No explanation wrapper may query authoritative source evidence directly or
reimplement why-not, graph traversal, comparison, or semantic-difference
logic.

## Canonical operator journeys

The documentation and executable examples use these shapes. Business names
and keys vary, but the number and order of operations do not.

```sql
SELECT pgreact.why_not(
	'order-routing', to_jsonb(100), 'decision_result', to_jsonb(9001)
);

SELECT pgreact.trace('order-routing', to_jsonb(100), to_jsonb(9001));

SELECT pgreact.trace(name, work_id)
FROM pgreact.work
WHERE kind = 'rule' AND name = 'manual-review-required' AND work_id = '42';
```

Summarize without changing the detailed answer:

```sql
WITH answer AS (
	SELECT pgreact.trace('order-routing', to_jsonb(100), to_jsonb(9001)) AS value
)
SELECT pgreact.explanation_summary(value)
FROM answer;
```

Capture a complete decision-result trace, then use the returned identity
directly:

```sql
WITH answer AS (
	SELECT pgreact.trace('order-routing', to_jsonb(100), to_jsonb(9001)) AS value
), summary AS (
	SELECT pgreact.explanation_summary(value) AS value
	FROM answer
)
SELECT pgreact.capture_evidence(value -> 'explanation_ref', 'incident-2026-09-01')
FROM summary;

SELECT pgreact.read_evidence(:snapshot_identity);
```

Compare one proposed declaration without constructing a target:

```sql
SELECT pgreact.compare(:proposed_declaration, why_changed => true);
SELECT pgreact.semantic_diff(:proposed_declaration);
```

Each journey is one statement for the question and at most one additional
statement for a summary or retained read. The advanced installed functions
remain the escape hatch for custom limits and explicit target versions.

## Structured `explanation_ref`

`explanation_ref` is versioned JSON that contains only public question
identity. It does not contain an evidence point, elapsed time, source values,
private UUIDs, transaction IDs, physical row positions, or catalog IDs.

```json
{
	"ref_version": 1,
	"question_kind": "causal_path",
	"target": {
		"kind": "decision_program",
		"name": "order-routing",
		"version": "1"
	},
	"subject": 10,
	"root": {
		"kind": "decision_result",
		"result_key": 1000
	}
}
```

Work references use the same outer fields. Their `root` contains `work_id`,
`generation`, `revision`, `event_kind`, and `consequence_identity` because
those fields define the installed M41 question identity.

The implementation uses the M44 typed serialization rules. JSON object order
does not change identity. Missing, unknown, null, oversized, or inconsistent
fields return `M53_EXPLANATION_REF_INVALID`.

The serialized reference may not exceed 65,536 bytes. The validator rejects a
larger reference before target or source lookup.

## Read-only explanation summary

`pgreact.explanation_summary(answer)` recognizes the installed Area 2 result
contracts and returns contract version `53`.

```json
{
	"contract_version": 53,
	"origin": "causal_path",
	"question_kind": "causal_path",
	"target": {},
	"subject": null,
	"explanation_ref": {},
	"availability_state": "current",
	"origin_state": "complete",
	"explanation_state": "complete",
	"complete": true,
	"evidence_point": {},
	"semantic_digest": null,
	"limits": {},
	"findings": [],
	"next_actions": []
}
```

The projection supports these origins:

- ordinary current explanation;
- M40 why-not;
- M41 causal path;
- M38 why-changed current comparison;
- M42 retained causal path;
- M43 semantic difference.

The projection follows these rules:

- `origin_state` preserves the installed state without relabeling it.
- `explanation_state` uses only the M44 mapping.
- `availability_state` distinguishes current evidence, available historical
  evidence, missing evidence, and deleted evidence.
- For an M42 result, outer availability and nested M41 completeness remain
  separate fields.
- For a comparison with several changed rows, the summary contains a canonical
  `children` array with one entry for each returned why-changed answer.
- For M43, `complete` means that M43 inspected every modeled field within its
  limits. It does not mean that arbitrary SQL has a known business meaning.
- The summary never includes graph nodes, graph edges, paths, causes, compared
  rows, declaration fields, or the retained M41 payload.
- Unknown result contracts return `M53_EXPLANATION_SUMMARY_UNSUPPORTED` and do
  not guess an origin.

The function is `IMMUTABLE`, reads no table, performs no writes, and scans the
supplied JSON once. It returns at most 16 next actions and at most 256 child
summaries. A larger child set returns `partial` with the reached limit.

## Structured next actions

The summary maps installed finding families to structured actions. It keeps
the original findings unchanged.

```json
{
	"action": "increase_limit",
	"reason_code": "M41_RESOURCE_LIMIT",
	"safe_to_retry": true,
	"parameters": {
		"field": "path_limit"
	}
}
```

The first contract supports these actions:

| Action | Meaning |
|---|---|
| `retry` | Repeat the same public question without changing its meaning |
| `refresh_target` | Refresh or reconcile the named public target, then retry |
| `grant_access` | Repair access through the documented PostgreSQL grant path |
| `repair_schema` | Restore or replace a missing or drifting public object |
| `increase_limit` | Raise one named limit within its installed maximum |
| `narrow_question` | Ask for a smaller supported result or graph |
| `read_snapshot` | Read one existing retained answer by snapshot identity |
| `recapture` | Capture a new answer after the current causal path is complete |
| `stop` | Do not retry because the question is unsupported or unsafe |

Actions contain data, not generated SQL. An unknown or ambiguous finding maps
to `stop`. Unauthorized summaries do not name a hidden source or object.

The implementation uses one explicit SQL mapping. Do not add a configuration
table or user-editable action registry.

## Capability introspection

`pgreact.explanation_capabilities(name)` returns contract version `53` and a
canonical list of supported questions for one authorized target.

Each question record contains:

- `question_kind`;
- `supported`;
- supported result or root kinds;
- the common public function name and argument names;
- the advanced option name;
- installed default limits;
- installed maximum limits;
- one finding when the target cannot support the question.

With a null name, the function returns the static target-kind matrix and no
deployed target data. With a name, it uses the existing names-first target
resolution and authorization rules.

The result contains at most 16 question records. It reads metadata only and
does not evaluate a rule, scan a source, expand a graph, or write state.

## Snapshot ergonomics

The M42 catalog already stores `snapshot_identity` as its primary key. M53
adds ordinary one-argument read and delete functions. A new internal
`pgreact_internal.m53_evidence_by_identity(snapshot_identity, operation)`
helper reads the live row, audit, or tombstone by that identity and then
applies the installed M42 operation.

The lookup repeats the exact M42 owner-or-operator authorization, result,
audit, tombstone, and deletion behavior. Missing and unauthorized identities
return the same fail-closed public result. It does not use the legacy
three-argument call as an identity lookup, parse a formatted root identity,
or reconstruct keys from identity text.

`pgreact.capture_evidence(explanation_ref, capture_key)` accepts only an
M42-supported `decision_result` reference. It delegates to the installed M42
capture function and returns the installed M42 result. Retention remains the
installed policy from the deployed declaration. The wrapper does not accept
or create another retention policy.

The retained nested M41 answer stays byte-for-byte equal to the captured
answer. A later live explanation never fills or updates that historical
answer.

## Security rules

The implementation must pass an authorization audit before adding the summary
and capability functions.

The audit covers:

- names-first target existence and ambiguity;
- target owner, operator, reader, and advanced-reader roles;
- source `SELECT` changes;
- object grants;
- RLS sources;
- removed and replaced targets;
- snapshot owner-or-operator access;
- changed role membership;
- denied summary and capability calls.

The audit must reconcile the M44 non-leakage contract with the installed M40
and M41 unavailable paths. If an installed path exposes target metadata that
M44 forbids, fix the shared result path before exposing it through a new
function. Do not weaken the M44 contract to preserve a leak.

New wrappers use `SECURITY DEFINER` only where the delegated installed
function already requires it. Every such function fixes `search_path` to
`pg_catalog, pg_temp` and performs authorization before metadata lookup.

## Resource rules

- A convenience function invokes one installed evaluator exactly once.
- The summary reads only its JSON argument.
- Capability introspection reads bounded metadata only.
- Reference validation stops at 65,536 bytes.
- Snapshot-identity validation stops at 4,096 bytes before catalog lookup.
- The summary returns no more than 16 actions and 256 child summaries.
- Existing M40, M41, M42, and M43 semantic limits remain authoritative.
- No new function adds a continuation token or unbounded search.
- Measured elapsed time remains outside identity and semantic digests.

## Implementation phases

### Phase 0: Freeze compatibility and security baselines

Files:

- `tests/m53-ergonomics.sql`;
- `docs/m53-ergonomics-contract.md`;
- `docs/m53-ergonomics-api-inventory.json`;
- `docs/m53-ergonomics-finding-codes.json`.

Work:

1. Record the exact full JSON for ordinary explanation, why-not, causal path,
   why-changed comparison, retained causal path, and semantic difference.
2. Record exact source, declaration, lifecycle, decision, work, snapshot,
   audit, retention, and frontier checksums around every read-only call.
3. Add exact denied outputs for every role, grant, and RLS case.
4. Freeze the new public signatures and internal finding codes.
5. Add the conflicting-question fixture before changing dispatch.

Exit:

- The baseline fixture passes against `0.41.0`.
- Every output that must remain compatible is stored as a complete value, not
  a count or selected-field assertion.
- The authorization audit has no unresolved M44 contract mismatch.

### Phase 1: Replace precedence dispatch with validated dispatch

File: `sql/m53.sql`.

Work:

1. Add `pgreact_internal.m53_explain_question(options jsonb)`.
2. Add `pgreact_internal.m53_explain_dispatch(name, subject, options)`.
3. Assert that `to_regprocedure('pgreact.explain(text,jsonb,jsonb)')` resolves
   to the frozen public identity, then replace only that function in the M53
   migration.
4. Delegate valid requests to `pgreact_internal.m41_explain`,
   `pgreact_internal.m40_explain`, or `pgreact_api.explain_m31` with the exact
   installed M41 and M40 option-stripping behavior.
5. Return `M53_EXPLAIN_QUESTION_CONFLICT` before evaluation when more than one
   question is enabled.
6. Preserve the installed option-stripping behavior for fallback calls.

Exit:

- Every valid inherited request returns its baseline bytes.
- The conflict request returns the exact new unsupported result and changes no
  state.
- Adding a future question requires one parser change and one dispatcher
  branch, not another wrapper over the public function.

### Phase 2: Add names-first task functions and references

File: `sql/m53.sql`.

Work:

1. Add `pgreact.why_not`.
2. Add all three `pgreact.trace` overloads.
3. Add the names-first compare overload.
4. Add `pgreact.semantic_diff`.
5. Add internal canonical reference construction and validation.
6. Resolve `trace(name, work_id)` through authorized work identity and reject
   target-kind ambiguity before reading work details.

Exit:

- Each wrapper returns the exact detailed result returned by its installed
  delegate.
- Repeated reference construction returns byte-for-byte equal JSON.
- A changed target, subject, root kind, result key, or work revision changes
  the reference.
- Common current, why-not, trace, compare, and semantic-difference tasks use no
  hand-written JSON or typed target constructor.

### Phase 3: Add direct snapshot operations

File: `sql/m53.sql`.

Work:

1. Add `pgreact.capture_evidence`.
2. Add `pgreact.read_evidence(snapshot_identity)`.
3. Add `pgreact.delete_evidence(snapshot_identity)`.
4. Add `pgreact_internal.m53_evidence_by_identity(snapshot_identity,
   operation)`; reuse the exact M42 authorization, result, audit, tombstone,
   deletion, and retention behavior.
5. Do not parse `snapshot_identity` or route the lookup through the legacy
   three-argument API as an identity parser.
6. Keep the installed advanced M42 functions unchanged.

Exit:

- The identity returned by capture can be passed directly to read and delete.
- Old and new read calls return byte-for-byte equal results.
- Old and new delete calls write the same exact rows.
- Unauthorized and missing identities have indistinguishable fail-closed
  outputs where the M44 contract requires them.

### Phase 4: Add summary, remediation, and capability discovery

File: `sql/m53.sql`.

Work:

1. Add origin discrimination by installed operation and contract version.
2. Add `pgreact_internal.m53_explanation_ref`.
3. Add `pgreact_internal.m53_next_actions` with one explicit mapping.
4. Add `pgreact.explanation_summary`.
5. Add `pgreact.explanation_capabilities`.
6. Reject unknown input contracts instead of guessing.

Exit:

- Every qualified Area 2 origin returns the full exact summary fixture.
- Every noncomplete summary has a structured action or `stop`.
- M42 availability and nested M41 completeness remain separate.
- M43 completeness does not imply understood SQL business meaning.
- Summary and capability calls perform no writes and stay within their fixed
  result limits.

### Phase 5: Update canonical documentation

Files:

- `docs/explaining-outcomes.md`;
- `docs/v1-api-reference.md`;
- `docs/v1-operations.md`;
- `docs/v1-troubleshooting.md`;
- `docs/v1-known-limitations.md`;
- `docs/index.md`;
- `README.md`.

Work:

1. Put the names-first task calls first.
2. Move raw JSON option construction into an advanced section.
3. Show one current-result, one missing-result, one work-trace, one comparison,
   one capture, and one snapshot-read journey with exact output.
4. Add a recovery loop for `partial`, `unavailable`, and `unsupported`.
5. Remove milestone numbers and result-contract versions from operator steps.
6. Update stale current-release text in canonical operations documentation.
7. Keep M40 through M44 documents as historical contract references.

Exit:

- Every canonical example runs against the exact `0.42.0` artifact.
- A reader can choose a question without opening a milestone document.
- The documentation audits pass.

### Phase 6: Package and qualify the release

Files:

- `sql/pg_react--0.41.0--0.42.0.sql`;
- `sql/pg_react--0.42.0.sql`;
- `tests/m53.sh`;
- `.github/workflows/ci.yml`;
- `.github/workflows/release.yml`;
- `Cargo.toml`;
- `Cargo.lock`;
- `pg_react.control`;
- `src/managed.rs`;
- M53 release and migration documentation.

Work:

1. Include the ergonomics SQL in the M53 migration and full install.
2. Add the exact API and finding inventories.
3. Run the inherited M40 through M44 suites.
4. Run fresh-install, populated adjacent-upgrade, rollback-by-restore, restart,
   recovery, and packaged-artifact lanes.
5. Verify the managed worker accepts `0.42.0`.
6. Verify the release workflow packages the exact candidate.

Exit:

- `tests/m53.sh complete` passes against the exact candidate image.
- Every inherited gate passes.
- The complete M53 policy-set package journey uses the new ergonomic
  explanation path.
- No P0 or P1 remains.

## Exact test matrix

All tests assert complete outputs. Do not replace a full-value assertion with
a count, key-existence check, or subset comparison.

| Area | Exact scenarios |
|---|---|
| Dispatch | no question, `why_not`, `causal_path`, both enabled, both false, one false and one enabled, unknown option |
| Why-not wrapper | all four result kinds, complete, already present, partial, unavailable, unsupported |
| Decision trace | winner, no candidate, ambiguous, missing source, changed revision, inaccessible predecessor |
| Work trace | rule work, decision work, same work ID under different names, name shared by rule and decision program, each event kind, stale generation, stale revision, pruned work, missing work |
| Reference | stable object order, changed identity field, missing field, unknown field, null field, oversized input, private-ID rejection |
| Compare wrapper | rule version `1`, decision program version `1`, current deployed policy-set version, explicit-version advanced call unchanged, why-changed false, why-changed true, missing target, ambiguous target |
| Semantic difference | added, removed, changed, unchanged, opaque SQL, partial, unavailable, unsupported |
| Summary | ordinary, M40, M41, M38, M42, M43, unknown contract, child limit, action limit |
| Remediation | retry, refresh, access, schema repair, limit, narrowing, snapshot read, recapture, stop |
| Capability discovery | null target, each target kind, unsupported origin, missing target, ambiguous target, denied target |
| Snapshot | capture with installed retention, duplicate capture, direct primary-key read, legacy read, direct delete, legacy delete, tombstone, expiry, missing, unauthorized, null identity, oversized identity, formatted-identity parsing rejected |
| Live and retained | source changed, source removed, grant changed, target replaced, snapshot unchanged, no cross-fill |
| Authorization | author, owner, operator, reader, advanced reader, changed role, source grant, object grant, RLS, `PUBLIC` |
| Read-only | success, rejection, cancellation, timeout, terminated backend, restart, recovery, concurrent source change |
| Compatibility | fresh install, `0.41.0 -> 0.42.0`, rollback restore, every inherited exact result, old function identities |
| Documentation | each common task in at most three statements, no hand-written JSON, no private ID, no milestone knowledge |

## File plan

| File | Change |
|---|---|
| `sql/m53.sql` | Add dispatch, wrappers, reference validation, summary, actions, capabilities, and snapshot overloads |
| `tests/m53-ergonomics.sql` | Store exact functional, compatibility, security, and checksum fixtures |
| `tests/m53.sh` | Run the ergonomics fixture in fast and complete M53 lanes |
| `docs/m53-ergonomics-contract.md` | Freeze public semantics and exclusions |
| `docs/m53-ergonomics-api-inventory.json` | Freeze new and replaced public function identities |
| `docs/m53-ergonomics-finding-codes.json` | Freeze new findings and structured action mappings |
| `docs/explaining-outcomes.md` | Make the names-first path canonical |
| `docs/v1-api-reference.md` | Document exact signatures and outputs |
| `docs/v1-operations.md` | Add the operator investigation and recovery loop |
| `docs/v1-troubleshooting.md` | Map findings to actions without generated SQL |
| M53 packaging files | Include the slice in `0.42.0` and inherited qualification |

Do not edit historical `sql/m40.sql` through `sql/m44.sql` to implement the
new behavior. Do not rewrite historical release records to describe the new
calls.

## Migration and rollback

The `0.41.0 -> 0.42.0` migration adds public overloads and internal helper
functions. It replaces only the exact public identity
`pgreact.explain(text, jsonb, jsonb)`. It leaves `pgreact_api.explain` and its
compatibility functions untouched. It does not rewrite declarations, matches,
decisions, work, evidence snapshots, audits, retention rows, or frontiers.

The migration performs no rule evaluation, graph traversal, snapshot capture,
snapshot deletion, reconciliation, or work execution.

Rollback remains restore-based. The rollback fixture restores the exact
`0.41.0` backup and proves that every old call and retained snapshot still
returns its pre-upgrade output.

## Implementation risks

| Risk | Control |
|---|---|
| A wrapper changes detailed JSON | Compare the complete wrapper result with the complete delegated result |
| Central dispatch breaks fallback behavior | Freeze `0.41.0` no-option and false-option outputs before replacement |
| A reference becomes another private identity | Permit only M44 public identity fields and reject private fields |
| Summary collapses two states into one | Keep origin, availability, and explanation states separate |
| Summary implies more certainty | Derive completeness only from the M44 mapping and preserve origin findings |
| Capability lookup leaks target existence | Apply authorization before target metadata and use one fail-closed result |
| Direct snapshot lookup weakens access | Reuse the exact M42 owner-or-operator check and audit path |
| Action mapping becomes a workflow engine | Return data only, cap the list, and use `stop` for unknown cases |
| Overloads become ambiguous | Test every positional and named-argument call at migration time |
| M53 packaging couples to explanation internals | Depend only on the public ergonomic calls and summaries |

## Explicit deferrals

- No `explain_v2` or universal evaluator.
- No combined live and historical answer.
- No common graph, cause, or difference record.
- No automatic question selection.
- No generated repair SQL or automatic repair execution.
- No client SDK, dashboard, visualization API, or AI interpretation.
- No batch explanation or continuation token.
- No new retention system or automatic snapshot capture.
- No relaxation of authorization, RLS, unsupported-SQL, or resource limits.

Add one of these only when the completed SQL workflow still has a measured,
repeated problem that the current plan cannot solve.

## Definition of done

- The public signatures and contract version `53` are frozen.
- Every success and failure scenario asserts its full output.
- Existing valid calls remain byte-for-byte compatible.
- The conflicting-question request fails explicitly.
- Common tasks meet the three-statement and no-hand-written-JSON criteria.
- `snapshot_identity` is directly reusable.
- Every noncomplete summary has one structured next action or `stop`.
- Summary and capability operations are bounded and read-only.
- Authorization and non-leakage tests pass for every qualified origin.
- Live and retained evidence remain separate.
- Fresh install, adjacent upgrade, rollback restore, restart, recovery, and the
  packaged candidate pass.
- Canonical documentation contains no milestone knowledge in operator steps.
- M53 policy-set packaging uses the completed ergonomic path.

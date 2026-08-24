# pg-react 1.x contract

This is the frozen contract for the M34 / extension `0.31.0` baseline and the
prepared `1.0.0-rc.1` candidate: the M33 ordinary runtime plus the M34 read-only
comparison surface. It does not set the eventual v1 feature boundary.

The project has postponed `1.0.0` and its complete feature freeze indefinitely.
Development continues one milestone at a time from M35, with separate contracts,
release versions, and qualification gates. Exact package versions and upgrade
paths become contractual through qualified release artifacts and migration scripts.

## Ordinary SQL surface

The ordinary path uses stable names, typed PostgreSQL identities, and the
`pgreact` schema:

```text
pgreact.rule
pgreact.decision
pgreact.policy_set
pgreact.validate
pgreact.preview
pgreact.deploy
pgreact.remove
pgreact.run
pgreact.status
pgreact.explain
pgreact.doctor
```

The ordinary public views are:

```text
pgreact.rules
pgreact.matches
pgreact.decisions
pgreact.policy_sets
pgreact.work
pgreact.attempts
pgreact.health
```

These calls and the required meanings of their current columns remain usable
throughout `1.x`. The current machine inventories are M33 snapshots, not exact
`0.31.0` inventories; they are not authority for omissions or classifications
until regenerated from a release-candidate artifact.

Private schemas and catalogs are not an application or repair API.

## Declarations

Canonical declarations use API version `1`.

`pgreact.rule` commits the fields `name`, `condition`, `semantic_key`, `kind`,
optional typed consequences (`on_activate`, `on_deactivate`, `on_change`),
`bootstrap_policy`, `change_columns`, `salience`, `agenda_group`,
`conflict_key_columns`, `max_attempts`, `initial_backoff_seconds`,
`backoff_multiplier`, and `max_backoff_seconds`.

`pgreact.decision` commits `name`, `candidate_relation`, `subject_key`,
`candidate_key`, `priority`, `results`, `valid_from`, `valid_to`, and
`max_candidates`.

`pgreact.policy_set` commits `name`, `version`, typed `members`,
`applicability`, `subject_keys`, `valid_from`, `valid_to`, and
`evidence_limit`.

The installed runtime supports typed key codecs beyond bigint in advanced
runtime paths. This contract does not collapse that general capability into
the narrower comparison restrictions below.

## Comparison contract

The v1 comparison surface is:

```text
pgreact.compare(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'
) RETURNS jsonb

pgreact.compare_results(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'
) RETURNS TABLE (...)

pgreact_api.target(
    kind text,
    name text,
    version text DEFAULT NULL
) RETURNS pgreact_api.target
```

Comparison varies one declaration over current authoritative facts. It accepts
only `rule`, `decision_program`, and `policy_set` proposals and targets. The
proposal and target `kind` and `name` must match.

For non-policy targets, `version` must be null or `'1'`. A policy-set target
may select a deployed policy-set version. Rule comparison requires one
`bigint`, non-null, unique semantic key in both evaluated rule relations.

`options.evidence_limit` defaults to `100` and must be between `1` and `1000`.
`options.sampled_time`, when supplied, must equal the current authoritative
frontier. v1 does not compare a historical time or hypothetical facts.

`compare()` returns:

- `current`, `proposed`, `delta`, `lifecycle`, and `work` arrays;
- `ADDED`, `REMOVED`, `CHANGED`, and `UNCHANGED` delta states;
- summary counts and whether those counts are exact;
- sampled time, source frontier, declaration digest, evidence limit, and
  completeness;
- bounded cost fields and findings.

`compare_results()` exposes rows from the same five bounded arrays. It does not
rerun an unbounded comparison and does not expose a continuation token.

When evidence is incomplete, `state` is `partial`, `truncated` is true,
`evidence.complete` and `summary.counts_exact` are false, and exact aggregate
counts may be null. Callers may rerun with a higher `evidence_limit` within the
installed maximum; they must not treat partial output as complete.

Comparison rejects callers that cannot inspect the deployed target or source
relations. RLS-enabled evaluated sources are rejected. Installed behavior is
fail-closed rejection, not a contractual redaction facility.

Comparison is a `STABLE`, read-only operation and returns would-be lifecycle
and work; it does not deploy the proposal or invoke `pgreact.run()`. The
installed before/after checksum qualifies this selected pg-react state:
authoritative frontier, declarations, rule versions, activation state,
decision subject state, the public work projection, and policy-set versions.
It does not cover source tables, lifecycle history, attempts, or delivery
state, so no broader checksum claim is part of this contract.

Determinism applies to ordered semantic results, counts, completeness, target
identity, frontier, sampled time, and declaration digest for identical inputs
and state. Runtime measurements such as `cost.elapsed_ms` are excluded.
`rows_considered`, affected-subject counts, would-be-work counts, and elapsed
time are populated where applicable. Installed
`dependency_fan_out`, `reevaluation`, `cascade_depth`, and
`temporary_storage_bytes` are placeholders, and `memory_bytes` is unavailable;
they are not measured cost evidence.

The v1 contract requires comparison semantics to agree with deployed behavior
for qualified fixtures. It does not require comparison and production to share
one evaluator implementation.

## Runtime contract

`pg_react` is preloaded with `pg_trickle`. `pg_react.databases` starts one
PostgreSQL-managed pg-react worker/coordinator loop for each distinct
configured database. Each loop polls and invokes the managed cycle using the
configured worker role, interval, batch size, and backpressure threshold.

PostgreSQL-managed polling is supported. Uncoordinated pg_trickle scheduling is
not: `pg_trickle.enabled` remains `off`, and pg-react owns explicit
`DIFFERENTIAL` refresh coordination. The `pg-reactd` program is a compatibility
worker path, not the ordinary managed runtime.

## Semantic and compatibility commitments

For all `1.x` releases:

- valid ordinary calls and required view meanings remain usable;
- existing stable finding codes keep their meaning;
- lifecycle generations and revisions remain deterministic;
- eligibility is checked before truth and again before work executes;
- leases, retries, revalidation, and transactional database actions remain
  safe;
- external delivery remains at least once and requires consumer
  deduplication;
- effective-date, database-time, event-time, support, retraction, and decision
  semantics do not change silently;
- durable state never requires editing a private catalog.

New nullable columns, non-conflicting optional overloads, detail fields, and
finding codes may be added. An incompatible ordinary API or semantic change
requires a future major release and a migration path.

## Supported boundary

The qualified `1.0.0-rc.1` environment is PostgreSQL `18.3`, pg_trickle
`0.81.0`, pgrx `0.18.0`, Linux `amd64`, the container artifact,
coordinator-owned explicit `DIFFERENTIAL` maintenance, and `READ COMMITTED`
transactions. RLS-protected evaluated sources, uncoordinated pg_trickle
scheduling, unsupported isolation levels, and unlisted operating systems or
architectures are not silently accepted.

The support matrix, upgrade policy, limits, security boundary, recovery model,
operations, compatibility, and deprecations are normative companion
documents.

# pg-react 1.0.0 contract

This is the normative v1 contract. The M33 qualification artifact is
`0.30.0`; the first GA candidate is `1.0.0-rc.1`. The old `0.1.1` material is
historical M4 documentation and is not this contract.

## Ordinary SQL surface

The ordinary path uses the `pgreact` schema, stable names, typed PostgreSQL
identities, and one global coordinator:

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

The required ordinary views are `rules`, `matches`, `decisions`,
`policy_sets`, `work`, `attempts`, and `health`. Their required columns and
meanings are listed in [`v1-api-inventory.json`](v1-api-inventory.json), which
is generated from the installed artifact by the M33 qualification test.

`pgreact_api` compatibility functions remain available where the inventory
marks them as compatibility or administrative. They delegate to the same
authoritative runtime. Private schemas and catalogs are not an application
API.

## Declaration fields

`pgreact.rule` freezes these fields: `name`, `condition`, `semantic_key`,
`kind`, optional typed consequences (`on_activate`, `on_deactivate`,
`on_change`), `bootstrap_policy`, `change_columns`, `salience`,
`agenda_group`, `conflict_key_columns`, `max_attempts`,
`initial_backoff_seconds`, `backoff_multiplier`, and `max_backoff_seconds`.

`pgreact.decision` freezes `name`, `candidate_relation`, `subject_key`,
`candidate_key`, `priority`, `results`, `valid_from`, `valid_to`, and
`max_candidates`.

`pgreact.policy_set` freezes `name`, `version`, typed `members`,
`applicability`, `subject_keys`, `valid_from`, `valid_to`, and
`evidence_limit`.

Canonical declarations use API version `1`. Result envelopes preserve their
top-level `state`, `summary`, `normalized`, `findings`, and `runtime` fields
where present. Every finding has `code`, `severity`, `blocking`, `target`,
`field`, `message`, `hint`, and `details`.

## Semantic commitments

For all `1.x` releases:

- valid ordinary calls and required view columns remain usable;
- existing stable finding codes keep their meaning;
- lifecycle generations and revisions remain deterministic;
- eligibility is checked before truth and again before work executes;
- leases, retries, revalidation, and transactional database actions remain
  safe;
- external delivery remains at-least-once and requires consumer deduplication;
- effective-date, database-time, event-time, support, retraction, and decision
  semantics do not change silently;
- durable state never requires editing a private catalog.

New nullable columns, non-conflicting optional overloads, detail fields, and
finding codes may be added. An incompatible change requires a future major
release and a migration path.

## Supported boundary

The exact supported tuple is PostgreSQL `18.3`, pg_trickle `0.81.0`, pgrx
`0.18.0`, Linux `amd64`, the published container artifact, coordinator-owned
explicit `DIFFERENTIAL` maintenance, and `READ COMMITTED` transactions.
RLS-protected source relations, automatic scheduling, unsupported isolation
levels, and unlisted operating-system or architecture combinations are not
silently accepted; `doctor()` reports detectable unsupported combinations.

The support matrix, upgrade policy, resource limits, security boundary,
recovery model, operational procedures, and deprecations are normative
companion documents.

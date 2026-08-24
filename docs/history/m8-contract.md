# M8 monotone recursive derivation contract

M8 is extension `0.5.0`. It lets positive derivation rules read public derived
relations while preserving M7 facts, supports, provenance, rule packs, and the
inherited support boundary.

## Program definition and validation

A program JSON object has exactly `name`, `version`, `max_iterations`,
`max_facts`, and `rules`. Each rule has exactly `name`, `definition`, `key`,
`target`, `version`, and `inputs`; each input has exactly `relation` and `key`.
Names and versions provide portable immutable identity.

```sql
SELECT * FROM pgreact.validate_derivation_program(:program_json);
```

Validation recursively discovers dependencies through nested views. The
declared inputs must exactly equal those dependencies. Each derived input must
occur once and preserve one non-null `bigint` key through an unconditional
inner-join equality with the output key. Positive filters (including `EXISTS`
and `ANY` over authoritative inputs), inner joins, and immutable `pg_catalog`
functions are supported. Derived semijoins, negation, aggregation or `GROUP BY`,
outer or anti joins, `UNION`, recursive CTEs, set generators, key value
invention, non-immutable functions, and unresolved or undeclared dependencies
are rejected before mutation.

## Rule packs and public surface

Programs are added, replaced, and removed only by format-version `1` rule
packs. Legacy packs may omit both M8 fields; `programs` and `remove_programs`
are independently optional arrays and default to `[]` when omitted.
Preview, drift detection, dependency ordering, and deployment cover the
complete graph. There is no standalone create, replace, or active pack-owned
removal path. A rule name and target relation belong to at most one active
program; validation rejects both catalog conflicts and sibling conflicts in one
pack before mutation.
An active program can be replaced or removed only by a later version of its
owning logical pack.

```sql
SELECT pgreact.refresh_derivation_program(:program_version_id);
SELECT pgreact.explain_recursive_fact(
  :program_version_id, :relation_version_id, :semantic_key);
SELECT pgreact.reconcile_derivation_program(:program_version_id);
SELECT pgreact.remove_derivation_program(:program_version_id);
```

The removal primitive rejects an active pack-owned program; deploy the next
pack version with a `remove_programs` entry instead. Independent derivation
creation, replacement, and removal likewise reject active program relations or
members. Inherited per-rule lifecycle, refresh, reconciliation, consequence,
batch, and agenda entry points also reject active program members, preserving
the closed graph after deployment.

The public inspection surface is:

```text
pgreact.derivation_programs
pgreact.derivation_components
pgreact.derivation_program_runs
pgreact.derivation_iterations
pgreact.recursive_support_inputs
pgreact.derivation_program_repair_diagnostics
```

Installation remains private by default. Following the existing author grant
recipe in `docs/v1-security.md`, grant the pack functions and the five M8
functions explicitly to the program owner, and grant `SELECT` on these six
views to the owner or reader. No access to `pgreact_internal` is required.

## Convergence, identity, and limits

Existing `pg_trickle` streams detect committed authoritative or derived input
changes. After a delta, `refresh_derivation_program` takes the component lock and
rebuilds the affected program from empty in dependency order. Components
stabilize in dependency order, with strongly connected components iterating to
the least fixed point. All staged components commit at one frontier. On any evaluation,
`max_iterations`, or `max_facts` failure, refresh returns SQL `NULL`, restores the
previous complete frontier, and records a `FAILED` run with its SQLSTATE and
diagnostic text for operators.

Logical support identity is stable across repeated evaluation. Every support
records its exact rule version, target fact, and stable input edges. Equivalent
reevaluation is idempotent; a fact is current only when some finite support path
reaches authoritative input. Circular support alone is discarded.

`explain_recursive_fact` returns every active grounded alternative, follows
stable support-input edges, and replaces a repeated edge with a cycle marker.
The result is finite, terminates on cycles, and does not claim general
base-tuple lineage. Exact normalized behavior is frozen in `docs/m8-entry.md`.

## Reconciliation, recovery, and compatibility

Reconciliation rebuilds the clean fixed point under the component lock and
repairs missing, extra, stale, circular-only, and wrong-frontier program state.
Every repair is public; a second run is a no-op. Crash restart and supported
physical restore preserve or reconcile programs, components, iterations,
facts, supports, input edges, provenance, and downstream lifecycle state.
Successful program recovery clears its member reconciliation barriers; other
rules complete the inherited per-rule recovery workflow.

The only supported in-place upgrade is `0.4.0 -> 0.5.0`. Existing single-rule
APIs, rule packs without program fields, both worker protocols, default and
batch execution, and non-recursive derivation output remain unchanged.

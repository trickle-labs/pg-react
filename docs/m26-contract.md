# M26 contract — decision tables

M26 is extension `0.23.0`, with a direct upgrade from `0.22.0`. It turns one
maintained PostgreSQL candidate relation into one durable, versioned, and
explainable decision result per subject. SQL remains the policy language; M26
adds deterministic selection and lifecycle semantics, not a new rule language.

## Public model

One decision-program version declares:

1. a stable program and version identity;
2. one maintained candidate relation and its owner;
3. one subject semantic key and one stable candidate identity;
4. one non-null `bigint` priority and one or more typed result columns; and
5. maintenance mode, grants, and the public winner relation.

Candidate identity is stable for the life of a candidate. A subject may have
any supported number of candidates within the published limit. The unique
lowest priority value wins. Equal lowest values never choose by row order,
transaction order, or timing: the subject is explicitly ambiguous.

## Result states and lifecycle

Public status, history, preview, and explanation expose the program and
version, candidate evidence, winner or ambiguity, lifecycle identity, result,
support, provenance, diagnostics, and authorization outcome. Evidence is
canonically ordered, bounded, and reports truncation when the bound is reached.

The public subject states are:

- `never_observed`: no candidate or retained winner history is known;
- `no_candidate`: a known subject has no remaining candidate and no default is
  invented;
- `winner`: exactly one lowest-priority candidate is authoritative; or
- `ambiguous`: two or more candidates share the lowest priority.

Candidate changes recompute only affected subjects. A losing-candidate change
that preserves the winner identity and result causes no lifecycle transition.
A changed result for the same winner is a revision. Winner disappearance closes
the activation; appearance or replacement opens a new activation. Replacement
is one ordered old-winner-out/new-winner-in transition, never a mixed-version
frontier or two authoritative winners.

All consequences remain asynchronous and at-least-once. A complete committed
frontier provides deterministic eligibility and catch-up, not synchronous
selection or exactly-once external effects.

## Validation and safety

Before durable mutation, validation rejects missing or unstable identities,
duplicate `(subject, candidate)` pairs, nullable or wrong-typed priorities and
results, unsupported result types, foreign ownership, unsafe dependencies,
row-level security, schema drift, and candidate counts above the published
limit. It also verifies grants, retention, recovery, and version compatibility.

Deployment and replacement are atomic. Candidate, parameter, effective-date,
maintenance, pause/resume, reconciliation, retention, recovery, and standby
transitions use the inherited coordinator, dependency, locking, work, and
frontier rules. No rejected declaration may leave partial winner, lifecycle,
provenance, or agenda state.

## Supported boundary

M26 inherits the complete M25 platform and all earlier boundaries: public API,
managed workers, typed keys, PostgreSQL permissions, maintenance and isolation
modes, immediate maintenance, shared conditions, retention, recovery,
resource limits, external effects, aggregates, windows, provenance, temporal
behavior, effective dating, parameter families, diagnostics, and usability.

M26 supports one PostgreSQL-native candidate relation per declared decision
program, one subject key, one stable candidate identity, `bigint` priority,
typed result columns, deterministic single-winner selection, explicit ties,
bounded competitor evidence, and versioned atomic deployment.

## Non-goals

M26 does not add a decision-table DSL, spreadsheet or range syntax, predicate
parser, generated SQL, visual editor, AI authoring, or second evaluation
engine. It does not support multi-winner decisions, weighted scoring,
ensembles, optimization, probabilistic ranking, arbitrary tie-breakers, or
user-defined comparisons.

It does not provide predeployment coverage/conflict analysis, required
defaults, unreachable-candidate detection, winner-distribution analysis,
policy-set gating, hypothetical facts, deployment impact simulation, replay,
backtesting, bounded synchronous firing, unstratified negation, recursive
aggregation, client DSLs, or domain packages. Coverage and conflict analysis
are M27 work.

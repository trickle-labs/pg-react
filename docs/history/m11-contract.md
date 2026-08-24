# M11 contract — PostgreSQL-first API

M11 replaces the provisional `0.7.0` presentation with the public
`pgreact_api` schema. This is the compatibility commitment for the M11
extension and bundled worker release; `0.7.0` names are not commitments except
where [the compatibility matrix](m11-0.7-compatibility.md) says `BRIDGE`.

## Authority and boundary

PostgreSQL objects and SQL are authoritative. A view or relation is a
condition, an explicit semantic key identifies its match, and a typed
PostgreSQL function or transactional outbox action is its consequence.
Manifests and `pg-reactd` only package that PostgreSQL intent.

`pgreact_api` is the only application-facing schema. `pgreact_internal`,
`pgreact_runtime`, generated dispatchers, stored immutable identifiers, and
physical catalog layout are private. `PUBLIC` receives no grants. Deployments
grant author, operator, worker, and reader roles only the corresponding
`pgreact_api` objects.

M11 preserves every M0--M10 semantic, durable-state, security, recovery,
external-effect, resource-limit, and worker-protocol guarantee. It adds no
reasoning semantic, execution mode, protocol 3, support-matrix expansion, or
second rule language.

## Supported tuple

The inherited M10 tuple is the complete M11 support boundary: PostgreSQL
18.3; `pg_trickle` 0.81.0 at
`ba41c9c2e2bbf2195917fcdcc89efa8ab3089dcb`; pgrx 0.18.0; Linux `amd64`;
coordinator-owned explicit `DIFFERENTIAL`; `READ COMMITTED`; one non-null
`bigint` semantic key with codec 1; no RLS source views; physical recovery;
and worker protocols 1 and 2. Any other tuple is unsupported and must fail
rather than degrade.

## Frozen public inventory

All routine rule operations are name-first. The exact `0.8.0` function-name
allow-list is `author_rule`, `claim`, `execute`, `explain_rule`, `health`,
`rule_status`, `run_rule`, and `validate_rule`; `author_rule` and
`validate_rule` each have an ordinary-rule and a released-pack overload.

| Surface | `pgreact_api` contract |
| --- | --- |
| Author | `validate_rule(condition, semantic_key, action_identity)` and `author_rule(rule_name, condition, semantic_key, ...)`; action identity is text so authors do not resolve a private function identifier. |
| Pack | JSON overloads of `validate_rule` and `author_rule` validate and deploy the released format-versioned pack without adding a second language. |
| Operator | `rule_status(name)`, `explain_rule(name)`, `run_rule(name)`, and `health()` return versioned JSON envelopes. |
| Worker | `claim(worker_id, max_items, lease_for)` and `execute(episode_id, worker_id, lease_token)` preserve the inherited single-episode claim and execution behavior. The bundled worker bridges the released protocol-1 and protocol-2 sequences while old work drains. |

The allow-list is deliberately name-first: routine calls never require callers
to supply a rule version, activation, episode, component, stratum, support, or
frontier identifier. Exact-identity overloads are advanced inspection or
recovery operations and return the same immutable state and evidence as M10.

## Required envelopes

Every validation, deployment, operation, and worker rejection returns the
existing versioned diagnostic envelope: contract version, code, severity,
object identity, message, hint, and details. M11 may rename presentation
fields only through a bridge that carries the complete original envelope.

Status, history, and explanation results are versioned envelopes. They expose
name and current state first, then immutable version, activation, episode,
support, frontier, stratum, negative-evidence, and aggregate-evidence identity
only when a caller asks for exact history or evidence. Aggregate explanation
continues to report the count condition without enumerating counted rows.

## Upgrade and worker rule

The supported upgrade begins with a populated `0.7.0` database, stops workers,
installs the M11 extension and worker, runs `ALTER EXTENSION`, and resumes only
after health, recovery, and protocol checks succeed. It preserves rules,
immutable bindings, activations, episodes, leases, attempts, programs,
frontiers, facts, supports, provenance, negative and aggregate evidence, and
pending work. There is no downgrade.

The M11 worker implements both inherited protocols. A worker whose selected
protocol is not accepted stops before claiming. Existing protocol-1 and
protocol-2 work retains its M0--M10 claim, lease, retry, batch, and
external-effect behavior; a worker never claims on a standby.

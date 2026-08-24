# M7 maintained derived knowledge contract

M7 is extension `0.4.0`. It adds durable, non-recursive derived facts while preserving both M6 worker protocols and every earlier rule API.

## Relations, derivations, and truth maintenance

A derived relation is an immutable version with a schema-qualified public name, owned PostgreSQL composite row type, one non-null `bigint` semantic key, owner, and portable relation identity. Its generated security-barrier view is read-only and exposes only current facts.

```sql
pgreact.validate_derived_relation(text, regtype, name[], integer)
pgreact.create_derived_relation(text, regtype, name[], integer) RETURNS uuid
pgreact.remove_derived_relation(uuid)
```

A derivation source is an authoritative view whose complete row shape equals the target type. Each active source match contributes exactly one support to its projected target fact. Derivations have no consequence and create no agenda episode.

```sql
pgreact.validate_derivation_rule(regclass, uuid, name[], integer)
pgreact.create_derivation_rule(text, regclass, name[], uuid, integer, text) RETURNS uuid
pgreact.replace_derivation_rule(uuid, regclass, name[], integer, text) RETURNS uuid
pgreact.remove_derivation_rule(uuid)
pgreact.refresh_derived_relation(uuid) RETURNS bigint
```

Support identity binds the exact relation version, rule version, activation identity, generation, revision, semantic key, fact payload, and source binding. Equivalent active supports collapse to one current fact. Removing one support preserves that fact; removing the last retracts it. Two active supports for the same key with different payloads abort the transaction.

Derivation source views may not read a derived relation, directly or through another view. Ordinary constraint and command rules may read the generated public view. Recursion, derivation chains, negation, temporal reasoning, and direct fact mutation are outside M7.

## Frontier and downstream observation

`refresh_derived_relation` takes the shared lifecycle lock and refreshes every active producer in stable name/version order. Support and fact changes commit atomically and advance the relation frontier once per changing transaction; a no-op refresh preserves the frontier and history.

PostgreSQL gives each statement one input snapshot. Refresh an ordinary downstream rule in the next SQL statement after the derived refresh:

```sql
SELECT pgreact.refresh_derived_relation(:relation_version_id);
SELECT pgreact.refresh_rule(:observer_rule_version_id);
```

That second statement observes the committed derived frontier and applies the existing lifecycle coalescing contract.

## Query, explanation, repair, and retention

```sql
SELECT * FROM pgreact.current_facts(:relation_version_id);
SELECT * FROM pgreact.support_history WHERE relation_version_id = :relation_version_id;
SELECT pgreact.explain_fact(:relation_version_id, :semantic_key);
SELECT pgreact.reconcile_derived_relation(:relation_version_id);
SELECT * FROM pgreact.derived_repair_diagnostics;
```

`explain_fact` returns the exact current fact and active support set with immutable rule versions, activation generations, and recorded source bindings. It does not claim base-tuple lineage. Support history is retained across deactivation, reactivation, replacement, and relation removal; the inherited payload-pruning API does not remove derived provenance.

Reconciliation recomputes expected supports from active derivation activations, repairs missing, extra, or stale supports and facts under the lifecycle lock, and records one public diagnostic per defect. A second reconciliation is a no-op. `health_check` reports unsupported, missing, or payload-conflicting derived facts.

Physical backup/PITR is supported. After restore, use the existing `prepare_recovery`, `rebuild_transient_metadata`, derived reconciliation, and `health_check` workflow. Logical restoration of live runtime state remains unsupported.

## Rule packs and public workflow

Format-version `1` packs remain compatible and may add four optional arrays: `derived_relations`, `derivations`, `remove_derivations`, and `remove_derived_relations`. Relation entries declare `name`, `row_type`, `key`, and `version`; derivations declare `name`, `definition`, `key`, `target`, `version`, and optional `bootstrap_policy` and `depends_on`.

Validation rejects unresolved objects, incompatible row shapes, derived sources, dangling dependencies, mixed versions, implicit removal, and invalid ordering. Preview includes derived graph actions in the plan digest. Deploy serializes with refresh and DDL lifecycle locks, applies the relation/producer/consumer graph atomically, and preserves the previous graph on injection, drift, or failure. Explicit removal orders consumers before producers and relations.

A minimal direct workflow is executable in `tests/m7.sql`; the atomic pack workflow is executable in `tests/m7-pack.sql`. Upgrade only from `0.3.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.4.0';
```

Existing rules, packs, episodes, attempts, batches, worker protocols, and default execution behavior remain unchanged.

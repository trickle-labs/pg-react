# M25 contract — parameterized policy families

M25 is extension `0.22.0`, with a direct upgrade from `0.21.0`. It lets one
ordinary rule or derivation-program version consume typed PostgreSQL parameter
rows. The parameter table is data, not a template: the consuming condition
view or program input defines the normal SQL join.

## The small public model

1. An author declares a family with one `bigint NOT NULL` unique key and one or
   more required scalar value columns.
2. A condition view joins that ordinary table and is declared as the policy
   version's input. No SQL is generated and no rule definition is edited when
   a parameter row changes.
3. The existing pg-trickle stream and pg-react coordinator process the joined
   result. An insert, update, or delete therefore uses the same activation,
   lifecycle, lock, agenda, worker, and recovery paths as any other source
   change.

The supported value types are `boolean`, `smallint`, `integer`, `bigint`,
`numeric`, `text`, `varchar`, `uuid`, `date`, `timestamp`, and `timestamptz`.
The family key is deliberately `bigint` in M25 so it has the same portable
`bigint-v1` identity as existing rules.

## Public API

```sql
pgreact_api.validate_parameter_family(
    family_name text,
    parameter_relation regclass,
    parameter_key_column name,
    parameter_value_columns name[]
) RETURNS TABLE (...)

pgreact_api.author_parameter_family(
    family_name text,
    parameter_relation regclass,
    parameter_key_column name,
    parameter_value_columns name[]
) RETURNS uuid

pgreact_api.author_parameterized_rule(
    policy_name text,
    rule_name text,
    condition regclass,
    semantic_key name,
    family_name text,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL,
    ... inherited rule options ...,
    initial_parameters jsonb DEFAULT '[]'
) RETURNS uuid

pgreact_api.author_parameterized_program(
    policy_name text,
    definition jsonb,
    family_name text,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL,
    initial_parameters jsonb DEFAULT '[]'
) RETURNS uuid

pgreact_api.bind_parameter_family(family_name text, policy_version_id uuid)
pgreact_api.grant_parameter_family_editor(family_name text, editor_role regrole)
pgreact_api.revoke_parameter_family_editor(family_name text, editor_role regrole)

pgreact_api.parameter_family_preview(
    family_name text, parameter_key bigint, proposed_values jsonb
) RETURNS jsonb
pgreact_api.parameter_family_status(family_name text DEFAULT NULL) RETURNS jsonb
pgreact_api.parameter_family_history(family_name text) RETURNS jsonb
pgreact_api.parameter_family_explain(
    family_name text, policy_name text, semantic_key bigint
) RETURNS jsonb
pgreact_api.parameter_family_doctor() RETURNS jsonb
```

The long rule signature retains M24's inherited retry, consequence, conflict,
agenda, and bootstrap options. `initial_parameters` is an array of complete
or defaultable rows. The definition and initial rows are committed together;
if either fails, neither is durable.

`parameter_family_preview` does not write the table. It returns the current
row, the proposed typed row, whether the row differs, each consuming policy
version, and the current match state for that key. The actual joined condition
is evaluated by the normal coordinator when the ordinary table change is
committed; this keeps preview side-effect free and avoids a second rule engine.

## Validation and authorization

Validation rejects missing or empty names, views, row-level security, foreign
owners, non-`bigint` or nullable keys, missing uniqueness, duplicate columns,
nullable or generated value columns, unsupported types, and rows beyond the
100,000-row admission limit. The declaration stores the relation signature;
doctor reports a definition change instead of silently accepting drift.

The family owner may author and edit values. The owner or configured operator
may grant a separate value-editor role. Policy logic ownership and parameter
value ownership can therefore be different. The configured reader role can
inspect status, history, preview, and explanation through the granted public
API; `PUBLIC` has no M25 function or catalog access. M25 does not yet provide
per-family reader grants, so deployments needing family-existence isolation
must keep the reader role restricted until that follow-up is delivered.

## Boundaries

M25 keeps M24 effective-dated versions, database-time frontiers, asynchronous
at-least-once consequences, immutable rule definitions, ordinary PostgreSQL
permissions, and inherited retention/recovery behavior. Parameter events are
separate from inherited policy-version history; a family-definition replacement
API is deferred.

M25 does not add templating, string substitution, arbitrary JSON parameters,
generated per-tenant rules, decision tables, winner selection, policy-set
gating, hypothetical fact simulation, backtesting, client DSLs, or visual or
AI authoring.

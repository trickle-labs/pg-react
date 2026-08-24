# M14 contract — explainability and reasoning UX

M14 is extension `0.11.0`. It keeps M13 execution semantics unchanged while making diagnosis, finite evidence, and derived-program declaration available through `pgreact_api`.

## Diagnosis and explanation

`pgreact_api.doctor()` is read-only. It returns contract version `4`, `ready` or `attention`, and ordered diagnostics from existing health, drift, failure, frontier, extension-compatibility, and facade-role state. A warning is informational; only an error makes the result `attention`. It never repairs, grants, retries, deploys, or changes state.

`explain` is an overload family. `explain(rule)` remains the M13 compatibility result. New overloads return a version-4 envelope with `target` and `evidence`:

```sql
SELECT pgreact_api.explain('app.fact', 42);
SELECT pgreact_api.explain('rule.name', :match_uuid);
SELECT pgreact_api.explain('job', :job_id, true);
SELECT pgreact_api.explain('program.name', true);
```

Fact evidence is the existing finite grounded support proof, including recursive inputs and M9/M10 negative or aggregate conditions. Missing facts return `evidence: null`; the API does not invent absent-source lineage.

## PostgreSQL-native programs

An author first declares each typed derived relation, then validates, previews, and deploys one program. A rule names a schema-qualified PostgreSQL definition view, output key, target relation, and immutable version. Do not provide `inputs`: M14 follows PostgreSQL view dependencies to active derived-relation views and writes the normalized positive graph itself. Components and strata remain engine-derived and stable.

`negative_inputs` and `aggregate_input` retain the M9/M10 condition shapes: they represent a semantic absence or count threshold not observable from the positive view dependency graph. Unsupported, unresolved, dynamic, volatile, or cyclic declarations are rejected by the inherited validators before atomic pack deployment.

```sql
SELECT pgreact_api.declare_derived_relation('app.fact', 'app.fact_row'::regtype, 'id');
SELECT pgreact_api.preview_program(:program_without_inputs);
SELECT pgreact_api.deploy_program(:program_without_inputs, :plan_digest);
```

The five-argument `configure_roles(author, operator, worker, reader, advanced_reader)` retains M13 grants and adds program authoring plus normal diagnosis/evidence grants. Only the explicitly named advanced reader receives `explain_advanced(program_version_id)`; it is the immutable catalog-evidence boundary. `PUBLIC` receives neither façade nor private-schema access.

## Boundary

M14 adds no reasoning semantics, SQL parser, dynamic-SQL inference, automatic repair, managed workers, new key codecs, composite keys, RLS support, or unbounded proof search. The supported upgrade is `0.10.0 -> 0.11.0`.


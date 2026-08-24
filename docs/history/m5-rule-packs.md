# M5 safe rule-set deployment

Extension `0.2.0` groups existing v1 constraint and command rules into one previewed PostgreSQL transaction. It does not add a rule language or execution mode: views, typed functions, immutable rule versions, worker protocol `1`, and outbox envelope `1` remain authoritative.

## Contract

A portable manifest is a JSON object with:

- `format_version: 1`, immutable logical `pack`, `version`, and `owner` strings;
- `rules` in dependency order, using the existing v1 rule fields;
- `depends_on` names that appear earlier in the same version;
- `old_work_policy` of `DRAIN_OLD` or `CANCEL_OLD` on replacements;
- an explicit `remove` entry for every former member omitted from `rules`.

Dependencies control deployment order only. `DRAIN_OLD` preserves pending, retrying, and leased episodes through their exact immutable binding. `CANCEL_OLD` cancels pending and retrying work but never ambiguously revokes a lease. Removals are not inferred.

The manifest stores no OIDs. A separate mapping object resolves logical view, exact function, and owner identities in each environment:

```sql
SELECT jsonb_build_object(
  'roles', jsonb_build_object('author', current_user),
  'objects', jsonb_build_object(
    'logical.overdue', 'rule_def.overdue_invoice',
    'logical.open(pgreact.activation_context,logical.overdue)',
      'rule_action.open_collection(pgreact.activation_context,rule_def.overdue_invoice)'
  )
) AS production_mappings;
```

The mapped owner must be the session user and must own every mapped view and function.

## Validate, preview, and deploy

Assume `pack_definition` and `environment_mappings` are application parameters. All calls below are public APIs:

```sql
SELECT *
FROM pgreact.validate_pack(:'pack_definition'::jsonb, :'environment_mappings'::jsonb);

SELECT *
FROM pgreact.preview_pack(:'pack_definition'::jsonb, :'environment_mappings'::jsonb);

SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(:'pack_definition'::jsonb, :'environment_mappings'::jsonb)
\gset

SELECT pgreact.deploy_pack(
  :'pack_definition'::jsonb,
  :'plan_digest',
  :'environment_mappings'::jsonb
);
```

Preview reports ordered additions, replacements, removals, dependencies, generated-object changes, prior work, and lifecycle risks. Deployment acquires the lifecycle and DDL locks, repeats validation, and recomputes the digest. Source/function DDL, work-state changes, or another deployment make the preview stale and require a new preview.

One PostgreSQL transaction covers pack catalogs, rule catalogs, pg_trickle stream creation/retirement, active versions, and history. An error leaves the complete old pack and no new generated objects. Recovery is therefore: inspect the error, query the unchanged state, correct the manifest or mapped objects, preview again, and retry.

```sql
SELECT * FROM pgreact.pack_history('collections');
SELECT pgreact.explain_pack('collections');
```

## Promote development to production

Keep the manifest byte-for-byte identical. Supply development mappings in development and production mappings in production, then run the same validate, preview, and deploy sequence. Compare `definition_digest` from `pack_history`; plan digests are environment-specific because they intentionally include resolved object fingerprints and current work.

Do not dump private pack catalogs, copy generated names, or substitute OIDs into the manifest. The executable two-database workflow is `tests/m5-setup.sql`, `tests/m5-promotion.sql`, and `tests/m5.sh`.

## Upgrade and validation

Install `pg_react--0.2.0.sql` for a new database or run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.2.0';
```

The only M5 upgrade source is immutable `0.1.1`. The complete repository gate is:

```text
bash tests/m5.sh pg-react:v0.2.0
```

It reruns M0–M3 compatibility, the v1 reference and physical-recovery workflows, the exact M5 API inventory, direct upgrade, every deployment failure phase, stale preview, dependency/binding/ownership errors, old-work dispatch, concurrent deployment/source/function DDL, history/diagnostics, and promotion into a second environment.

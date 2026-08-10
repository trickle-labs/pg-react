\set ON_ERROR_STOP on
\if :{?m8_seed_left}
\else
  \set m8_seed_left true
\endif
\if :{?m8_seed_right}
\else
  \set m8_seed_right true
\endif
\if :{?m8_left_first}
\else
  \set m8_left_first true
\endif
\if :{?m8_seed_delay}
\else
  \set m8_seed_delay 0
\endif

CREATE SCHEMA m8_ref;
CREATE TYPE m8_ref.fact_row AS (id bigint);
CREATE TABLE m8_ref.left_seed (id bigint PRIMARY KEY);
CREATE TABLE m8_ref.right_seed (id bigint PRIMARY KEY);
CREATE VIEW m8_ref.left_active AS SELECT id FROM m8_ref.left_seed;
CREATE VIEW m8_ref.right_active AS SELECT id FROM m8_ref.right_seed;
CREATE TABLE m8_ref.manifests (
    version integer PRIMARY KEY,
    definition jsonb NOT NULL,
    mappings jsonb NOT NULL
);

WITH mappings(value) AS (
    VALUES (jsonb_build_object(
        'roles', jsonb_build_object('owner', current_user),
        'objects', jsonb_build_object(
            'm8.fact_row', 'm8_ref.fact_row',
            'm8.left', 'm8_ref.left_active',
            'm8.right', 'm8_ref.right_active',
            'm8.a', 'm8_ref.a',
            'm8.b', 'm8_ref.b',
            'm8.c', 'm8_ref.c',
            'm8.d', 'm8_ref.d')))
)
INSERT INTO m8_ref.manifests
SELECT 0, jsonb_build_object(
    'format_version', 1, 'pack', 'm8-reference-pack', 'version', '0',
    'owner', 'owner', 'rules', '[]'::jsonb, 'remove', '[]'::jsonb,
    'derived_relations', jsonb_build_array(
        jsonb_build_object('name', 'm8.a', 'row_type', 'm8.fact_row',
                           'key', 'id', 'version', 1),
        jsonb_build_object('name', 'm8.b', 'row_type', 'm8.fact_row',
                           'key', 'id', 'version', 1),
        jsonb_build_object('name', 'm8.c', 'row_type', 'm8.fact_row',
                           'key', 'id', 'version', 1),
        jsonb_build_object('name', 'm8.d', 'row_type', 'm8.fact_row',
                           'key', 'id', 'version', 1)),
    'derivations', '[]'::jsonb, 'remove_derivations', '[]'::jsonb,
    'remove_derived_relations', '[]'::jsonb,
    'programs', '[]'::jsonb, 'remove_programs', '[]'::jsonb
), value FROM mappings;

SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 0),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 0)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 0), :'plan_digest',
    (SELECT mappings FROM m8_ref.manifests WHERE version = 0));

CREATE VIEW m8_ref.left_to_a AS SELECT id FROM m8_ref.left_active;
CREATE VIEW m8_ref.right_to_a AS SELECT id FROM m8_ref.right_active;
CREATE VIEW m8_ref.a_to_b AS SELECT id FROM m8_ref.a;
CREATE VIEW m8_ref.a_to_c AS SELECT id FROM m8_ref.a;
CREATE VIEW m8_ref.b_to_c AS SELECT id FROM m8_ref.b;
CREATE VIEW m8_ref.c_to_d AS SELECT id FROM m8_ref.c;
CREATE VIEW m8_ref.d_to_c AS SELECT id FROM m8_ref.d;
CREATE VIEW m8_ref.observe_d AS SELECT id FROM m8_ref.d;

SELECT pgreact.create_rule(
    name => 'm8.observe_d', definition => 'm8_ref.observe_d'::regclass,
    key_columns => ARRAY['id'], kind => 'CONSTRAINT'
) AS observer_rule_version_id \gset
SELECT set_config('m8.observer', :'observer_rule_version_id', false);

UPDATE m8_ref.manifests
SET mappings = mappings || jsonb_build_object(
    'objects', mappings -> 'objects' || jsonb_build_object(
        'm8.left_to_a', 'm8_ref.left_to_a',
        'm8.right_to_a', 'm8_ref.right_to_a',
        'm8.a_to_b', 'm8_ref.a_to_b',
        'm8.a_to_c', 'm8_ref.a_to_c',
        'm8.b_to_c', 'm8_ref.b_to_c',
        'm8.c_to_d', 'm8_ref.c_to_d',
        'm8.d_to_c', 'm8_ref.d_to_c'))
WHERE version = 0;

CREATE FUNCTION m8_ref.program(program_version integer, split boolean)
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT jsonb_build_object(
    'name', 'm8.reference', 'version', program_version,
    'max_iterations', 16, 'max_facts', 64,
    'rules', jsonb_build_array(
        jsonb_build_object(
            'name', 'm8.left_to_a', 'definition', 'm8.left_to_a',
            'key', 'id', 'target', 'm8.a', 'version', 1,
            'inputs', '[]'::jsonb),
        jsonb_build_object(
            'name', 'm8.right_to_a', 'definition', 'm8.right_to_a',
            'key', 'id', 'target', 'm8.a', 'version', 1,
            'inputs', '[]'::jsonb),
        jsonb_build_object(
            'name', 'm8.a_to_b', 'definition', 'm8.a_to_b',
            'key', 'id', 'target', 'm8.b', 'version', 1,
            'inputs', jsonb_build_array(jsonb_build_object('relation', 'm8.a', 'key', 'id')))
    ) || CASE WHEN split THEN '[]'::jsonb ELSE jsonb_build_array(
        jsonb_build_object(
            'name', 'm8.a_to_c', 'definition', 'm8.a_to_c',
            'key', 'id', 'target', 'm8.c',
            'version', CASE WHEN program_version = 3 THEN 2 ELSE 1 END,
            'inputs', jsonb_build_array(jsonb_build_object('relation', 'm8.a', 'key', 'id')))
    ) END || jsonb_build_array(
        jsonb_build_object(
            'name', 'm8.b_to_c', 'definition', 'm8.b_to_c',
            'key', 'id', 'target', 'm8.c', 'version', 1,
            'inputs', jsonb_build_array(jsonb_build_object('relation', 'm8.b', 'key', 'id'))),
        jsonb_build_object(
            'name', 'm8.c_to_d', 'definition', 'm8.c_to_d',
            'key', 'id', 'target', 'm8.d', 'version', 1,
            'inputs', jsonb_build_array(jsonb_build_object('relation', 'm8.c', 'key', 'id')))
    ) || CASE WHEN split THEN '[]'::jsonb ELSE jsonb_build_array(
        jsonb_build_object(
            'name', 'm8.d_to_c', 'definition', 'm8.d_to_c',
            'key', 'id', 'target', 'm8.c',
            'version', CASE WHEN program_version = 3 THEN 2 ELSE 1 END,
            'inputs', jsonb_build_array(jsonb_build_object('relation', 'm8.d', 'key', 'id')))
    ) END
)
$$;

INSERT INTO m8_ref.manifests
SELECT program_version,
       jsonb_set(jsonb_set(definition, '{version}', to_jsonb(program_version::text)),
                 '{programs}', jsonb_build_array(m8_ref.program(program_version, split))),
       mappings
FROM m8_ref.manifests CROSS JOIN (VALUES (1, false), (2, true), (3, false))
    AS versions(program_version, split)
WHERE version = 0;

\if :m8_seed_left
  \if :m8_seed_right
    \if :m8_left_first
      INSERT INTO m8_ref.left_seed VALUES (7);
      SELECT pg_sleep(:m8_seed_delay);
      INSERT INTO m8_ref.right_seed VALUES (7);
    \else
      INSERT INTO m8_ref.right_seed VALUES (7);
      SELECT pg_sleep(:m8_seed_delay);
      INSERT INTO m8_ref.left_seed VALUES (7);
    \endif
  \else
    INSERT INTO m8_ref.left_seed VALUES (7);
  \endif
\else
  \if :m8_seed_right
    INSERT INTO m8_ref.right_seed VALUES (7);
  \endif
\endif

SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 1),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 1)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 1), :'plan_digest',
    (SELECT mappings FROM m8_ref.manifests WHERE version = 1));

SELECT program_version_id AS program_version_id
FROM pgreact.derivation_programs
WHERE program_name = 'm8.reference' AND state = 'ACTIVE' \gset
SELECT set_config('m8.program', :'program_version_id', false);

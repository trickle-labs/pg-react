\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m12_performance;
CREATE TABLE m12_performance.source (
    id bigint PRIMARY KEY,
    deadline timestamptz NOT NULL
);
CREATE VIEW m12_performance.candidate AS
SELECT id, deadline FROM m12_performance.source;
INSERT INTO m12_performance.source
SELECT id,
       CASE WHEN id = 1
            THEN '2026-06-01 00:00:00+00'::timestamptz
            ELSE '2026-06-02 00:00:00+00'::timestamptz END
FROM generate_series(1, 1000) id;
SELECT pgreact_api.author_deadline_rule(
    'performance-deadline', 'm12_performance.candidate'::regclass,
    'id', 'deadline', 'CONSTRAINT') AS version_id \gset
SELECT set_config('m12.performance_version', :'version_id', false);

DO $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
    index_name text; plan json; actual jsonb;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = current_setting('m12.performance_version')::uuid;
    SELECT index_relation.relname INTO STRICT index_name
    FROM pg_catalog.pg_index index
    JOIN pg_catalog.pg_class index_relation ON index_relation.oid = index.indexrelid
    WHERE index.indrelid = version_row.match_relid
      AND index_relation.relname LIKE 'deadline_%';
    SET LOCAL enable_seqscan = off;
    EXECUTE format(
        'EXPLAIN (FORMAT JSON, COSTS OFF) SELECT %I FROM %s '
        'WHERE %I > ''-infinity''::timestamptz '
        'AND %I <= ''2026-06-01 00:00:00+00''::timestamptz',
        version_row.key_column, version_row.match_relid::regclass,
        'deadline', 'deadline') INTO plan;
    actual := jsonb_build_object(
        'node_type', plan::jsonb #>> '{0,Plan,Node Type}',
        'uses_deadline_index', COALESCE(
            plan::jsonb #>> '{0,Plan,Index Name}',
            plan::jsonb #>> '{0,Plan,Plans,0,Index Name}') = index_name,
        'index_condition_mentions_deadline',
            COALESCE(plan::jsonb #>> '{0,Plan,Index Cond}',
                     plan::jsonb #>> '{0,Plan,Plans,0,Index Cond}') LIKE '%deadline%');
    IF actual -> 'node_type' NOT IN ('"Index Scan"'::jsonb,
                                     '"Index Only Scan"'::jsonb,
                                     '"Bitmap Heap Scan"'::jsonb)
       OR actual -> 'uses_deadline_index' IS DISTINCT FROM 'true'::jsonb
       OR actual -> 'index_condition_mentions_deadline' IS DISTINCT FROM 'true'::jsonb THEN
        RAISE EXCEPTION 'M12 indexed crossing plan changed: %, %', actual, plan;
    END IF;
END
$$;

SELECT pgreact.begin_deadline_refresh(12601);
SELECT pgreact.advance_deadline_clock('2026-06-01 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'activations', (SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', semantic_key, 'active', active,
            'generation', generation, 'revision', revision) ORDER BY semantic_key)
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = current_setting('m12.performance_version')::uuid),
        'clock', (SELECT jsonb_build_object(
            'frontier', frontier,
            'affected_rules', affected_rules,
            'affected_keys', affected_keys)
            FROM pgreact_internal.clock_history ORDER BY clock_event_id DESC LIMIT 1))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'activations', jsonb_build_array(jsonb_build_object(
            'semantic_key', 1, 'active', true, 'generation', 1, 'revision', 0)),
        'clock', jsonb_build_object(
            'frontier', '2026-06-01 00:00:00+00'::timestamptz,
            'affected_rules', 1, 'affected_keys', 1)) THEN
        RAISE EXCEPTION 'M12 selective 1-of-1000 pass changed: %', actual;
    END IF;
END
$$;

SELECT pgreact.begin_deadline_refresh(12602);
SELECT pgreact.advance_deadline_clock('2026-06-02 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();
DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'semantic_key', semantic_key, 'active', active,
        'generation', generation, 'revision', revision) ORDER BY semantic_key)
    INTO actual
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = current_setting('m12.performance_version')::uuid;
    SELECT jsonb_agg(jsonb_build_object(
        'semantic_key', id, 'active', true,
        'generation', 1, 'revision', 0) ORDER BY id)
    INTO expected
    FROM generate_series(1, 1000) id;
    IF actual IS DISTINCT FROM expected
       OR (SELECT jsonb_build_object(
               'frontier', frontier,
               'affected_rules', affected_rules,
               'affected_keys', affected_keys)
           FROM pgreact_internal.clock_history
           ORDER BY clock_event_id DESC LIMIT 1)
          IS DISTINCT FROM jsonb_build_object(
              'frontier', '2026-06-02 00:00:00+00'::timestamptz,
              'affected_rules', 1, 'affected_keys', 999) THEN
        RAISE EXCEPTION 'M12 1000-key catch-up changed';
    END IF;
END
$$;

SELECT 'M12 indexed 1-of-1000 and deterministic catch-up smoke passed';

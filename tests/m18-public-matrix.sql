\set ON_ERROR_STOP on
\o /dev/null
SET TIME ZONE 'UTC';
SET client_min_messages = error;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(oid::regprocedure::text ORDER BY oid::regprocedure::text)
    INTO actual FROM pg_proc
    WHERE pronamespace = 'pgreact_api'::regnamespace
      AND oid::regprocedure::text = ANY (ARRAY[
        'pgreact_api.doctor()',
        'pgreact_api.explain(text,boolean)',
        'pgreact_api.explain(text,jsonb)',
        'pgreact_api.managed_status()',
        'pgreact_api.reconcile_program(text)',
        'pgreact_api.status(text)',
        'pgreact_api.watermark_status(text)']);
    IF actual IS DISTINCT FROM jsonb_build_array(
        'pgreact_api.doctor()',
        'pgreact_api.explain(text,boolean)',
        'pgreact_api.explain(text,jsonb)',
        'pgreact_api.managed_status()',
        'pgreact_api.reconcile_program(text)',
        'pgreact_api.status(text)',
        'pgreact_api.watermark_status(text)') THEN
        RAISE EXCEPTION 'M18 public diagnostic inventory changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE status_value jsonb; explanation jsonb; normalized_explanation jsonb;
        watermark jsonb; managed jsonb;
BEGIN
    IF pgreact_api.doctor() IS DISTINCT FROM jsonb_build_object(
        'contract_version', 6, 'status', 'ready', 'diagnostics', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M18 healthy doctor transcript changed: %', pgreact_api.doctor();
    END IF;
    status_value := pgreact_api.status('m17.reference');
    IF status_value IS DISTINCT FROM jsonb_build_object(
        'contract_version', 5, 'rules', '[]'::jsonb,
        'programs', jsonb_build_array(jsonb_build_object(
            'program', 'm17.reference', 'version', 1, 'state', 'active',
            'frontier', 2, 'max_iterations', 8, 'max_facts', 64,
            'last_run', jsonb_build_object(
                'status', 'completed', 'frontier', 2),
            'watermark', jsonb_build_object(
                'input_relation', 'm17_reference.item_source',
                'event_time_column', 'occurred_at',
                'requested_watermark', '-infinity',
                'complete_watermark', '-infinity',
                'history_floor', '-infinity',
                'status', 'complete', 'barrier', NULL)))) THEN
        RAISE EXCEPTION 'M18 program status transcript changed: %', status_value;
    END IF;
    explanation := pgreact_api.explain('m17.reference', true);
    SELECT jsonb_set(jsonb_set(jsonb_set(
        explanation, '{evidence,definition,rules}',
        (SELECT jsonb_agg(rule_value - ARRAY['target','definition'] ||
                    jsonb_build_object('aggregate_input',
                        (rule_value -> 'aggregate_input') - ARRAY['relation','public_relation'])
                ORDER BY rule_value ->> 'name')
         FROM jsonb_array_elements(explanation #> '{evidence,definition,rules}') rule_value)),
        '{evidence,components}',
        (SELECT jsonb_agg(component_value - ARRAY['component_id','targets']
                          ORDER BY component_value -> 'order')
         FROM jsonb_array_elements(explanation #> '{evidence,components}') component_value)),
        '{evidence,graph}',
        (SELECT jsonb_agg(graph_value - ARRAY[
                    'dependency_id','source_relation','target_relation',
                    'source_component_id','target_component_id']
                ORDER BY graph_value ->> 'rule_name', graph_value -> 'input_order')
         FROM jsonb_array_elements(explanation #> '{evidence,graph}') graph_value))
    INTO normalized_explanation;
    IF normalized_explanation IS DISTINCT FROM $json$
      {"contract_version":4,
       "target":{"kind":"program","name":"m17.reference","version":1},
       "evidence":{
         "definition":{"name":"m17.reference","version":1,
           "max_facts":64,"max_iterations":8,"rules":[
             {"key":"__pgreact_key","name":"m17.count_all","inputs":[],"version":1,
              "aggregate_input":{"key":"__pgreact_key","threshold":2,"comparison":">="}},
             {"key":"__pgreact_key","name":"m17.count_amount","inputs":[],"version":1,
              "aggregate_input":{"key":"__pgreact_key","function":"COUNT","threshold":2,"comparison":">=","expression":"amount"}},
             {"key":"__pgreact_key","name":"m17.max_amount","inputs":[],"version":1,
              "aggregate_input":{"key":"__pgreact_key","function":"MAX","threshold":8,"comparison":">=","expression":"amount"}},
             {"key":"__pgreact_key","name":"m17.min_amount","inputs":[],"version":1,
              "aggregate_input":{"key":"__pgreact_key","function":"MIN","threshold":5,"comparison":"<","expression":"amount"}},
             {"key":"__pgreact_key","name":"m17.sum_amount","inputs":[],"version":1,
              "aggregate_input":{"key":"__pgreact_key","function":"SUM","threshold":10,"comparison":">=","expression":"amount"}}]},
         "components":[
           {"order":1,"rules":["m17.count_all"],"cyclic":false},
           {"order":2,"rules":["m17.sum_amount"],"cyclic":false},
           {"order":3,"rules":["m17.count_amount"],"cyclic":false},
           {"order":4,"rules":["m17.min_amount"],"cyclic":false},
           {"order":5,"rules":["m17.max_amount"],"cyclic":false}],
         "graph":[
           {"polarity":"AGGREGATE","rule_name":"m17.count_all","input_order":1,"source_stratum":0,"target_stratum":1},
           {"polarity":"AGGREGATE","rule_name":"m17.count_amount","input_order":1,"source_stratum":0,"target_stratum":1},
           {"polarity":"AGGREGATE","rule_name":"m17.max_amount","input_order":1,"source_stratum":0,"target_stratum":1},
           {"polarity":"AGGREGATE","rule_name":"m17.min_amount","input_order":1,"source_stratum":0,"target_stratum":1},
           {"polarity":"AGGREGATE","rule_name":"m17.sum_amount","input_order":1,"source_stratum":0,"target_stratum":1}]}}
      $json$::jsonb THEN
        RAISE EXCEPTION 'M18 normalized program explanation transcript changed: %',
            normalized_explanation;
    END IF;
    SELECT to_jsonb(row_value) INTO watermark
    FROM pgreact_api.watermark_status('m17.reference') row_value;
    IF watermark IS DISTINCT FROM jsonb_build_object(
        'input_relation', 'm17_reference.item_source',
        'event_time_column', 'occurred_at',
        'requested_watermark', '-infinity', 'complete_watermark', '-infinity',
        'history_floor', '-infinity', 'status', 'complete', 'barrier', NULL) THEN
        RAISE EXCEPTION 'M18 watermark status transcript changed: %', watermark;
    END IF;
    managed := pgreact_api.managed_status();
    IF (managed - 'process') || jsonb_build_object(
        'process', (managed -> 'process') - ARRAY['pid','started_at','heartbeat_at'])
       IS DISTINCT FROM jsonb_build_object(
        'contract_version', 5, 'database', current_database(), 'configured', true,
        'process', jsonb_build_object(
            'state', 'ready', 'detail', NULL, 'protocol', 2,
            'pending_jobs', 0, 'processed_jobs', 0)) THEN
        RAISE EXCEPTION 'M18 managed status transcript changed: %', managed;
    END IF;
END
$$;

-- Map engine source drift to a public name and remediation command.
CREATE SCHEMA m18_drift AUTHORIZATION m17_author;
SET SESSION AUTHORIZATION m17_author;
CREATE TABLE m18_drift.source(id bigint PRIMARY KEY, active boolean NOT NULL);
CREATE VIEW m18_drift.condition AS SELECT id FROM m18_drift.source WHERE active;
CREATE VIEW m18_drift.source_condition AS SELECT id FROM m18_drift.source WHERE active;
CREATE TABLE m18_drift.effects(id bigint PRIMARY KEY);
RESET SESSION AUTHORIZATION;
GRANT USAGE ON SCHEMA pgreact TO m17_author;
GRANT EXECUTE ON FUNCTION pgreact.create_rule(
    text, regclass, name[], text, regprocedure, regprocedure, regprocedure,
    text, name[], integer, text, name[], integer, integer, numeric, integer)
TO m17_author;
SET SESSION AUTHORIZATION m17_author;
CREATE FUNCTION m18_drift.activate(
    context pgreact.activation_context, row_value m18_drift.condition)
RETURNS void LANGUAGE SQL AS $$ INSERT INTO m18_drift.effects VALUES (row_value.id) $$;
CREATE FUNCTION m18_drift.source_activate(
    context pgreact.activation_context, row_value m18_drift.source_condition)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m18_drift.effects VALUES (row_value.id) ON CONFLICT DO NOTHING
$$;
SELECT pgreact.create_rule(
    name => 'diagnostics.action',
    definition => 'm18_drift.condition'::regclass,
    key_columns => ARRAY['id'], kind => 'COMMAND',
    on_activate => 'm18_drift.activate(pgreact.activation_context,m18_drift.condition)'::regprocedure);
RESET SESSION AUTHORIZATION;
INSERT INTO m18_drift.source VALUES (1, true);
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run('2030-01-03T00:00:00Z');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m17_author;
CREATE OR REPLACE FUNCTION m18_drift.activate(
    context pgreact.activation_context, row_value m18_drift.condition)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m18_drift.effects VALUES (row_value.id) ON CONFLICT DO NOTHING
$$;
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.doctor();
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 6, 'status', 'attention',
        'diagnostics', jsonb_build_array(jsonb_build_object(
            'code', 'CONSEQUENCE_DRIFT', 'severity', 'ERROR',
            'object_identity', 'diagnostics.action',
            'message', 'consequence or dispatcher is missing, changed, or no longer exact',
            'hint', 'Run SELECT pgreact_api.pause_rule(''diagnostics.action''); then replace the rule through pgreact_api.replace_rule.'))) THEN
        RAISE EXCEPTION 'M18 public action drift diagnosis changed: %', actual;
    END IF;
END
$$;
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.pause_rule('diagnostics.action');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m17_author;
SELECT pgreact_api.replace_rule(
    'diagnostics.action', 'm18_drift.condition', ARRAY['id']::name[],
    'm18_drift', 'activate', NULL::name, NULL::name);
RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF pgreact_api.doctor() IS DISTINCT FROM jsonb_build_object(
        'contract_version', 6, 'status', 'ready', 'diagnostics', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M18 documented action drift remediation failed: %', pgreact_api.doctor();
    END IF;
END
$$;
SET SESSION AUTHORIZATION m17_author;
SELECT pgreact.create_rule(
    name => 'diagnostics.drift',
    definition => 'm18_drift.source_condition'::regclass,
    key_columns => ARRAY['id'], kind => 'COMMAND',
    on_activate => 'm18_drift.source_activate(pgreact.activation_context,m18_drift.source_condition)'::regprocedure);
RESET SESSION AUTHORIZATION;
ALTER VIEW m18_drift.source_condition RENAME COLUMN id TO drifted_id;
DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.doctor();
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 6, 'status', 'attention',
        'diagnostics', jsonb_build_array(jsonb_build_object(
            'code', 'SOURCE_DRIFT', 'severity', 'ERROR',
            'object_identity', 'diagnostics.drift',
            'message', 'source view differs from the deployed snapshot',
            'hint', 'Run SELECT pgreact_api.pause_rule(''diagnostics.drift''); then replace the rule through pgreact_api.replace_rule.'))) THEN
        RAISE EXCEPTION 'M18 public drift diagnosis changed: %', actual;
    END IF;
END
$$;
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.pause_rule('diagnostics.drift');
RESET SESSION AUTHORIZATION;
ALTER VIEW m18_drift.source_condition RENAME COLUMN drifted_id TO id;
SET SESSION AUTHORIZATION m17_author;
SELECT pgreact_api.replace_rule(
    'diagnostics.drift', 'm18_drift.source_condition', ARRAY['id']::name[],
    'm18_drift', 'source_activate', NULL::name, NULL::name);
RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF pgreact_api.doctor() IS DISTINCT FROM jsonb_build_object(
        'contract_version', 6, 'status', 'ready', 'diagnostics', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M18 documented drift remediation failed: %', pgreact_api.doctor();
    END IF;
END
$$;
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.pause_rule('diagnostics.drift');
SELECT pgreact_api.remove_rule('diagnostics.drift');
SELECT pgreact_api.pause_rule('diagnostics.action');
SELECT pgreact_api.remove_rule('diagnostics.action');
RESET SESSION AUTHORIZATION;
DROP SCHEMA m18_drift CASCADE;

\o
SELECT 'M18 healthy doctor/status/explain/watermark transcript passed';
SELECT 'M18 public source/action drift diagnosis and remediation transcript passed';

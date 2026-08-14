\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- Run after a populated M17 fixture. State is captured only through public APIs.
CREATE TEMP TABLE m18_before AS
SELECT jsonb_build_object(
    'status', pgreact_api.status(),
    'explain', pgreact_api.explain('m17.reference', true),
    'watermark', pgreact_api.watermark_status('m17.reference')) AS state;

ALTER EXTENSION pg_react UPDATE TO '0.15.0';

DO $$
DECLARE before_state jsonb; after_state jsonb;
BEGIN
    SELECT state INTO before_state FROM m18_before;
    SELECT jsonb_build_object(
        'status', pgreact_api.status(),
        'explain', pgreact_api.explain('m17.reference', true),
        'watermark', pgreact_api.watermark_status('m17.reference')) INTO after_state;
    IF after_state IS DISTINCT FROM before_state THEN
        RAISE EXCEPTION 'M18 public state changed across 0.14.0 -> 0.15.0: before %, after %', before_state, after_state;
    END IF;
END
$$;

SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run('2030-01-03T00:00:00Z');
RESET SESSION AUTHORIZATION;
INSERT INTO m17_reference.items VALUES (18,7,1,'1970-01-01T00:30:00Z');
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run('2030-01-03T00:00:01Z');
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'version', (SELECT extversion FROM pg_extension WHERE extname = 'pg_react'),
        'evidence', (SELECT jsonb_build_object(
            'rule', rule_name, 'key', public_window_key, 'value', exact_value,
            'truth', truth_result, 'generation', support_generation)
            FROM pgreact.window_evidence
            WHERE program_name = 'm17.reference' AND rule_name = 'm17.sum_amount'
              AND public_window_key = '[7,0]'::jsonb))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'version', '0.15.0', 'evidence', jsonb_build_object(
            'rule', 'm17.sum_amount', 'key', jsonb_build_array(7,0),
            'value', '12', 'truth', true, 'generation', 1)) THEN
        RAISE EXCEPTION 'M18 post-upgrade continued result changed: %', actual;
    END IF;
END
$$;
SELECT 'M18 direct upgrade and continued execution passed';

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $$
DECLARE
    expected m15_recovery.control%ROWTYPE;
    actual jsonb;
    before_job jsonb;
    after_job jsonb;
BEGIN
    SELECT * INTO STRICT expected FROM m15_recovery.control;
    FOR attempt_number IN 1..120 LOOP
        EXIT WHEN (SELECT count(*) FROM m15_recovery.effects) = 1
              AND jsonb_path_query_first(
                    pgreact_api.jobs('m15.recovery'), '$.jobs[0].state') = '"completed"'::jsonb;
        PERFORM pg_sleep(0.1);
    END LOOP;
    SELECT jobs -> 'jobs' -> 0 INTO before_job FROM m15_recovery.control;
    SELECT pgreact_api.jobs('m15.recovery') -> 'jobs' -> 0 INTO after_job;
    SELECT jsonb_agg(to_jsonb(effect) ORDER BY public_key::text)
    INTO actual FROM m15_recovery.effects effect;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
            'public_key', jsonb_build_array(
                'north', '123e4567-e89b-12d3-a456-426614174010'),
            'deadline', (SELECT deadline FROM m15_recovery.source WHERE tenant = 'north')))
       OR after_job - ARRAY['claimed_at', 'completed_at', 'state']
          IS DISTINCT FROM before_job - ARRAY['claimed_at', 'completed_at', 'state']
       OR after_job ->> 'state' <> 'completed'
       OR after_job -> 'claimed_at' = 'null'::jsonb
       OR after_job -> 'completed_at' = 'null'::jsonb
       OR (SELECT jsonb_agg(jsonb_build_object(
                'semantic_key', semantic_key,
                'canonical_key', encode(canonical_key, 'hex'),
                'public_key', public_key) ORDER BY semantic_key)
           FROM pgreact_internal.semantic_key_identities
           WHERE rule_version_id = expected.rule_version_id)
          IS DISTINCT FROM expected.identities
       OR pgreact_api.matches('m15.recovery') #> '{matches,0,key}'
          IS DISTINCT FROM jsonb_build_array(
                'north', '123e4567-e89b-12d3-a456-426614174010')
       OR pgreact_api.deadline_history('m15.recovery') #> '{events,0,semantic_key}'
          IS DISTINCT FROM jsonb_build_array(
                'north', '123e4567-e89b-12d3-a456-426614174010')
       OR pgreact_api.explain(
            'm15.recovery', '["north","123e4567-e89b-12d3-a456-426614174010"]'::jsonb)
          #> '{target,key}' IS DISTINCT FROM jsonb_build_array(
                'north', '123e4567-e89b-12d3-a456-426614174010')
       OR pg_is_in_recovery() THEN
        RAISE EXCEPTION 'M15 promoted physical restore changed typed state: %, %', actual, after_job;
    END IF;
END
$$;

SELECT 'M15 standby promotion and physical restore passed';

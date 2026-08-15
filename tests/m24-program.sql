\set ON_ERROR_STOP on
\ir /tmp/m8-setup.sql

SELECT frontier AS base_time FROM pgreact_internal.clock_frontier \gset
SELECT pgreact_api.author_effective_program(
    'm24-program',
    (SELECT pgreact_internal.m8_program_definition(
         definition -> 'programs' -> 0, mappings)
     FROM m8_ref.manifests WHERE version = 2),
    :'base_time'::timestamptz + interval '10 minutes'
) AS policy_version_id \gset

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'target_kind', target_kind,
        'effective_state', effective_state,
        'program_version_id', program_version_id)
    INTO actual
    FROM pgreact.effective_policy_versions
    WHERE policy_name = 'm24-program';
    IF actual IS DISTINCT FROM jsonb_build_object(
        'target_kind', 'PROGRAM',
        'effective_state', 'FUTURE',
        'program_version_id', NULL) THEN
        RAISE EXCEPTION 'M24 future program was not dormant: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.run(:'base_time'::timestamptz + interval '10 minutes');

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'target_kind', version.target_kind,
        'effective_state', version.effective_state,
        'program_state', program.state,
        'program_version_id', version.program_version_id)
    INTO actual
    FROM pgreact.effective_policy_versions version
    JOIN pgreact.derivation_programs program
      ON program.program_version_id = version.program_version_id
    WHERE version.policy_name = 'm24-program';
    IF actual ->> 'target_kind' <> 'PROGRAM'
       OR actual ->> 'effective_state' <> 'CURRENT'
       OR actual ->> 'program_state' <> 'ACTIVE'
       OR actual ->> 'program_version_id' IS NULL THEN
        RAISE EXCEPTION 'M24 program boundary changed: %', actual;
    END IF;
    actual := pgreact_api.effective_policy_explain('m24-program', 7);
    IF actual ->> 'target_kind' <> 'PROGRAM'
       OR actual ->> 'program' <> 'm8.reference' THEN
        RAISE EXCEPTION 'M24 program explanation changed: %', actual;
    END IF;
END
$$;

SELECT 'M24 effective derivation-program dormancy, boundary materialization, and explanation gate passed';

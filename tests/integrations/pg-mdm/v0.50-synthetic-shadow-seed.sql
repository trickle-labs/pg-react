\set ON_ERROR_STOP on

SELECT input.reason_code AS v050_shadow_reason_code
FROM pgreact_mdm.policy_inputs('mdm_steward.policy_cases_v1'::regclass) AS input
WHERE input.entity_name = 'review_admission_live'
ORDER BY input.case_key
LIMIT 1
\gset

SELECT pgreact_mdm.publish_package(
    'v0.50-synthetic-shadow-proposed',
    jsonb_build_object(
        'deadline', jsonb_build_object(
            'duration_seconds', 86400,
            'min_seconds', 60,
            'max_seconds', 86400,
            'replace_existing_deadline', false),
        'routes', jsonb_build_array(jsonb_build_object(
            'reason_code', :'v050_shadow_reason_code',
            'entity_name', 'review_admission_live',
            'queue', 'm2-ready',
            'priority', 0,
            'action', 'ASSIGN_QUEUE')))
    )
    ->> 'policy_revision' = 'v0.50-synthetic-shadow-proposed' AS published
\gset
\if :published
\echo v0.50 synthetic shadow package: PASS
\else
\quit 1
\endif

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

\ir ../../../integrations/pg-mdm/sql/policy-inputs.sql
\ir ../../../integrations/pg-mdm/sql/routing.sql
\ir ../../../integrations/pg-mdm/sql/deadline-preview.sql
\ir ../../../integrations/pg-mdm/sql/comparison.sql
\ir ../../../integrations/pg-mdm/sql/typed-flow.sql

-- The upstream lifecycle fixture leaves one open case without an auditable opening time.
DO $$
DECLARE
    actual jsonb;
BEGIN
    actual := pgreact_mdm.validate_inputs('mdm_steward.policy_cases_v1'::regclass);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'state', 'valid',
        'findings', jsonb_build_array(jsonb_build_object(
            'code', 'MDM_INPUT_OPENING_UNKNOWN',
            'rows', 1,
            'message', 'open cases without an authorized opening time cannot receive a due-date proposal')),
        'source_relation', 'mdm_steward.policy_cases_v1') THEN
        RAISE EXCEPTION 'live MDM input validation mismatch: %', actual;
    END IF;
END
$$;

SELECT pgreact_mdm.publish_package(
    'live-policy-1',
    jsonb_build_object(
        'applicability', '{}'::jsonb,
        'deadline', jsonb_build_object(
            'duration_seconds', 3600, 'min_seconds', 60, 'max_seconds', 86400,
            'replace_existing_deadline', false),
        'routes', jsonb_build_array(jsonb_build_object(
            'reason_code', 'SINGLETON_NEEDS_INDEPENDENT_GROUP',
            'queue', 'mdm-review', 'priority', 1, 'action', 'ASSIGN_QUEUE'))))
AS published;

SELECT pgreact_mdm.publish_package(
    'live-policy-2',
    jsonb_build_object(
        'applicability', '{}'::jsonb,
        'deadline', jsonb_build_object(
            'duration_seconds', 7200, 'min_seconds', 60, 'max_seconds', 86400,
            'replace_existing_deadline', true),
        'routes', jsonb_build_array(jsonb_build_object(
            'reason_code', 'SINGLETON_NEEDS_INDEPENDENT_GROUP',
            'queue', 'mdm-urgent', 'priority', 1, 'action', 'ASSIGN_QUEUE'))))
AS published;

DO $$
DECLARE
    live_count bigint;
    live_keys bigint[];
    routes jsonb;
    deadlines jsonb;
    comparison jsonb;
    partial jsonb;
    before_source jsonb;
    after_source jsonb;
    before_packages jsonb;
    after_packages jsonb;
    captured_at timestamptz := '2026-09-22 12:00:00+00';
BEGIN
    SELECT count(*), array_agg(case_key ORDER BY case_key)
    INTO live_count, live_keys
    FROM pgreact_mdm.policy_inputs('mdm_steward.policy_cases_v1'::regclass)
    WHERE entity_name = 'review_admission_live' AND status = 'open';
    IF live_count < 1 THEN
        RAISE EXCEPTION 'live MDM qualification found no open review cases';
    END IF;

    SELECT jsonb_agg(to_jsonb(result) ORDER BY result.case_key)
    INTO routes
    FROM pgreact_mdm.route_cases('mdm_steward.policy_cases_v1'::regclass, 'live-policy-1') AS result
    WHERE result.reason_code = 'SINGLETON_NEEDS_INDEPENDENT_GROUP';
    IF jsonb_array_length(routes) <> live_count
       OR EXISTS (
           SELECT 1
           FROM jsonb_array_elements(routes) AS item(value)
           WHERE value ->> 'decision' <> 'WINNER'
              OR value ->> 'selected_queue' <> 'mdm-review'
              OR value ->> 'action' <> 'ASSIGN_QUEUE') THEN
        RAISE EXCEPTION 'live MDM routing mismatch: %', routes;
    END IF;

    SELECT jsonb_agg(to_jsonb(result) ORDER BY result.case_key)
    INTO deadlines
    FROM pgreact_mdm.deadline_preview(
        'mdm_steward.policy_cases_v1'::regclass, 'live-policy-1', captured_at) AS result
    WHERE result.review_id IN (
           SELECT review_id
           FROM pgreact_mdm.policy_inputs('mdm_steward.policy_cases_v1'::regclass)
           WHERE entity_name = 'review_admission_live');
    IF jsonb_array_length(deadlines) < live_count
       OR EXISTS (
           SELECT 1
           FROM jsonb_array_elements(deadlines) AS item(value)
           WHERE value ->> 'decision' <> 'PROPOSED'
              OR value ->> 'policy_revision' <> 'live-policy-1'
              OR (value ->> 'proposed_due_at')::timestamptz IS NULL) THEN
        RAISE EXCEPTION 'live MDM deadline mismatch: %', deadlines;
    END IF;

    SELECT jsonb_agg(to_jsonb(c) ORDER BY c.case_key)
    INTO before_source
    FROM pgreact_mdm.policy_inputs('mdm_steward.policy_cases_v1'::regclass) AS c
    WHERE c.entity_name = 'review_admission_live';
    SELECT jsonb_agg(to_jsonb(p) ORDER BY p.policy_revision)
    INTO before_packages
    FROM pgreact_mdm.policy_packages AS p;

    comparison := pgreact_mdm.compare_population(
        'mdm_steward.policy_cases_v1'::regclass,
        'live-policy-1', 'live-policy-2', captured_at,
        jsonb_build_object(
            'id', 'live-all', 'membership', to_jsonb(live_keys),
            'expected_count', live_count));
    IF comparison ->> 'state' <> 'complete'
       OR comparison -> 'coverage' ->> 'observed_count' <> live_count::text
       OR comparison -> 'coverage' ->> 'partial' <> 'false'
       OR jsonb_array_length(comparison -> 'rows') <> live_count
       OR NOT EXISTS (
           SELECT 1
           FROM jsonb_array_elements(comparison -> 'rows') AS item(value)
           WHERE (value ->> 'changed')::boolean) THEN
        RAISE EXCEPTION 'live MDM complete comparison mismatch: %', comparison;
    END IF;

    partial := pgreact_mdm.compare_population(
        'mdm_steward.policy_cases_v1'::regclass,
        'live-policy-1', 'live-policy-2', captured_at,
        jsonb_build_object(
            'id', 'live-partial',
            'membership', to_jsonb(live_keys || ARRAY[live_keys[array_length(live_keys, 1)] + 1]),
            'expected_count', live_count + 1));
    IF partial ->> 'state' <> 'partial'
       OR partial -> 'coverage' ->> 'observed_count' <> live_count::text
       OR partial -> 'coverage' ->> 'partial' <> 'true' THEN
        RAISE EXCEPTION 'live MDM partial comparison mismatch: %', partial;
    END IF;

    SELECT jsonb_agg(to_jsonb(c) ORDER BY c.case_key)
    INTO after_source
    FROM pgreact_mdm.policy_inputs('mdm_steward.policy_cases_v1'::regclass) AS c
    WHERE c.entity_name = 'review_admission_live';
    SELECT jsonb_agg(to_jsonb(p) ORDER BY p.policy_revision)
    INTO after_packages
    FROM pgreact_mdm.policy_packages AS p;
    IF before_source IS DISTINCT FROM after_source
       OR before_packages IS DISTINCT FROM after_packages THEN
        RAISE EXCEPTION 'live MDM comparison changed durable state';
    END IF;
END
$$;

DO $$
DECLARE
    member pgreact_api.declaration;
    declaration pgreact_api.declaration;
    preview jsonb;
    review text;
    package_digest text;
BEGIN
    member := pgreact_api.declaration(
        'rule', 'mdm-live-rule',
        jsonb_build_object(
            'condition', 'mdm_steward.policy_cases_v1',
            'semantic_key', 'case_key', 'kind', 'CONSTRAINT', 'salience', 10));
    SELECT encode(policy_digest, 'hex')
    INTO package_digest
    FROM pgreact_mdm.policy_packages
    WHERE policy_revision = 'live-policy-1';
    declaration := pgreact_mdm.review_declaration(
        'mdm-live', 'live-policy-1', member,
        'mdm_steward.policy_cases_v1'::regclass,
        ARRAY['case_key'::name], '2026-09-22 12:00:00+00');
    IF (declaration).spec ->> 'version' IS DISTINCT FROM package_digest THEN
        RAISE EXCEPTION 'live typed declaration lost the MDM package digest: %', declaration;
    END IF;
    preview := pgreact.preview(declaration);
    review := pgreact.review_token(preview);
    IF review IS NULL OR length(review) = 0 THEN
        RAISE EXCEPTION 'live typed declaration produced no review token';
    END IF;
END
$$;

SELECT 'v0.47 live MDM policy package passed' AS result;

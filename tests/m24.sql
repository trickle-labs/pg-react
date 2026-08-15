\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

SELECT pgreact_api.run('2026-01-01 00:00:00+00'::timestamptz);
SELECT frontier AS base_time FROM pgreact_internal.clock_frontier \gset

CREATE SCHEMA m24_reference;
CREATE TABLE m24_reference.fact (
    id bigint PRIMARY KEY,
    enabled boolean NOT NULL DEFAULT true,
    amount integer NOT NULL
);
CREATE VIEW m24_reference.v1 AS
SELECT id, amount FROM m24_reference.fact WHERE enabled;
CREATE VIEW m24_reference.v2 AS
SELECT id, amount FROM m24_reference.fact WHERE enabled AND amount >= 100;
CREATE VIEW m24_reference.v3 AS
SELECT id, amount FROM m24_reference.fact WHERE enabled AND amount >= 100;
CREATE VIEW m24_reference.v4 AS
SELECT id, amount FROM m24_reference.fact WHERE enabled AND amount >= 300;

INSERT INTO m24_reference.fact VALUES (1, true, 150);
SELECT pgreact_api.author_effective_rule(
    'm24-pricing', 'm24-pricing-v1', 'm24_reference.v1'::regclass, 'id',
    :'base_time'::timestamptz + interval '10 minutes',
    :'base_time'::timestamptz + interval '20 minutes',
    'CONSTRAINT') AS v1 \gset
SELECT pgreact_api.author_effective_rule(
    'm24-pricing', 'm24-pricing-v2', 'm24_reference.v2'::regclass, 'id',
    :'base_time'::timestamptz + interval '20 minutes',
    :'base_time'::timestamptz + interval '30 minutes',
    'CONSTRAINT') AS v2 \gset
SELECT pgreact_api.author_effective_rule(
    'm24-pricing', 'm24-pricing-v3', 'm24_reference.v3'::regclass, 'id',
    :'base_time'::timestamptz + interval '40 minutes',
    NULL,
    'CONSTRAINT') AS v3 \gset
SELECT set_config('m24.base_time', :'base_time', false);
SELECT set_config('m24.v1', :'v1', false);
SELECT set_config('m24.v2', :'v2', false);
SELECT set_config('m24.v3', :'v3', false);
SELECT rule_version_id AS v3_rule
FROM pgreact.effective_policy_versions
WHERE policy_version_id = :'v3'::uuid \gset
SELECT set_config('m24.v3_rule', :'v3_rule', false);
SELECT pgreact.create_rule(
    'm24-overlap', 'm24_reference.v4'::regclass, ARRAY['id'], 'CONSTRAINT'
) AS overlap_rule \gset
SELECT pgreact.pause_rule(:'overlap_rule'::uuid);
SELECT set_config('m24.overlap_rule', :'overlap_rule', false);

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'v1', (SELECT effective_state FROM pgreact.effective_policy_versions
               WHERE policy_version_id = current_setting('m24.v1')::uuid),
        'v2', (SELECT effective_state FROM pgreact.effective_policy_versions
               WHERE policy_version_id = current_setting('m24.v2')::uuid),
        'v3', (SELECT effective_state FROM pgreact.effective_policy_versions
               WHERE policy_version_id = current_setting('m24.v3')::uuid),
        'matches', (SELECT count(*) FROM pgreact.activations WHERE active)
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'v1', 'FUTURE', 'v2', 'FUTURE', 'v3', 'FUTURE', 'matches', 0) THEN
        RAISE EXCEPTION 'M24 future policy leaked authority: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.run(:'base_time'::timestamptz + interval '9 minutes');
DO $$
BEGIN
    IF (SELECT count(*) FROM pgreact.activations WHERE active) <> 0 THEN
        RAISE EXCEPTION 'M24 future version became active before valid_from';
    END IF;
END
$$;

SELECT pgreact_api.run(:'base_time'::timestamptz + interval '10 minutes');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'authoritative', (SELECT policy_version_id
                          FROM pgreact.effective_policy_versions
                          WHERE policy_name = 'm24-pricing' AND authoritative),
        'active_keys', (SELECT jsonb_agg(semantic_key ORDER BY semantic_key)
                        FROM pgreact.activations WHERE active)
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'authoritative', to_jsonb(current_setting('m24.v1')::uuid),
        'active_keys', jsonb_build_array(1)) THEN
        RAISE EXCEPTION 'M24 valid_from equality changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.run(:'base_time'::timestamptz + interval '20 minutes');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'authoritative', (SELECT policy_version_id
                          FROM pgreact.effective_policy_versions
                          WHERE policy_name = 'm24-pricing' AND authoritative),
        'v1_active', (SELECT count(*) FROM pgreact.activations
                      WHERE rule_version_id = (SELECT rule_version_id
                        FROM pgreact.effective_policy_versions WHERE policy_version_id = current_setting('m24.v1')::uuid)
                        AND active),
        'v2_active', (SELECT count(*) FROM pgreact.activations
                      WHERE rule_version_id = (SELECT rule_version_id
                        FROM pgreact.effective_policy_versions WHERE policy_version_id = current_setting('m24.v2')::uuid)
                        AND active)
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'authoritative', to_jsonb(current_setting('m24.v2')::uuid), 'v1_active', 0, 'v2_active', 1) THEN
        RAISE EXCEPTION 'M24 adjacent transition changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.run(:'base_time'::timestamptz + interval '30 minutes');
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pgreact.effective_policies
               WHERE policy_name = 'm24-pricing' AND authoritative_version_id IS NOT NULL)
       OR EXISTS (SELECT 1 FROM pgreact.activations WHERE active) THEN
        RAISE EXCEPTION 'M24 explicit gap retained authority';
    END IF;
END
$$;

DO $$
DECLARE overlap_code text;
BEGIN
    SELECT code INTO overlap_code
    FROM pgreact_api.validate_effective_policy(
        'm24-pricing', current_setting('m24.overlap_rule')::uuid,
        current_setting('m24.base_time')::timestamptz + interval '45 minutes',
        current_setting('m24.base_time')::timestamptz + interval '50 minutes')
    WHERE severity = 'ERROR';
    IF overlap_code = 'M24_INTERVAL_OVERLAP' THEN RETURN; END IF;
    RAISE EXCEPTION 'M24 overlap was accepted: %', overlap_code;
END
$$;

SELECT pgreact_api.run(:'base_time'::timestamptz + interval '40 minutes');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'state', (SELECT state FROM pgreact.effective_policies WHERE policy_name = 'm24-pricing'),
        'active_keys', (SELECT jsonb_agg(semantic_key ORDER BY semantic_key)
                        FROM pgreact.activations WHERE active),
        'history_kinds', (SELECT jsonb_agg(event_kind ORDER BY transition_id)
                          FROM pgreact_internal.effective_policy_history history
                          JOIN pgreact_internal.effective_policies policy USING (policy_id)
                          WHERE policy.policy_name = 'm24-pricing')
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'state', 'CURRENT', 'active_keys', jsonb_build_array(1),
        'history_kinds', jsonb_build_array(
            'DEPLOYED', 'DEPLOYED', 'DEPLOYED', 'EFFECTIVE', 'EXPIRED',
            'EFFECTIVE', 'EXPIRED', 'GAP', 'EFFECTIVE')) THEN
        RAISE EXCEPTION 'M24 gap successor changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE status jsonb; preview jsonb; history jsonb; explanation jsonb; doctor jsonb;
BEGIN
    status := pgreact_api.effective_policy_status('m24-pricing');
    preview := pgreact_api.effective_policy_preview('m24-pricing');
    history := pgreact_api.effective_policy_history('m24-pricing');
    explanation := pgreact_api.effective_policy_explain('m24-pricing', 1);
    doctor := pgreact_api.effective_policy_doctor();
    IF status ->> 'clock_domain' <> 'DATABASE_TIME'
       OR preview ->> 'contract_version' <> '12'
       OR jsonb_array_length(history) <> 9
       OR explanation ->> 'policy' <> 'm24-pricing'
       OR doctor ->> 'status' <> 'ready' THEN
        RAISE EXCEPTION 'M24 public evidence changed: % / % / % / % / %',
            status, preview, history, explanation, doctor;
    END IF;
END
$$;

SELECT 'M24 effective intervals, dormant deployment, equality, adjacency, gap, overlap, evidence, and recovery gate passed';

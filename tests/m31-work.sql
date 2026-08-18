\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m31_work_reference;
CREATE TABLE m31_work_reference.facts (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL
);
INSERT INTO m31_work_reference.facts VALUES (42, 7);
CREATE VIEW m31_work_reference.facts_match AS
SELECT order_id, customer_id FROM m31_work_reference.facts;
CREATE TABLE m31_work_reference.customer_gate (customer_id bigint PRIMARY KEY);
INSERT INTO m31_work_reference.customer_gate VALUES (7);
CREATE TABLE m31_work_reference.effects (order_id bigint PRIMARY KEY, calls integer NOT NULL);

CREATE FUNCTION m31_work_reference.activate(
    context pgreact.activation_context, match m31_work_reference.facts_match)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m31_work_reference.effects(order_id, calls)
    VALUES ((match).order_id, 1)
    ON CONFLICT (order_id) DO UPDATE SET calls = effects.calls + 1
$$;

DO $m31work$
DECLARE member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    preview jsonb;
    rule_version uuid;
    claimed_batch_id uuid;
    claimed_count bigint;
    skipped_count bigint;
    batch_state text;
    batch_claim record;
    claimed_episode_id bigint;
    lease_token uuid;
    result text;
    agenda_state text;
    effect_count bigint;
BEGIN
    member := pgreact_api.declaration('rule', 'm31-work-rule', jsonb_build_object(
        'condition', 'm31_work_reference.facts_match', 'semantic_key', 'order_id',
        'kind', 'COMMAND', 'delegate', true,
        'on_activate', 'm31_work_reference.activate(pgreact.activation_context,m31_work_reference.facts_match)'));
    preview := pgreact_api.preview(member);
    PERFORM pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    SELECT delegated_id INTO rule_version
    FROM pgreact_internal.api_declarations
    WHERE kind = 'rule' AND object_name = 'm31-work-rule' AND state = 'DEPLOYED';
    PERFORM pgreact.declare_batch_safe(rule_version, 'ACTIVATE');
    PERFORM pgreact_api.run_rule('m31-work-rule');
    INSERT INTO m31_work_reference.facts VALUES (43, 7), (44, 7);
    PERFORM pgreact_api.run_rule('m31-work-rule');

    policy_set := pgreact_api.declaration('policy_set', 'm31-work-set', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-work-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_work_reference.customer_gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', '2026-01-01 00:00:00+00'));
    preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-work-set', '1'),
        '2026-01-01 00:00:00+00');

    claimed_count := 0;
    FOR batch_claim IN SELECT * FROM pgreact.claim_batch(
        rule_version, 'ACTIVATE', 'm31-batch-test', 2, interval '60 seconds') LOOP
        claimed_count := claimed_count + 1;
        claimed_batch_id := batch_claim.batch_id;
    END LOOP;
    IF claimed_count <> 2 OR claimed_batch_id IS NULL THEN
        RAISE EXCEPTION 'M31 batch fixture did not claim two episodes: % / % / agenda=% / declarations=% / binding=%',
            claimed_count, claimed_batch_id,
            (SELECT COALESCE(string_agg(event_kind || ':' || state, ','), '<none>')
             FROM pgreact_internal.agenda WHERE rule_version_id = rule_version),
            (SELECT count(*) FROM pgreact_internal.batch_declarations
             WHERE rule_version_id = rule_version),
            (SELECT consequence_kind FROM pgreact_internal.consequence_bindings
             WHERE rule_version_id = rule_version AND event_kind = 'ACTIVATE');
    END IF;

    DELETE FROM m31_work_reference.customer_gate;
    UPDATE pgreact_internal.policy_set_versions
    SET valid_from = clock_timestamp() + interval '1 hour'
    WHERE policy_set_id = (
        SELECT policy_set_id
        FROM pgreact_internal.policy_sets
        WHERE set_name = 'm31-work-set');
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-work-set', '1'),
        '2026-02-01 00:00:00+00');
    SELECT count(*) INTO skipped_count
    FROM pgreact.execute_claimed_batch(claimed_batch_id, 'm31-batch-test') result
    WHERE result.status = 'SKIPPED'
      AND result.error_code = 'M31_SCOPE_WITHDRAWN';
    SELECT batch.state INTO batch_state
    FROM pgreact_internal.execution_batches batch
    WHERE batch.batch_id = claimed_batch_id;
    SELECT count(*) INTO effect_count FROM m31_work_reference.effects;
    IF skipped_count <> 2 OR batch_state <> 'REJECTED' OR effect_count <> 0 THEN
        RAISE EXCEPTION 'M31 stale batch was executable: % / % / %',
            skipped_count, batch_state, effect_count;
    END IF;

    UPDATE pgreact_internal.policy_set_versions
    SET valid_from = '2026-01-01 00:00:00+00'
    WHERE policy_set_id = (
        SELECT policy_set_id
        FROM pgreact_internal.policy_sets
        WHERE set_name = 'm31-work-set');
    INSERT INTO m31_work_reference.customer_gate VALUES (7);
    INSERT INTO m31_work_reference.facts VALUES (45, 7);
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-work-set', '1'),
        '2026-03-01 00:00:00+00');

    SELECT claimed.episode_id, claimed.lease_token
    INTO claimed_episode_id, lease_token
    FROM pgreact.claim_episode(rule_version, 'm31-work-test', 60) claimed;
    IF claimed_episode_id IS NULL OR lease_token IS NULL THEN
        RAISE EXCEPTION 'M31 work fixture did not claim an episode: %, %, %, %',
            rule_version,
            (SELECT count(*) FROM pgreact_internal.agenda
             WHERE rule_version_id = rule_version),
            (SELECT count(*) FROM pgreact_internal.policy_set_scope_supports
             WHERE member_name = 'm31-work-rule'),
            (SELECT state FROM pgreact_internal.api_declarations
             WHERE delegated_id = rule_version);
    END IF;

    UPDATE pgreact_internal.policy_set_versions
    SET valid_to = clock_timestamp() - interval '1 second'
    WHERE policy_set_id = (
        SELECT policy_set_id
        FROM pgreact_internal.policy_sets
        WHERE set_name = 'm31-work-set');
    result := pgreact.execute_claimed_episode(
        claimed_episode_id, 'm31-work-test', lease_token);
    SELECT agenda.state INTO agenda_state
    FROM pgreact_internal.agenda agenda
    WHERE agenda.episode_id = claimed_episode_id;
    SELECT count(*) INTO effect_count FROM m31_work_reference.effects;
    IF result <> 'SKIPPED' OR agenda_state <> 'WITHDRAWN' OR effect_count <> 0 THEN
        RAISE EXCEPTION 'M31 stale work was executable: %, %, %',
            result, agenda_state, effect_count;
    END IF;
END
$m31work$;

SELECT 'M31_CLAIM_REVALIDATION_OK' AS result;

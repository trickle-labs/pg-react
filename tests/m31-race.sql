\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET statement_timeout = '30s';

\if :{?phase}
\else
  \echo 'phase is required'
  \quit 2
\endif

SELECT :'phase' = 'setup' AS is_setup,
       :'phase' = 'withdraw-worker' AS is_withdraw_worker,
       :'phase' = 'withdraw-mutator' AS is_withdraw_mutator,
       :'phase' = 'lease-worker' AS is_lease_worker,
       :'phase' = 'lease-mutator' AS is_lease_mutator,
       :'phase' = 'verify' AS is_verify
\gset

\if :is_setup
CREATE SCHEMA m31_race_reference;
CREATE TABLE m31_race_reference.facts (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL
);
CREATE VIEW m31_race_reference.facts_match AS
SELECT order_id, customer_id FROM m31_race_reference.facts;
CREATE TABLE m31_race_reference.customer_gate (customer_id bigint PRIMARY KEY);
CREATE TABLE m31_race_reference.effects (
    order_id bigint PRIMARY KEY,
    calls integer NOT NULL
);
CREATE TABLE m31_race_reference.claims (
    scenario text PRIMARY KEY,
    rule_version_id uuid NOT NULL,
    episode_id bigint NOT NULL,
    lease_token uuid NOT NULL
);
CREATE TABLE m31_race_reference.results (
    scenario text PRIMARY KEY,
    result text NOT NULL,
    error_code text,
    error_message text
);
CREATE TABLE m31_race_reference.mutations (
    scenario text PRIMARY KEY,
    swept bigint,
    run_result jsonb
);

CREATE FUNCTION m31_race_reference.activate(
    context pgreact.activation_context,
    match m31_race_reference.facts_match)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m31_race_reference.effects(order_id, calls)
    VALUES ((match).order_id, 1)
    ON CONFLICT (order_id) DO UPDATE SET calls = effects.calls + 1
$$;

INSERT INTO m31_race_reference.customer_gate VALUES (7);

DO $m31race$
DECLARE member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    preview jsonb;
    version_id uuid;
    actual jsonb;
BEGIN
    member := pgreact_api.declaration('rule', 'm31-race-rule', jsonb_build_object(
        'condition', 'm31_race_reference.facts_match',
        'semantic_key', 'order_id',
        'kind', 'COMMAND',
        'delegate', true,
        'on_activate', 'm31_race_reference.activate(pgreact.activation_context,m31_race_reference.facts_match)'));
    preview := pgreact_api.preview(member);
    PERFORM pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    SELECT delegated_id INTO STRICT version_id
    FROM pgreact_internal.api_declarations
    WHERE kind = 'rule' AND object_name = 'm31-race-rule' AND state = 'DEPLOYED';
    PERFORM pgreact.declare_batch_safe(version_id, 'ACTIVATE');
    PERFORM pgreact_api.run_rule('m31-race-rule');
    INSERT INTO m31_race_reference.facts VALUES (1, 7);

    policy_set := pgreact_api.declaration('policy_set', 'm31-race-set', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-race-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation',
            'relation', 'm31_race_reference.customer_gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', '2026-01-01 00:00:00+00'));
    preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-race-set', '1'),
        '2026-01-01 00:00:00+00');

    SELECT jsonb_build_object(
        'pending_episodes', (SELECT count(*) FROM pgreact_internal.agenda
            WHERE rule_version_id = version_id AND state = 'PENDING'),
        'active_matches', (SELECT count(*) FROM pgreact_internal.activation_state
            WHERE rule_version_id = version_id AND active),
        'supports', (SELECT count(*) FROM pgreact_internal.policy_set_scope_supports
            WHERE member_name = 'm31-race-rule'),
        'effects', (SELECT count(*) FROM m31_race_reference.effects))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'pending_episodes', 1,
        'active_matches', 1,
        'supports', 1,
        'effects', 0) THEN
        RAISE EXCEPTION 'M31 race setup mismatch: %', actual;
    END IF;
END
$m31race$;

SELECT 'M31_RACE_SETUP_OK' AS marker;
\elif :is_withdraw_worker
DO $m31race$
DECLARE version_id uuid;
    claim record;
BEGIN
    SELECT delegated_id INTO STRICT version_id
    FROM pgreact_internal.api_declarations
    WHERE kind = 'rule' AND object_name = 'm31-race-rule' AND state = 'DEPLOYED';
    SELECT * INTO claim
    FROM pgreact.claim_episode(version_id, 'm31-race-withdraw-worker', 60);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'M31 race withdrawal worker could not claim an episode';
    END IF;
    INSERT INTO m31_race_reference.claims(
        scenario, rule_version_id, episode_id, lease_token)
    VALUES ('withdraw', version_id, claim.episode_id, claim.lease_token);
END
$m31race$;

SELECT 'M31_RACE_WITHDRAW_CLAIMED' AS marker;
SELECT pg_sleep(2);

DO $m31race$
DECLARE claim record;
    execution_result text;
BEGIN
    SELECT * INTO STRICT claim
    FROM m31_race_reference.claims
    WHERE scenario = 'withdraw';
    BEGIN
        SELECT pgreact.execute_claimed_episode(
            claim.episode_id, 'm31-race-withdraw-worker', claim.lease_token)
        INTO execution_result;
        INSERT INTO m31_race_reference.results(scenario, result)
        VALUES ('withdraw', execution_result);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO m31_race_reference.results(
            scenario, result, error_code, error_message)
        VALUES ('withdraw', 'ERROR', SQLSTATE, SQLERRM);
    END;
END
$m31race$;

SELECT 'M31_RACE_WITHDRAW_EXECUTED' AS marker;
\elif :is_withdraw_mutator
DO $m31race$
DECLARE runtime jsonb;
BEGIN
    DELETE FROM m31_race_reference.customer_gate;
    SELECT pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-race-set', '1'),
        '2026-02-01 00:00:00+00') INTO runtime;
    INSERT INTO m31_race_reference.mutations(scenario, run_result)
    VALUES ('withdraw', runtime);
END
$m31race$;

SELECT 'M31_RACE_WITHDRAW_MUTATED' AS marker;
\elif :is_lease_worker
DO $m31race$
DECLARE version_id uuid;
    claim record;
BEGIN
    SELECT delegated_id INTO STRICT version_id
    FROM pgreact_internal.api_declarations
    WHERE kind = 'rule' AND object_name = 'm31-race-rule' AND state = 'DEPLOYED';
    INSERT INTO m31_race_reference.customer_gate VALUES (7)
    ON CONFLICT (customer_id) DO NOTHING;
    INSERT INTO m31_race_reference.facts VALUES (2, 7);
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-race-set', '1'),
        '2026-03-01 00:00:00+00');
    SELECT * INTO claim
    FROM pgreact.claim_episode(version_id, 'm31-race-lease-worker', 1);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'M31 race lease worker could not claim an episode';
    END IF;
    INSERT INTO m31_race_reference.claims(
        scenario, rule_version_id, episode_id, lease_token)
    VALUES ('lease', version_id, claim.episode_id, claim.lease_token);
END
$m31race$;

SELECT 'M31_RACE_LEASE_CLAIMED' AS marker;
SELECT pg_sleep(3);

DO $m31race$
DECLARE claim record;
    execution_result text;
BEGIN
    SELECT * INTO STRICT claim
    FROM m31_race_reference.claims
    WHERE scenario = 'lease';
    BEGIN
        SELECT pgreact.execute_claimed_episode(
            claim.episode_id, 'm31-race-lease-worker', claim.lease_token)
        INTO execution_result;
        INSERT INTO m31_race_reference.results(scenario, result)
        VALUES ('lease', execution_result);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO m31_race_reference.results(
            scenario, result, error_code, error_message)
        VALUES ('lease', 'ERROR', SQLSTATE, SQLERRM);
    END;
END
$m31race$;

SELECT 'M31_RACE_LEASE_EXECUTED' AS marker;
\elif :is_lease_mutator
SELECT pg_sleep(1.5);

INSERT INTO m31_race_reference.mutations(scenario, swept)
SELECT 'lease', pgreact.sweep_expired_leases(claim.rule_version_id)
FROM m31_race_reference.claims claim
WHERE claim.scenario = 'lease';
SELECT 'M31_RACE_LEASE_EXPIRED' AS marker;

DO $m31race$
DECLARE attempts integer := 0;
BEGIN
    LOOP
        EXIT WHEN EXISTS (
            SELECT 1 FROM m31_race_reference.results
            WHERE scenario = 'lease');
        attempts := attempts + 1;
        IF attempts >= 50 THEN
            RAISE EXCEPTION 'M31 race lease worker did not revalidate within bound';
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END
$m31race$;

DO $m31race$
DECLARE runtime jsonb;
BEGIN
    DELETE FROM m31_race_reference.customer_gate;
    SELECT pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-race-set', '1'),
        '2026-04-01 00:00:00+00:00') INTO runtime;
    UPDATE m31_race_reference.mutations
    SET run_result = runtime
    WHERE scenario = 'lease';
END
$m31race$;

SELECT 'M31_RACE_LEASE_WITHDRAWN' AS marker;
\elif :is_verify
DO $m31race$
DECLARE version_id uuid;
    withdrawal_episode bigint;
    lease_episode bigint;
    fresh_claims bigint;
    actual jsonb;
BEGIN
    SELECT delegated_id INTO STRICT version_id
    FROM pgreact_internal.api_declarations
    WHERE kind = 'rule' AND object_name = 'm31-race-rule' AND state = 'DEPLOYED';
    SELECT episode_id INTO STRICT withdrawal_episode
    FROM m31_race_reference.claims WHERE scenario = 'withdraw';
    SELECT episode_id INTO STRICT lease_episode
    FROM m31_race_reference.claims WHERE scenario = 'lease';
    SELECT count(*) INTO fresh_claims
    FROM pgreact.claim_episode(version_id, 'm31-race-probe', 1);
    actual := jsonb_build_object(
        'withdrawal', jsonb_build_object(
            'result', (SELECT result FROM m31_race_reference.results
                WHERE scenario = 'withdraw'),
            'agenda_state', (SELECT state FROM pgreact_internal.agenda
                WHERE episode_id = withdrawal_episode),
            'lease_cleared', (SELECT lease_token IS NULL FROM pgreact_internal.agenda
                WHERE episode_id = withdrawal_episode),
            'worker_cleared', (SELECT worker_id IS NULL FROM pgreact_internal.agenda
                WHERE episode_id = withdrawal_episode),
            'support_count', (SELECT count(*) FROM pgreact_internal.policy_set_scope_supports
                WHERE activation_id = (SELECT activation_id FROM pgreact_internal.agenda
                    WHERE episode_id = withdrawal_episode)),
            'execution_count', (SELECT count(*) FROM pgreact_internal.executions
                WHERE episode_id = withdrawal_episode)),
        'lease', jsonb_build_object(
            'result', (SELECT result FROM m31_race_reference.results
                WHERE scenario = 'lease'),
            'error_code', (SELECT error_code FROM m31_race_reference.results
                WHERE scenario = 'lease'),
            'agenda_state', (SELECT state FROM pgreact_internal.agenda
                WHERE episode_id = lease_episode),
            'lease_cleared', (SELECT lease_token IS NULL FROM pgreact_internal.agenda
                WHERE episode_id = lease_episode),
            'support_count', (SELECT count(*) FROM pgreact_internal.policy_set_scope_supports
                WHERE activation_id = (SELECT activation_id FROM pgreact_internal.agenda
                    WHERE episode_id = lease_episode)),
            'execution_count', (SELECT count(*) FROM pgreact_internal.executions
                WHERE episode_id = lease_episode),
            'sweep_count', (SELECT swept FROM m31_race_reference.mutations
                WHERE scenario = 'lease'),
            'fresh_claims_after_withdrawal', fresh_claims),
        'effects', COALESCE((SELECT jsonb_agg(
            jsonb_build_object('order_id', order_id, 'calls', calls)
            ORDER BY order_id) FROM m31_race_reference.effects), '[]'::jsonb));
    IF actual IS DISTINCT FROM jsonb_build_object(
        'withdrawal', jsonb_build_object(
            'result', 'SKIPPED', 'agenda_state', 'WITHDRAWN',
            'lease_cleared', true, 'worker_cleared', true,
            'support_count', 0, 'execution_count', 0),
        'lease', jsonb_build_object(
            'result', 'ERROR', 'error_code', 'P0001',
            'agenda_state', 'WITHDRAWN', 'lease_cleared', true,
            'support_count', 0, 'execution_count', 0,
            'sweep_count', 1, 'fresh_claims_after_withdrawal', 0),
        'effects', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M31 race stale work was executable or left effects: %', actual;
    END IF;
    RAISE NOTICE 'M31 race exact result: %', actual;
END
$m31race$;

SELECT 'M31_RACE_QUALIFICATION_OK' AS marker;
\else
  \echo 'unknown phase'
  \quit 2
\endif

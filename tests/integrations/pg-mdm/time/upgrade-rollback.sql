\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SELECT to_regclass('mdm_steward.policy_cases_v1') IS NOT NULL AS mdm_present
\gset
\if :mdm_present
\ir ../../../../integrations/pg-mdm/sql/policy-inputs.sql
\ir ../../../../integrations/pg-mdm/sql/routing.sql
\ir ../../../../integrations/pg-mdm/sql/deadline-preview.sql
\ir ../../../../integrations/pg-mdm/sql/comparison.sql
\ir ../../../../integrations/pg-mdm/sql/typed-flow.sql
\ir ../../../../integrations/pg-mdm/sql/request-store.sql
\ir ../../../../integrations/pg-mdm/sql/intent-worker.sql
SELECT pgreact_mdm.publish_intent_package('upgrade-rollback',
    '{"routes":[{"entity_name":"policy_qualification","reason_code":"ESTABLISHED_NEEDS_TWO_STRONG_CONNECTIONS","action":"ESCALATE","level":2,"priority":0}]}'::jsonb);
\endif
CREATE SCHEMA upgrade_rollback;
CREATE TABLE upgrade_rollback.candidates(
    subject_id bigint NOT NULL, candidate_id bigint PRIMARY KEY, priority bigint NOT NULL, result text NOT NULL);
INSERT INTO upgrade_rollback.candidates VALUES (1,1001,1,'ready'),(1,1002,2,'fallback');
DO $populate$
DECLARE declaration pgreact_api.declaration; preview jsonb; deployed jsonb; actual jsonb;
BEGIN
    declaration := pgreact.decision('upgrade-rollback', 'upgrade_rollback.candidates',
        'subject_id','candidate_id','priority',ARRAY['result']::name[],statement_timestamp());
    preview := pgreact.preview(declaration);
    deployed := pgreact.deploy(declaration, jsonb_build_object(
        'preview_digest',preview->'summary'->>'preview_digest'));
    IF deployed->>'state' IS DISTINCT FROM 'deployed' THEN
        RAISE EXCEPTION 'upgrade fixture did not deploy: %',deployed;
    END IF;
    PERFORM pgreact.run(statement_timestamp() + interval '1 second');
    SELECT jsonb_agg(jsonb_build_object(
        'subject_key',subject_key,'state',state,'winner_candidate',winner_candidate,
        'winner_priority',winner_priority,'winner_result',winner_result,'claimable',claimable,
        'generation',generation,'revision',revision,'competitors',competitors) ORDER BY subject_key)
    INTO actual FROM pgreact.decision_winners WHERE program_name='upgrade-rollback';
    IF actual IS DISTINCT FROM '[{"subject_key":1,"state":"WINNER","winner_candidate":1001,"winner_priority":1,"winner_result":{"result":"ready"},"claimable":true,"generation":1,"revision":0,"competitors":[{"candidate":1001,"priority":1,"result":{"result":"ready"}},{"candidate":1002,"priority":2,"result":{"result":"fallback"}}]}]'::jsonb THEN
        RAISE EXCEPTION 'upgrade fixture has unexpected complete decision vector: %',actual;
    END IF;
END
$populate$;

CREATE SCHEMA upgrade_rollback_temporal;
CREATE TABLE upgrade_rollback_temporal.cases(
    case_key bigint PRIMARY KEY, is_active boolean NOT NULL);
INSERT INTO upgrade_rollback_temporal.cases VALUES (1, true);
CREATE VIEW upgrade_rollback_temporal.condition AS
SELECT case_key FROM upgrade_rollback_temporal.cases WHERE is_active;
CREATE VIEW upgrade_rollback_temporal.recovery AS
SELECT case_key FROM upgrade_rollback_temporal.cases WHERE NOT is_active;
DO $temporal_fixture$
DECLARE
    rule_id uuid := gen_random_uuid();
    version_id uuid := gen_random_uuid();
    source_oid oid := 'upgrade_rollback_temporal.condition'::regclass;
    recovery_oid oid := 'upgrade_rollback_temporal.recovery'::regclass;
    source_definition text := pg_catalog.pg_get_viewdef(source_oid, true);
BEGIN
    INSERT INTO pgreact_internal.rules (rule_id, rule_name, owner_oid)
    VALUES (rule_id, 'upgrade-recovery-metadata', 'postgres'::regrole);
    INSERT INTO pgreact_internal.rule_versions (
        rule_version_id, rule_id, owner_oid, source_view_oid, source_view_name,
        source_definition, source_definition_digest, source_row_signature, key_column,
        match_name, bootstrap_policy, refresh_mode, isolation_level, state
    ) VALUES (
        version_id, rule_id, 'postgres'::regrole, source_oid,
        'upgrade_rollback_temporal.condition', source_definition,
        sha256(convert_to(source_definition, 'UTF8')),
        pgreact_internal.source_row_signature(source_oid), 'case_key',
        'pgreact_runtime.upgrade_recovery_metadata', 'SEED_CURRENT',
        'DIFFERENTIAL', 'read committed', 'REMOVED'
    );
    INSERT INTO pgreact_internal.temporal_rules (
        rule_version_id, primitive, recovery_condition_oid, recovery_key_column
    ) VALUES (version_id, 'HYSTERESIS', recovery_oid, 'case_key');
END
$temporal_fixture$;

CREATE FUNCTION upgrade_rollback.state(normalize_upgrade_metadata boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql AS $state$
DECLARE result jsonb := '{}'::jsonb; relation record; rows jsonb;
BEGIN
    FOR relation IN
        SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname IN ('pgreact_internal','pgreact_mdm') AND c.relkind='r'
          AND (NOT normalize_upgrade_metadata OR c.relname <> 'operational_settings_snapshot')
        ORDER BY n.nspname,c.relname
    LOOP
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg(value ORDER BY value::text),''[]'') FROM '
            '(SELECT CASE WHEN $1 THEN to_jsonb(t) - '
            'ARRAY[''owner_name'',''recovery_condition_name'',''recovery_condition_definition'','
            '''recovery_condition_signature'']::text[] ELSE to_jsonb(t) END AS value FROM %I.%I t) normalized',
            relation.nspname,relation.relname)
        INTO rows USING normalize_upgrade_metadata;
        result := result || jsonb_build_object(relation.nspname||'.'||relation.relname,rows);
    END LOOP;
    IF to_regclass('mdm_steward.policy_cases_v1') IS NOT NULL THEN
        result := result || jsonb_build_object(
            'mdm_cases',(SELECT jsonb_agg(to_jsonb(c) ORDER BY case_key) FROM mdm_steward.policy_cases_v1 c),
            'mdm_receipts',(SELECT jsonb_agg(to_jsonb(r) ORDER BY receipt_id) FROM mdm_steward.policy_receipts_v1 r));
    END IF;
    RETURN result;
END
$state$;
CREATE FUNCTION upgrade_rollback.api() RETURNS jsonb LANGUAGE SQL AS $api$
    SELECT jsonb_agg(jsonb_build_object(
        'identity',p.oid::regprocedure::text,'owner',pg_get_userbyid(p.proowner),
        'acl',p.proacl::text,'definition',pg_get_functiondef(p.oid)) ORDER BY p.oid::regprocedure::text)
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname IN ('pgreact','pgreact_api','pgreact_internal','pgreact_mdm') AND p.prokind='f'
$api$;
CREATE TABLE upgrade_rollback.before_upgrade AS
SELECT upgrade_rollback.state() AS state,
       upgrade_rollback.state(true) AS compatible_state,
       upgrade_rollback.api() AS api;
CREATE FUNCTION upgrade_rollback.reject_upgrade() RETURNS event_trigger LANGUAGE plpgsql AS $reject$
BEGIN
    RAISE EXCEPTION 'injected adjacent upgrade failure';
END
$reject$;
CREATE EVENT TRIGGER qualification_upgrade_failure ON ddl_command_end
    WHEN TAG IN ('ALTER EXTENSION') EXECUTE FUNCTION upgrade_rollback.reject_upgrade();
CREATE TABLE upgrade_rollback.evidence(result jsonb NOT NULL);
DO $rollback$
DECLARE failure_state text; failure_message text; actual jsonb;
BEGIN
    BEGIN
        ALTER EXTENSION pg_react UPDATE TO '0.46.1';
        RAISE EXCEPTION 'injected upgrade failure did not fire';
    EXCEPTION WHEN raise_exception THEN
        GET STACKED DIAGNOSTICS failure_state = RETURNED_SQLSTATE, failure_message = MESSAGE_TEXT;
        IF failure_state <> 'P0001' OR failure_message <> 'injected adjacent upgrade failure' THEN RAISE; END IF;
    END;
    actual := jsonb_build_object('version',(SELECT extversion FROM pg_extension WHERE extname='pg_react'),
        'state',upgrade_rollback.state(),'api',upgrade_rollback.api());
    IF actual IS DISTINCT FROM (SELECT jsonb_build_object('version','0.46.0','state',state,'api',api)
                               FROM upgrade_rollback.before_upgrade) THEN
        RAISE EXCEPTION 'failed upgrade changed predecessor version, durable state or callable definitions/privileges: %',actual;
    END IF;
    INSERT INTO upgrade_rollback.evidence VALUES (jsonb_build_object(
        'sqlstate',failure_state,'message',failure_message,'restored',actual));
END
$rollback$;
DROP EVENT TRIGGER qualification_upgrade_failure;
DROP FUNCTION upgrade_rollback.reject_upgrade();
ALTER EXTENSION pg_react UPDATE TO '0.46.1';
DO $preserved$
DECLARE recovery_actual record;
BEGIN
    IF upgrade_rollback.state(true) IS DISTINCT FROM
       (SELECT compatible_state FROM upgrade_rollback.before_upgrade)
       OR (SELECT extversion FROM pg_extension WHERE extname='pg_react') <> '0.46.1' THEN
        RAISE EXCEPTION 'successful adjacent upgrade changed populated durable state';
    END IF;
    IF (SELECT settings FROM pgreact_internal.operational_settings_snapshot WHERE singleton)
       IS DISTINCT FROM (SELECT to_jsonb(settings) FROM pgreact_internal.operational_settings settings
                         WHERE singleton) THEN
        RAISE EXCEPTION 'adjacent upgrade did not snapshot operational settings exactly';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.rules rule
        WHERE rule.owner_name IS DISTINCT FROM pg_get_userbyid(rule.owner_oid)
    ) OR EXISTS (
        SELECT 1 FROM pgreact_internal.rule_versions version
        JOIN pgreact_internal.rules rule USING (rule_id)
        WHERE pg_get_userbyid(version.owner_oid) IS DISTINCT FROM rule.owner_name
    ) THEN
        RAISE EXCEPTION 'adjacent upgrade did not backfill owner identity exactly';
    END IF;
    SELECT temporal.recovery_condition_name, temporal.recovery_condition_definition,
           temporal.recovery_condition_signature
    INTO STRICT recovery_actual
    FROM pgreact_internal.temporal_rules temporal
    JOIN pgreact_internal.rule_versions version USING (rule_version_id)
    JOIN pgreact_internal.rules rule USING (rule_id)
    WHERE rule.rule_name = 'upgrade-recovery-metadata';
    IF recovery_actual.recovery_condition_name IS DISTINCT FROM
           'upgrade_rollback_temporal.recovery'
       OR recovery_actual.recovery_condition_definition IS DISTINCT FROM
           pg_catalog.pg_get_viewdef('upgrade_rollback_temporal.recovery'::regclass, true)
       OR recovery_actual.recovery_condition_signature IS DISTINCT FROM
           pgreact_internal.source_row_signature('upgrade_rollback_temporal.recovery'::regclass) THEN
        RAISE EXCEPTION 'adjacent upgrade did not backfill temporal recovery identity exactly: %',
            recovery_actual;
    END IF;
END
$preserved$;
CREATE SCHEMA upgrade_rollback_state_only;
CREATE TABLE upgrade_rollback_state_only.cases(
    case_key bigint PRIMARY KEY, is_active boolean NOT NULL);
INSERT INTO upgrade_rollback_state_only.cases VALUES (1, true);
CREATE VIEW upgrade_rollback_state_only.condition AS
SELECT case_key FROM upgrade_rollback_state_only.cases WHERE is_active;
SELECT pgreact_api.author_temporal_rule(
    'upgrade-state-only-temporal', 'upgrade_rollback_state_only.condition'::regclass,
    'case_key', 'DURATION', interval '1 hour') AS rule_version_id
\gset temporal_
CREATE TEMP TABLE upgrade_temporal_state_before AS
SELECT state, active, input_true, recovery_true, continuous_since, pending_deadline,
       cooldown_until, generation, last_bindings
FROM pgreact_internal.temporal_state
WHERE rule_version_id = :'temporal_rule_version_id'::uuid AND semantic_key = 1;
DO $state_only_baseline$
DECLARE actual record;
BEGIN
    SELECT * INTO STRICT actual FROM upgrade_temporal_state_before;
    IF actual.state IS DISTINCT FROM 'PENDING'
       OR actual.active IS DISTINCT FROM false
       OR actual.input_true IS DISTINCT FROM true
       OR actual.recovery_true IS DISTINCT FROM false
       OR actual.continuous_since IS NULL
       OR actual.pending_deadline IS DISTINCT FROM actual.continuous_since + interval '1 hour'
       OR actual.generation IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'upgrade temporal fixture did not start with the expected pending duration state: %',
            row_to_json(actual);
    END IF;
END
$state_only_baseline$;
SELECT pgreact.begin_reconciliation(:'temporal_rule_version_id'::uuid);
DO $state_only_reconciliation$
DECLARE repaired bigint; actual record; prior record; version_id uuid; observed_frontier timestamptz;
    state_details jsonb;
BEGIN
    SELECT version.rule_version_id INTO STRICT version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = 'upgrade-state-only-temporal';
    SELECT * INTO STRICT prior FROM upgrade_temporal_state_before;
    SELECT frontier INTO STRICT observed_frontier FROM pgreact_internal.clock_frontier;
    IF observed_frontier >= prior.pending_deadline THEN
        RAISE EXCEPTION 'state-only temporal fixture is already due: frontier %, pending deadline %',
            observed_frontier, prior.pending_deadline;
    END IF;
    repaired := pgreact.reconcile_rule(version_id, 'STATE_ONLY');
    SELECT * INTO STRICT actual
    FROM pgreact_internal.temporal_state
    WHERE rule_version_id = version_id AND semantic_key = 1;
    SELECT jsonb_build_object(
        'source_keys',(SELECT COALESCE(jsonb_agg(case_key ORDER BY case_key),'[]')
                       FROM upgrade_rollback_state_only.cases WHERE is_active),
        'states',(SELECT COALESCE(jsonb_agg(to_jsonb(state) ORDER BY semantic_key),'[]')
                  FROM pgreact_internal.temporal_state state WHERE rule_version_id = version_id),
        'history',(SELECT COALESCE(jsonb_agg(to_jsonb(history) ORDER BY temporal_event_id),'[]')
                   FROM pgreact_internal.temporal_history history WHERE rule_version_id = version_id),
        'activations',(SELECT COALESCE(jsonb_agg(to_jsonb(activation) ORDER BY activation_id),'[]')
                       FROM pgreact_internal.activation_state activation WHERE rule_version_id = version_id))
    INTO state_details;
    IF repaired IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'state-only temporal reconciliation reported % lifecycle repairs (frontier %, prior state %, active %, deadline %; current state %, active %, deadline %; details %)',
            repaired, observed_frontier, prior.state, prior.active, prior.pending_deadline,
            actual.state, actual.active, actual.pending_deadline, state_details;
    END IF;
    IF ROW(actual.state, actual.active, actual.input_true, actual.recovery_true,
           actual.continuous_since, actual.pending_deadline, actual.cooldown_until,
           actual.generation, actual.last_bindings)
       IS DISTINCT FROM
       (SELECT ROW(state, active, input_true, recovery_true, continuous_since,
                   pending_deadline, cooldown_until, generation, last_bindings)
        FROM upgrade_temporal_state_before) THEN
        RAISE EXCEPTION 'state-only temporal reconciliation changed pending temporal state: %',
            row_to_json(actual);
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.activation_state
               WHERE rule_version_id = version_id)
       OR EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers
                  WHERE rule_version_id = version_id
                    AND reason = 'RECONCILING') THEN
        RAISE EXCEPTION 'state-only temporal reconciliation left activation state or its claim barrier';
    END IF;
    IF (SELECT count(*) FROM pgreact_internal.temporal_history
        WHERE rule_version_id = version_id AND semantic_key = 1) <> 2
       OR EXISTS (
            SELECT 1 FROM pgreact_internal.temporal_history
            WHERE rule_version_id = version_id AND semantic_key = 1
              AND (event_kind IS DISTINCT FROM 'OBSERVE'
                   OR lifecycle_event_id IS NOT NULL
                   OR primitive_state IS DISTINCT FROM 'PENDING'
                   OR input_true IS DISTINCT FROM true
                   OR recovery_true IS DISTINCT FROM false
                   OR continuous_since IS DISTINCT FROM
                      (SELECT continuous_since FROM upgrade_temporal_state_before)
                   OR pending_deadline IS DISTINCT FROM
                      (SELECT pending_deadline FROM upgrade_temporal_state_before))) THEN
        RAISE EXCEPTION 'state-only temporal reconciliation did not preserve its two exact observation events';
    END IF;
END
$state_only_reconciliation$;
CREATE SCHEMA upgrade_rollback_identity;
CREATE TABLE upgrade_rollback_identity.candidates(case_key bigint PRIMARY KEY);
INSERT INTO upgrade_rollback_identity.candidates VALUES (1);
CREATE VIEW upgrade_rollback_identity.source AS
SELECT case_key FROM upgrade_rollback_identity.candidates;
SELECT pgreact.create_rule('upgrade-owner-identity',
    'upgrade_rollback_identity.source'::regclass, ARRAY['case_key']::name[]);
DO $owner_identity$
DECLARE actual record;
BEGIN
    SELECT r.owner_name, r.owner_oid, v.owner_oid AS version_owner_oid
    INTO STRICT actual
    FROM pgreact_internal.rules r
    JOIN pgreact_internal.rule_versions v USING (rule_id)
    WHERE r.rule_name='upgrade-owner-identity';
    IF actual.owner_name IS DISTINCT FROM 'postgres'::name
       OR actual.owner_oid <> 'postgres'::regrole::oid
       OR actual.version_owner_oid <> 'postgres'::regrole::oid THEN
        RAISE EXCEPTION 'upgraded rule registration lost owner identity: %', actual;
    END IF;
END
$owner_identity$;
SELECT 'PASS: upgrade STATE_ONLY temporal recovery preserved its pending deadline and cleared the barrier';

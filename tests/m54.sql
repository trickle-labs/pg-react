\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA IF NOT EXISTS m54_reference;
CREATE TABLE IF NOT EXISTS m54_reference.conditions (
    account_id bigint PRIMARY KEY,
    result text NOT NULL,
    state text NOT NULL
);
CREATE TABLE IF NOT EXISTS m54_reference.routes (
    account_id bigint NOT NULL,
    route_id bigint NOT NULL,
    priority bigint NOT NULL,
    result text NOT NULL,
    PRIMARY KEY (account_id, route_id)
);
TRUNCATE m54_reference.conditions, m54_reference.routes;
INSERT INTO m54_reference.conditions VALUES (1, 'first', 'open'), (2, 'second', 'open');
INSERT INTO m54_reference.routes VALUES (1, 10, 1, 'primary'), (1, 20, 2, 'backup');
CREATE OR REPLACE VIEW m54_reference.account_conditions AS
    SELECT account_id, result, state FROM m54_reference.conditions;
CREATE OR REPLACE VIEW m54_reference.route_candidates AS
    SELECT account_id, route_id, priority, result FROM m54_reference.routes;
CREATE OR REPLACE FUNCTION m54_reference.activate(
    context pgreact.activation_context,
    row_data m54_reference.account_conditions
)
RETURNS void LANGUAGE plpgsql AS $m54test$
BEGIN
    NULL;
END
$m54test$;

DO $m54test$
DECLARE
    declaration pgreact_api.declaration;
    replacement pgreact_api.declaration;
    decision pgreact_api.declaration;
    decision_replacement pgreact_api.declaration;
    preview jsonb;
    token text;
    deployed jsonb;
    exported jsonb;
    target_version_id uuid;
    target_program_id uuid;
    deployed_versions integer;
BEGIN
    IF to_regprocedure('pgreact.review_token(jsonb)') IS NULL
       OR to_regprocedure('pgreact.deploy(pgreact_api.declaration,text,jsonb)') IS NULL
       OR to_regprocedure('pgreact.reconcile_rule(text,text)') IS NULL
       OR to_regprocedure('pgreact.sweep_expired_leases(text)') IS NULL
       OR to_regprocedure('pgreact.requeue_episode(text,text)') IS NULL THEN
        RAISE EXCEPTION 'M54 public API inventory is incomplete';
    END IF;

    declaration := pgreact.rule(
        'm54-ordinary-rule', 'm54_reference.account_conditions'::regclass,
        'account_id', 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT',
        ARRAY['state']::name[], 7, 'default', ARRAY['state']::name[], 2, 1, 2, 60);
    preview := pgreact.preview(declaration);
    IF preview -> 'summary' ->> 'action' <> 'ADD'
       OR preview -> 'summary' ->> 'old_work_policy_required' <> 'false'
       OR length(preview -> 'summary' ->> 'plan_digest') <> 64
       OR preview ->> 'state' <> 'ready' THEN
        RAISE EXCEPTION 'M54 ordinary ADD preview mismatch: %', preview;
    END IF;
    token := pgreact.review_token(preview);
    IF length(token) >= 4096 OR token NOT LIKE 'm54.v1.%' THEN
        RAISE EXCEPTION 'M54 review token format mismatch';
    END IF;
    deployed := pgreact.deploy(declaration, token);
    IF deployed ->> 'state' <> 'deployed' OR deployed -> 'summary' ->> 'action' <> 'ADD' THEN
        RAISE EXCEPTION 'M54 ordinary ADD deployment mismatch: %', deployed;
    END IF;
    target_version_id := deployed -> 'summary' ->> 'delegated_id';
    preview := pgreact.preview(declaration);
    IF preview -> 'summary' ->> 'action' <> 'KEEP' THEN
        RAISE EXCEPTION 'M54 ordinary KEEP preview mismatch: %', preview;
    END IF;
    deployed := pgreact.deploy(declaration, pgreact.review_token(preview));
    IF deployed -> 'summary' ->> 'action' <> 'KEEP' THEN
        RAISE EXCEPTION 'M54 ordinary KEEP deployment mismatch: %', deployed;
    END IF;
    IF (SELECT version.change_columns FROM pgreact_internal.rule_versions version
        WHERE version.rule_version_id = target_version_id) IS DISTINCT FROM ARRAY['state']::name[]
       OR (SELECT version.conflict_key_columns FROM pgreact_internal.rule_versions version
           WHERE version.rule_version_id = target_version_id) IS DISTINCT FROM ARRAY['state']::name[] THEN
        RAISE EXCEPTION 'M54 ordinary rule fields were not propagated';
    END IF;
    exported := pgreact.export('m54-ordinary-rule', 'rule', '1');
    IF exported -> 'spec' ->> 'condition' <> 'm54_reference.account_conditions'
       OR exported -> 'spec' -> 'change_columns' IS DISTINCT FROM '["state"]'::jsonb
       OR exported -> 'spec' -> 'conflict_key_columns' IS DISTINCT FROM '["state"]'::jsonb THEN
        RAISE EXCEPTION 'M54 ordinary export mismatch: %', exported;
    END IF;

    replacement := pgreact.rule(
        'm54-ordinary-rule', 'm54_reference.account_conditions'::regclass,
        'account_id', 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT',
        ARRAY['result']::name[], 9, 'default', ARRAY['state']::name[], 2, 1, 2, 60);
    preview := pgreact.preview(replacement);
    IF preview -> 'summary' ->> 'action' <> 'REPLACE'
       OR preview -> 'summary' ->> 'current_declaration_digest' IS NULL
       OR preview -> 'summary' ->> 'proposed_declaration_digest' IS NULL THEN
        RAISE EXCEPTION 'M54 ordinary REPLACE preview mismatch: %', preview;
    END IF;
    deployed := pgreact.deploy(replacement, pgreact.review_token(preview),
                                jsonb_build_object('old_work', 'DRAIN_OLD'));
    IF deployed ->> 'state' <> 'deployed' OR deployed -> 'summary' ->> 'action' <> 'REPLACE' THEN
        RAISE EXCEPTION 'M54 ordinary REPLACE deployment mismatch: %', deployed;
    END IF;
    target_version_id := deployed -> 'summary' ->> 'delegated_id';
    IF (SELECT version.change_columns FROM pgreact_internal.rule_versions version
        WHERE version.rule_version_id = target_version_id) IS DISTINCT FROM ARRAY['result']::name[] THEN
        RAISE EXCEPTION 'M54 replacement watched columns were not propagated';
    END IF;

    decision := pgreact.decision(
        'm54-ordinary-decision', 'm54_reference.route_candidates'::regclass,
        'account_id', 'route_id', 'priority', ARRAY['result']::name[],
        '2026-01-01 00:00:00+00', NULL, 100);
    preview := pgreact.preview(decision);
    IF preview -> 'summary' ->> 'action' <> 'ADD' THEN
        RAISE EXCEPTION 'M54 decision ADD preview mismatch: %', preview;
    END IF;
    deployed := pgreact.deploy(decision, pgreact.review_token(preview));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M54 decision ADD deployment mismatch: %', deployed;
    END IF;
    decision_replacement := pgreact.decision(
        'm54-ordinary-decision', 'm54_reference.route_candidates'::regclass,
        'account_id', 'route_id', 'priority', ARRAY['result']::name[],
        '2026-01-01 00:00:00+00', NULL, 200);
    preview := pgreact.preview(decision_replacement);
    IF preview -> 'summary' ->> 'action' <> 'REPLACE' THEN
        RAISE EXCEPTION 'M54 decision REPLACE preview mismatch: %', preview;
    END IF;
    deployed := pgreact.deploy(decision_replacement, pgreact.review_token(preview));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M54 decision REPLACE deployment mismatch: %', deployed;
    END IF;
    SELECT version.program_id INTO target_program_id
    FROM pgreact_internal.api_declarations declaration_row
    JOIN pgreact_internal.decision_program_versions version
      ON version.version_id = declaration_row.delegated_id
    WHERE declaration_row.kind = 'decision_program'
      AND declaration_row.object_name = 'm54-ordinary-decision';
    SELECT count(*) INTO deployed_versions
    FROM pgreact_internal.decision_program_versions version
        WHERE version.program_id = target_program_id AND version.state = 'DEPLOYED';
    IF deployed_versions <> 1 THEN
        RAISE EXCEPTION 'M54 decision replacement left % deployed versions', deployed_versions;
    END IF;

    PERFORM pgreact.sweep_expired_leases('m54-ordinary-rule');

    BEGIN
        PERFORM pgreact.review_token('{}'::jsonb);
        RAISE EXCEPTION 'M54 accepted an invalid review result';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M54_REVIEW_TOKEN_INVALID:%' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM pgreact.deploy(replacement, 'not-a-review-token');
        RAISE EXCEPTION 'M54 accepted a malformed review token';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M54_REVIEW_TOKEN_INVALID:%' THEN RAISE; END IF;
    END;
    preview := pgreact.preview(replacement);
    CREATE OR REPLACE VIEW m54_reference.account_conditions AS
        SELECT account_id, result || '' AS result, state FROM m54_reference.conditions;
    BEGIN
        PERFORM pgreact.deploy(replacement, pgreact.review_token(preview));
        RAISE EXCEPTION 'M54 accepted a stale source review';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M54_REVIEW_TOKEN_STALE:%' THEN RAISE; END IF;
    END;
END
$m54test$;

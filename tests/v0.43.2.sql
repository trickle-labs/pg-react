\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA "Odd Schema";
CREATE TABLE "Odd Schema"."Odd Table" (account_id bigint PRIMARY KEY, state text NOT NULL);
INSERT INTO "Odd Schema"."Odd Table" VALUES (1, 'open');
CREATE VIEW "Odd Schema"."Odd Table View" AS
    SELECT account_id, state FROM "Odd Schema"."Odd Table";
CREATE VIEW safe_rule_source AS
    SELECT account_id, state FROM "Odd Schema"."Odd Table";

DO $v0432$
DECLARE
    declaration pgreact_api.declaration;
    expected pgreact_api.declaration;
    first_result jsonb;
    second_result jsonb;
    validation jsonb;
    package jsonb;
    ordered jsonb;
    expected_order jsonb := '[
        {"kind":"decision_program","name":"d","version":"1"},
        {"kind":"rule","name":"a","version":"1"},
        {"kind":"rule","name":"z","version":"1"}
    ]'::jsonb;
BEGIN
    declaration := pgreact.rule(
        'quoted-rule', '"Odd Schema"."Odd Table View"'::regclass, 'account_id');
    expected := pgreact_api.declaration('rule', 'quoted-rule', jsonb_build_object(
        'condition', '"Odd Schema"."Odd Table View"', 'semantic_key', 'account_id',
        'kind', 'CONSTRAINT', 'bootstrap_policy', 'SEED_CURRENT', 'salience', 0,
        'agenda_group', 'default', 'max_attempts', 1, 'initial_backoff_seconds', 1,
        'backoff_multiplier', 2, 'max_backoff_seconds', 60, 'delegate', true));
    IF declaration IS DISTINCT FROM expected THEN
        RAISE EXCEPTION '0.43.2 canonical rule output mismatch: %', declaration;
    END IF;
    validation := pgreact.validate(declaration);
    IF validation ->> 'state' <> 'ready'
       OR validation -> 'evidence' -> 'normalized_declaration' IS DISTINCT FROM
          jsonb_build_object('api_version', '1', 'kind', 'rule', 'name', 'quoted-rule',
              'spec', expected.spec) THEN
        RAISE EXCEPTION '0.43.2 quoted validation output mismatch: %', validation;
    END IF;

    first_result := pgreact.deploy(
        pgreact.rule('guarded-rule', 'safe_rule_source'::regclass, 'account_id'),
        jsonb_build_object('allow_create', false));
    IF first_result ->> 'state' <> 'deployed'
       OR first_result -> 'summary' ->> 'action' <> 'ADD'
       OR first_result -> 'summary' ->> 'delegated_id' IS NULL THEN
        RAISE EXCEPTION '0.43.2 allow_create=false creation mismatch: %', first_result;
    END IF;
    declaration := pgreact.rule(
        'guarded-rule', 'safe_rule_source'::regclass, 'account_id',
        'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT', NULL, 1);
    second_result := pgreact.deploy(declaration, jsonb_build_object(
        'allow_create', false,
        'expected_current_digest', first_result -> 'summary' ->> 'proposed_declaration_digest'));
    IF second_result ->> 'state' <> 'deployed'
       OR second_result -> 'summary' ->> 'action' <> 'REPLACE' THEN
        RAISE EXCEPTION '0.43.2 guarded replacement mismatch: %', second_result;
    END IF;
    BEGIN
        PERFORM pgreact.deploy(
            pgreact.rule('guarded-rule', 'safe_rule_source'::regclass,
                'account_id', 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT', NULL, 2),
            jsonb_build_object('allow_create', false,
                'expected_current_digest', first_result -> 'summary' ->> 'proposed_declaration_digest'));
        RAISE EXCEPTION '0.43.2 accepted a stale expected_current_digest';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'M28_REPLACE_STALE' THEN RAISE; END IF;
    END;

    package := jsonb_build_object(
        'spec', jsonb_build_object(
            'members', jsonb_build_array(
                jsonb_build_object('kind', 'rule', 'name', 'z', 'version', '1'),
                jsonb_build_object('kind', 'rule', 'name', 'a', 'version', '1'),
                jsonb_build_object('kind', 'decision_program', 'name', 'd', 'version', '1')),
            'support', '[]'::jsonb,
            'dependencies', jsonb_build_array(jsonb_build_object(
                'from', jsonb_build_object('kind', 'rule', 'name', 'z', 'version', '1'),
                'on', jsonb_build_object('kind', 'rule', 'name', 'a', 'version', '1')))));
    ordered := pgreact_internal.m54_package_graph_order(package);
    IF ordered IS DISTINCT FROM expected_order THEN
        RAISE EXCEPTION '0.43.2 package order mismatch: %', ordered;
    END IF;
    package := jsonb_set(package, '{spec,dependencies}', jsonb_build_array(
        jsonb_build_object('from', jsonb_build_object('kind', 'rule', 'name', 'z', 'version', '1'),
                           'on', jsonb_build_object('kind', 'rule', 'name', 'a', 'version', '1')),
        jsonb_build_object('from', jsonb_build_object('kind', 'rule', 'name', 'a', 'version', '1'),
                           'on', jsonb_build_object('kind', 'rule', 'name', 'z', 'version', '1'))));
    IF pgreact_internal.m54_package_has_cycle(package -> 'spec') IS DISTINCT FROM true THEN
        RAISE EXCEPTION '0.43.2 package cycle detection mismatch';
    END IF;

    CREATE TABLE "Odd Schema"."RLS Table" (account_id bigint PRIMARY KEY);
    ALTER TABLE "Odd Schema"."RLS Table" ENABLE ROW LEVEL SECURITY;
    CREATE VIEW "Odd Schema"."RLS View" AS
        SELECT account_id FROM "Odd Schema"."RLS Table";
    validation := pgreact.validate(pgreact.rule(
        'rls-rule', '"Odd Schema"."RLS View"'::regclass, 'account_id'));
    IF validation ->> 'state' <> 'attention'
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(validation -> 'findings') item
                      WHERE item ->> 'code' = 'M54_RLS_UNSUPPORTED'
                        AND item ->> 'severity' = 'ERROR') THEN
        RAISE EXCEPTION '0.43.2 transitive RLS validation mismatch: %', validation;
    END IF;
END
$v0432$;

SELECT 'v0.43.2 SQL corpus passed' AS result;

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m15_reason AUTHORIZATION m15_author;
CREATE TYPE m15_reason.fact_row AS (
    tenant text COLLATE "C",
    event_id uuid
);
CREATE TABLE m15_reason.seed (
    tenant text COLLATE "C" NOT NULL,
    event_id uuid NOT NULL,
    PRIMARY KEY (tenant, event_id)
);
CREATE TABLE m15_reason.candidate (LIKE m15_reason.seed INCLUDING ALL);
CREATE TABLE m15_reason.blocked (LIKE m15_reason.seed INCLUDING ALL);
CREATE TABLE m15_reason.groups (LIKE m15_reason.seed INCLUDING ALL);
CREATE TABLE m15_reason.items (
    item_id bigint PRIMARY KEY,
    tenant text COLLATE "C" NOT NULL,
    event_id uuid NOT NULL
);
CREATE VIEW m15_reason.seed_source AS SELECT * FROM m15_reason.seed;
CREATE VIEW m15_reason.candidate_source AS SELECT * FROM m15_reason.candidate;
CREATE VIEW m15_reason.blocked_source AS SELECT * FROM m15_reason.blocked;
CREATE VIEW m15_reason.group_source AS SELECT * FROM m15_reason.groups;
CREATE VIEW m15_reason.item_source AS SELECT tenant, event_id FROM m15_reason.items;
ALTER TYPE m15_reason.fact_row OWNER TO m15_author;
ALTER TABLE m15_reason.seed OWNER TO m15_author;
ALTER TABLE m15_reason.candidate OWNER TO m15_author;
ALTER TABLE m15_reason.blocked OWNER TO m15_author;
ALTER TABLE m15_reason.groups OWNER TO m15_author;
ALTER TABLE m15_reason.items OWNER TO m15_author;
ALTER VIEW m15_reason.seed_source OWNER TO m15_author;
ALTER VIEW m15_reason.candidate_source OWNER TO m15_author;
ALTER VIEW m15_reason.blocked_source OWNER TO m15_author;
ALTER VIEW m15_reason.group_source OWNER TO m15_author;
ALTER VIEW m15_reason.item_source OWNER TO m15_author;

SET SESSION AUTHORIZATION m15_author;
SELECT pgreact_api.declare_derived_relation(
    'm15_reason.reach', 'm15_reason.fact_row'::regtype,
    ARRAY['tenant', 'event_id']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm15_reason.eligible', 'm15_reason.fact_row'::regtype,
    ARRAY['tenant', 'event_id']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm15_reason.alert', 'm15_reason.fact_row'::regtype,
    ARRAY['tenant', 'event_id']::name[]);
CREATE VIEW m15_reason.cycle_source AS SELECT * FROM m15_reason.reach;
ALTER VIEW m15_reason.cycle_source OWNER TO m15_author;
RESET SESSION AUTHORIZATION;

INSERT INTO m15_reason.seed VALUES (
    'north', '123e4567-e89b-12d3-a456-426614174030');
INSERT INTO m15_reason.candidate VALUES (
    'north', '123e4567-e89b-12d3-a456-426614174031');
INSERT INTO m15_reason.blocked VALUES (
    'north', '123e4567-e89b-12d3-a456-426614174031');
INSERT INTO m15_reason.groups VALUES (
    'north', '123e4567-e89b-12d3-a456-426614174032');
INSERT INTO m15_reason.items VALUES
    (1, 'north', '123e4567-e89b-12d3-a456-426614174032'),
    (2, 'north', '123e4567-e89b-12d3-a456-426614174032');

SET SESSION AUTHORIZATION m15_author;
DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'm15.reasoning', 'version', 1, 'max_iterations', 8, 'max_facts', 32,
        'rules', jsonb_build_array(
            jsonb_build_object(
                'name', 'm15.reach.seed', 'definition', 'm15_reason.seed_source',
                'key', jsonb_build_array('tenant', 'event_id'),
                'target', 'm15_reason.reach', 'version', 1),
            jsonb_build_object(
                'name', 'm15.reach.cycle', 'definition', 'm15_reason.cycle_source',
                'key', jsonb_build_array('tenant', 'event_id'),
                'target', 'm15_reason.reach', 'version', 1),
            jsonb_build_object(
                'name', 'm15.eligible', 'definition', 'm15_reason.candidate_source',
                'key', jsonb_build_array('tenant', 'event_id'),
                'target', 'm15_reason.eligible', 'version', 1,
                'negative_inputs', jsonb_build_array(jsonb_build_object(
                    'relation', 'm15_reason.blocked_source',
                    'key', jsonb_build_array('tenant', 'event_id')))),
            jsonb_build_object(
                'name', 'm15.alert', 'definition', 'm15_reason.group_source',
                'key', jsonb_build_array('tenant', 'event_id'),
                'target', 'm15_reason.alert', 'version', 1,
                'aggregate_input', jsonb_build_object(
                    'relation', 'm15_reason.item_source',
                    'key', jsonb_build_array('tenant', 'event_id'),
                    'comparison', '>=', 'threshold', 2))));
    preview jsonb;
BEGIN
    preview := pgreact_api.preview_program(definition);
    PERFORM pgreact_api.deploy_program(definition, preview ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb; explanation jsonb;
BEGIN
    SELECT jsonb_agg(fact ORDER BY fact ->> 'relation') INTO actual
    FROM (
        SELECT jsonb_build_object('relation', 'alert', 'rows',
                   COALESCE(jsonb_agg(to_jsonb(row_value) ORDER BY tenant, event_id), '[]'::jsonb)) fact
        FROM m15_reason.alert row_value
        UNION ALL
        SELECT jsonb_build_object('relation', 'eligible', 'rows',
                   COALESCE(jsonb_agg(to_jsonb(row_value) ORDER BY tenant, event_id), '[]'::jsonb))
        FROM m15_reason.eligible row_value
        UNION ALL
        SELECT jsonb_build_object('relation', 'reach', 'rows',
                   COALESCE(jsonb_agg(to_jsonb(row_value) ORDER BY tenant, event_id), '[]'::jsonb))
        FROM m15_reason.reach row_value
    ) facts;
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('relation', 'alert', 'rows', jsonb_build_array(jsonb_build_object(
            'tenant', 'north', 'event_id', '123e4567-e89b-12d3-a456-426614174032'))),
        jsonb_build_object('relation', 'eligible', 'rows', '[]'::jsonb),
        jsonb_build_object('relation', 'reach', 'rows', jsonb_build_array(jsonb_build_object(
            'tenant', 'north', 'event_id', '123e4567-e89b-12d3-a456-426614174030')))) THEN
        RAISE EXCEPTION 'M15 typed recursive/negative/aggregate facts changed: %', actual;
    END IF;
    explanation := pgreact_api.explain(
        'm15_reason.alert', '["north","123e4567-e89b-12d3-a456-426614174032"]'::jsonb);
    IF explanation #> '{target,key}' IS DISTINCT FROM jsonb_build_array(
            'north', '123e4567-e89b-12d3-a456-426614174032')
       OR explanation::text LIKE '%__pgreact_%'
       OR explanation::text LIKE '%pgreact_runtime.%' THEN
        RAISE EXCEPTION 'M15 aggregate explanation leaked private identity: %', explanation;
    END IF;
END
$$;

DELETE FROM m15_reason.blocked;
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
DO $$
DECLARE explanation jsonb;
BEGIN
    IF (SELECT jsonb_agg(to_jsonb(row_value) ORDER BY tenant, event_id)
        FROM m15_reason.eligible row_value) IS DISTINCT FROM jsonb_build_array(
            jsonb_build_object('tenant', 'north',
                'event_id', '123e4567-e89b-12d3-a456-426614174031')) THEN
        RAISE EXCEPTION 'M15 typed negation transition changed';
    END IF;
    explanation := pgreact_api.explain(
        'm15_reason.eligible', '["north","123e4567-e89b-12d3-a456-426614174031"]'::jsonb);
    IF explanation #> '{target,key}' IS DISTINCT FROM jsonb_build_array(
            'north', '123e4567-e89b-12d3-a456-426614174031')
       OR explanation::text LIKE '%__pgreact_%'
       OR explanation::text LIKE '%pgreact_runtime.%' THEN
        RAISE EXCEPTION 'M15 negative explanation leaked private identity: %', explanation;
    END IF;
END
$$;

DELETE FROM m15_reason.items WHERE item_id = 2;
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM m15_reason.alert) THEN
        RAISE EXCEPTION 'M15 typed aggregate retraction changed';
    END IF;
END
$$;

SET SESSION AUTHORIZATION m15_author;
DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'm15.reasoning', 'version', 2, 'max_iterations', 8, 'max_facts', 32,
        'rules', jsonb_build_array(
            jsonb_build_object(
                'name', 'm15.reach.seed', 'definition', 'm15_reason.seed_source',
                'key', jsonb_build_array('tenant', 'event_id'),
                'target', 'm15_reason.reach', 'version', 1),
            jsonb_build_object(
                'name', 'm15.reach.cycle', 'definition', 'm15_reason.cycle_source',
                'key', jsonb_build_array('tenant', 'event_id'),
                'target', 'm15_reason.reach', 'version', 1),
            jsonb_build_object(
                'name', 'm15.eligible', 'definition', 'm15_reason.candidate_source',
                'key', jsonb_build_array('tenant', 'event_id'),
                'target', 'm15_reason.eligible', 'version', 1,
                'negative_inputs', jsonb_build_array(jsonb_build_object(
                    'relation', 'm15_reason.blocked_source',
                    'key', jsonb_build_array('tenant', 'event_id')))),
            jsonb_build_object(
                'name', 'm15.alert', 'definition', 'm15_reason.group_source',
                'key', jsonb_build_array('tenant', 'event_id'),
                'target', 'm15_reason.alert', 'version', 1,
                'aggregate_input', jsonb_build_object(
                    'relation', 'm15_reason.item_source',
                    'key', jsonb_build_array('tenant', 'event_id'),
                    'comparison', '>=', 'threshold', 2))));
BEGIN
    PERFORM pgreact_api.deploy_program(
        definition, pgreact_api.preview_program(definition) ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;

DO $$
DECLARE explanation jsonb;
BEGIN
    explanation := pgreact_api.explain(
        'm15_reason.reach', '["north","123e4567-e89b-12d3-a456-426614174030"]'::jsonb);
    IF (SELECT count(*) FROM m15_reason.reach) <> 1
       OR (SELECT count(*) FROM m15_reason.eligible) <> 1
       OR EXISTS (SELECT 1 FROM m15_reason.alert)
       OR explanation #> '{target,key}' IS DISTINCT FROM jsonb_build_array(
            'north', '123e4567-e89b-12d3-a456-426614174030')
       OR explanation::text LIKE '%__pgreact_%'
       OR explanation::text LIKE '%pgreact_runtime.%' THEN
        RAISE EXCEPTION 'M15 typed program replacement or recursion changed: %', explanation;
    END IF;
END
$$;

SELECT 'M15 typed recursion, negation, aggregation, explanation, and program replacement gate passed';

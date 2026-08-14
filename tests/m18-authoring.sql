\set ON_ERROR_STOP on
\o /dev/null
SET TIME ZONE 'UTC';
SET client_min_messages = error;
SELECT setseed(0.18);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm18_author') THEN CREATE ROLE m18_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm18_operator') THEN CREATE ROLE m18_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm18_worker') THEN CREATE ROLE m18_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm18_reader') THEN CREATE ROLE m18_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm18_advanced') THEN CREATE ROLE m18_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles(
    'm18_author', 'm18_operator', 'm18_worker', 'm18_reader', 'm18_advanced');

-- Risk/fraud: one constraint and one asynchronous review command.
CREATE SCHEMA m18_risk AUTHORIZATION m18_author;
SET SESSION AUTHORIZATION m18_author;
CREATE TABLE m18_risk.transfers (
    transfer_id bigint PRIMARY KEY,
    account_id bigint NOT NULL,
    amount numeric NOT NULL
);
CREATE VIEW m18_risk.suspicious AS
SELECT transfer_id, account_id, amount FROM m18_risk.transfers WHERE amount >= 1000;
CREATE TABLE m18_risk.reviews (
    event text NOT NULL,
    transfer_id bigint NOT NULL,
    amount numeric NOT NULL
);
CREATE FUNCTION m18_risk.activate(row_value m18_risk.suspicious)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m18_risk.reviews VALUES ('activate', row_value.transfer_id, row_value.amount)
$$;
CREATE FUNCTION m18_risk.deactivate(row_value m18_risk.suspicious)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m18_risk.reviews VALUES ('deactivate', row_value.transfer_id, row_value.amount)
$$;
CREATE FUNCTION m18_risk.change(
    old_row m18_risk.suspicious, new_row m18_risk.suspicious)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m18_risk.reviews VALUES ('change', new_row.transfer_id, new_row.amount)
$$;
SELECT pgreact_api.author_rule(
    rule_name => 'risk.suspicious-transfer',
    condition => 'm18_risk.suspicious'::regclass,
    semantic_key => 'transfer_id',
    kind => 'CONSTRAINT');
SELECT pgreact_api.author_rule(
    'risk.review-transfer', 'm18_risk.suspicious', ARRAY['transfer_id']::name[],
    'm18_risk', 'activate', 'deactivate', 'change');
RESET SESSION AUTHORIZATION;
INSERT INTO m18_risk.transfers VALUES (1, 7, 1250), (2, 8, 20);
SET SESSION AUTHORIZATION m18_operator;
SELECT pgreact_api.run('2030-01-01T00:00:00Z');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m18_worker;
SELECT pgreact_api.managed_cycle();
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(review) ORDER BY event, transfer_id) INTO actual
    FROM m18_risk.reviews review;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'event', 'activate', 'transfer_id', 1, 'amount', 1250))
       OR pgreact_api.matches('risk.suspicious-transfer') #> '{matches,0,key}'
          IS DISTINCT FROM '1'::jsonb
       OR (pgreact_api.jobs('risk.review-transfer') #> '{jobs,0}') -
          ARRAY['job_id','available_at','claimed_at','completed_at','idempotency_key']
          IS DISTINCT FROM jsonb_build_object(
            'rule', 'risk.review-transfer', 'action', 'activate',
            'state', 'completed', 'key', 1) THEN
        RAISE EXCEPTION 'M18 risk/fraud transcript changed: %, %, %', actual,
            pgreact_api.matches('risk.suspicious-transfer'),
            pgreact_api.jobs('risk.review-transfer');
    END IF;
END
$$;

-- Inventory: direct derived stock knowledge plus a typed reorder aggregate.
CREATE SCHEMA m18_inventory AUTHORIZATION m18_author;
SET SESSION AUTHORIZATION m18_author;
CREATE TYPE m18_inventory.fact_row AS (product_id bigint);
CREATE TABLE m18_inventory.products(product_id bigint PRIMARY KEY);
CREATE TABLE m18_inventory.stock_lines(
    line_id bigint PRIMARY KEY, product_id bigint NOT NULL, units integer NOT NULL);
CREATE VIEW m18_inventory.product_source AS SELECT product_id FROM m18_inventory.products;
CREATE VIEW m18_inventory.stock_source AS
SELECT line_id, product_id, units FROM m18_inventory.stock_lines;
INSERT INTO m18_inventory.products VALUES (101), (102);
SELECT pgreact_api.declare_derived_relation(
    'm18_inventory.current_stock', 'm18_inventory.fact_row'::regtype,
    ARRAY['product_id']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm18_inventory.reorder', 'm18_inventory.fact_row'::regtype,
    ARRAY['product_id']::name[]);
DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'inventory.stock', 'version', 1, 'max_iterations', 8, 'max_facts', 32,
        'rules', jsonb_build_array(
            jsonb_build_object(
                'name', 'inventory.current-stock',
                'definition', 'm18_inventory.product_source',
                'key', 'product_id', 'target', 'm18_inventory.current_stock', 'version', 1),
            jsonb_build_object(
                'name', 'inventory.reorder',
                'definition', 'm18_inventory.product_source',
                'key', 'product_id', 'target', 'm18_inventory.reorder', 'version', 1,
                'aggregate_input', jsonb_build_object(
                    'relation', 'm18_inventory.stock_source', 'key', 'product_id',
                    'function', 'SUM', 'expression', 'units',
                    'comparison', '>=', 'threshold', 10))));
BEGIN
    PERFORM pgreact_api.deploy_program(
        definition, pgreact_api.preview_program(definition) ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;
INSERT INTO m18_inventory.stock_lines VALUES (1,101,4), (2,101,7), (3,102,2);
SET SESSION AUTHORIZATION m18_operator;
SELECT pgreact_api.run('2030-01-01T00:00:01Z');
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb; explanation jsonb;
BEGIN
    SELECT jsonb_build_object(
        'current_stock', (SELECT jsonb_agg(product_id ORDER BY product_id)
                          FROM m18_inventory.current_stock),
        'reorder', (SELECT jsonb_agg(product_id ORDER BY product_id)
                    FROM m18_inventory.reorder)) INTO actual;
    explanation := pgreact_api.explain('m18_inventory.reorder', '101'::jsonb);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'current_stock', jsonb_build_array(101,102), 'reorder', jsonb_build_array(101))
       OR explanation -> 'target' IS DISTINCT FROM jsonb_build_object(
            'kind', 'fact', 'name', 'm18_inventory.reorder', 'key', 101)
       OR explanation #> '{evidence,fact}' IS DISTINCT FROM jsonb_build_object(
            'product_id', 101) THEN
        RAISE EXCEPTION 'M18 inventory transcript changed: %, %', actual, explanation;
    END IF;
END
$$;

-- SLA/deadline: overdue lifecycle and escalation command.
CREATE SCHEMA m18_sla AUTHORIZATION m18_author;
SET SESSION AUTHORIZATION m18_author;
CREATE TABLE m18_sla.tickets(
    ticket_id bigint PRIMARY KEY, due_at timestamptz NOT NULL, open boolean NOT NULL);
CREATE VIEW m18_sla.overdue_candidate AS
SELECT ticket_id, due_at FROM m18_sla.tickets WHERE open;
CREATE TABLE m18_sla.escalations(ticket_id bigint PRIMARY KEY);
CREATE FUNCTION m18_sla.escalate(row_value m18_sla.overdue_candidate)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m18_sla.escalations VALUES (row_value.ticket_id)
$$;
SELECT pgreact_api.author_deadline_rule(
    'sla.overdue', 'm18_sla.overdue_candidate', ARRAY['ticket_id']::name[],
    'due_at', 'm18_sla', 'escalate');
RESET SESSION AUTHORIZATION;
INSERT INTO m18_sla.tickets VALUES
    (11, '2030-01-01T00:00:00Z', true), (12, '2030-02-01T00:00:00Z', true);
SET SESSION AUTHORIZATION m18_operator;
SELECT pgreact_api.run('2030-01-02T00:00:00Z');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m18_worker;
SELECT pgreact_api.managed_cycle();
SELECT pgreact_api.managed_cycle();
RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF pgreact_api.deadline_history('sla.overdue') #> '{events,0,semantic_key}'
       IS DISTINCT FROM '11'::jsonb
       OR pgreact_api.jobs('sla.overdue') #> '{jobs,0,key}' IS DISTINCT FROM '11'::jsonb
       OR (SELECT jsonb_agg(ticket_id ORDER BY ticket_id) FROM m18_sla.escalations)
          IS DISTINCT FROM jsonb_build_array(11) THEN
        RAISE EXCEPTION 'M18 SLA transcript changed: %, %, %',
            pgreact_api.deadline_history('sla.overdue'), pgreact_api.jobs('sla.overdue'),
            (SELECT jsonb_agg(ticket_id ORDER BY ticket_id) FROM m18_sla.escalations);
    END IF;
END
$$;

-- Derived knowledge: positive recursion and stratified absence.
CREATE SCHEMA m18_knowledge AUTHORIZATION m18_author;
SET SESSION AUTHORIZATION m18_author;
CREATE TYPE m18_knowledge.fact_row AS (id bigint);
CREATE TABLE m18_knowledge.seeds(id bigint PRIMARY KEY);
CREATE TABLE m18_knowledge.blocked(id bigint PRIMARY KEY);
CREATE VIEW m18_knowledge.seed_source AS SELECT id FROM m18_knowledge.seeds;
CREATE VIEW m18_knowledge.blocked_source AS SELECT id FROM m18_knowledge.blocked;
INSERT INTO m18_knowledge.seeds VALUES (1), (2);
INSERT INTO m18_knowledge.blocked VALUES (2);
SELECT pgreact_api.declare_derived_relation(
    'm18_knowledge.a', 'm18_knowledge.fact_row'::regtype, 'id');
SELECT pgreact_api.declare_derived_relation(
    'm18_knowledge.b', 'm18_knowledge.fact_row'::regtype, 'id');
SELECT pgreact_api.declare_derived_relation(
    'm18_knowledge.c', 'm18_knowledge.fact_row'::regtype, 'id');
SELECT pgreact_api.declare_derived_relation(
    'm18_knowledge.eligible', 'm18_knowledge.fact_row'::regtype, 'id');
CREATE VIEW m18_knowledge.a_to_b AS SELECT id FROM m18_knowledge.a;
CREATE VIEW m18_knowledge.b_to_c AS SELECT id FROM m18_knowledge.b;
CREATE VIEW m18_knowledge.c_to_b AS SELECT id FROM m18_knowledge.c;
DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'knowledge.reference', 'version', 1,
        'max_iterations', 16, 'max_facts', 64,
        'rules', jsonb_build_array(
            jsonb_build_object(
                'name', 'knowledge.seed', 'definition', 'm18_knowledge.seed_source',
                'key', 'id', 'target', 'm18_knowledge.a', 'version', 1),
            jsonb_build_object(
                'name', 'knowledge.a-to-b', 'definition', 'm18_knowledge.a_to_b',
                'key', 'id', 'target', 'm18_knowledge.b', 'version', 1),
            jsonb_build_object(
                'name', 'knowledge.b-to-c', 'definition', 'm18_knowledge.b_to_c',
                'key', 'id', 'target', 'm18_knowledge.c', 'version', 1),
            jsonb_build_object(
                'name', 'knowledge.c-to-b', 'definition', 'm18_knowledge.c_to_b',
                'key', 'id', 'target', 'm18_knowledge.b', 'version', 1),
            jsonb_build_object(
                'name', 'knowledge.eligible', 'definition', 'm18_knowledge.seed_source',
                'key', 'id', 'target', 'm18_knowledge.eligible', 'version', 1,
                'negative_inputs', jsonb_build_array(jsonb_build_object(
                    'relation', 'm18_knowledge.blocked_source', 'key', 'id')))));
BEGIN
    PERFORM pgreact_api.deploy_program(
        definition, pgreact_api.preview_program(definition) ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m18_operator;
SELECT pgreact_api.run('2030-01-02T00:00:01Z');
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb; explanation jsonb;
BEGIN
    SELECT jsonb_build_object(
        'a', (SELECT jsonb_agg(id ORDER BY id) FROM m18_knowledge.a),
        'b', (SELECT jsonb_agg(id ORDER BY id) FROM m18_knowledge.b),
        'c', (SELECT jsonb_agg(id ORDER BY id) FROM m18_knowledge.c),
        'eligible', (SELECT jsonb_agg(id ORDER BY id) FROM m18_knowledge.eligible))
    INTO actual;
    explanation := pgreact_api.explain('knowledge.reference', true);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'a', jsonb_build_array(1,2), 'b', jsonb_build_array(1,2),
        'c', jsonb_build_array(1,2), 'eligible', jsonb_build_array(1))
       OR explanation -> 'target' IS DISTINCT FROM jsonb_build_object(
            'kind', 'program', 'name', 'knowledge.reference', 'version', 1)
       OR (SELECT jsonb_agg(rule ->> 'name' ORDER BY rule ->> 'name')
           FROM jsonb_array_elements(explanation #> '{evidence,definition,rules}') rule)
          IS DISTINCT FROM jsonb_build_array(
            'knowledge.a-to-b','knowledge.b-to-c','knowledge.c-to-b',
            'knowledge.eligible','knowledge.seed') THEN
        RAISE EXCEPTION 'M18 derived-knowledge transcript changed: %, %', actual, explanation;
    END IF;
END
$$;

-- Event-time windows: tumbling aggregate, out-of-order input, correction, finalization.
CREATE SCHEMA m18_windows AUTHORIZATION m18_author;
SET SESSION AUTHORIZATION m18_author;
CREATE TYPE m18_windows.fact_row AS (account_id bigint, window_ordinal bigint);
CREATE TABLE m18_windows.accounts(account_id bigint PRIMARY KEY);
CREATE TABLE m18_windows.transfers(
    transfer_id bigint PRIMARY KEY, account_id bigint NOT NULL,
    amount numeric NOT NULL, occurred_at timestamptz NOT NULL);
CREATE VIEW m18_windows.account_source AS SELECT account_id FROM m18_windows.accounts;
CREATE VIEW m18_windows.transfer_source AS
SELECT transfer_id, account_id, amount, occurred_at FROM m18_windows.transfers;
INSERT INTO m18_windows.accounts VALUES (7);
SELECT pgreact_api.declare_derived_relation(
    'm18_windows.alert', 'm18_windows.fact_row'::regtype,
    ARRAY['account_id','window_ordinal']::name[]);
DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'windows.reference', 'version', 1, 'max_iterations', 8, 'max_facts', 32,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'windows.sum', 'definition', 'm18_windows.account_source',
            'key', 'account_id', 'target', 'm18_windows.alert', 'version', 1,
            'aggregate_input', jsonb_build_object(
                'relation', 'm18_windows.transfer_source', 'key', 'account_id',
                'function', 'SUM', 'expression', 'amount',
                'comparison', '>=', 'threshold', 10,
                'window', jsonb_build_object(
                    'event_time', 'occurred_at', 'duration', 'PT1H',
                    'allowed_lateness', 'PT15M')))));
BEGIN
    PERFORM pgreact_api.deploy_program(
        definition, pgreact_api.preview_program(definition) ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;
INSERT INTO m18_windows.transfers VALUES
    (1,7,6,'2030-01-01T00:05:00Z'), (2,7,5,'2030-01-01T00:01:00Z');
SET SESSION AUTHORIZATION m18_operator;
SELECT pgreact_api.run('2030-01-02T00:00:02Z');
RESET SESSION AUTHORIZATION;
UPDATE m18_windows.transfers SET amount = 8 WHERE transfer_id = 2;
SET SESSION AUTHORIZATION m18_operator;
SELECT pgreact_api.run('2030-01-02T00:00:03Z');
SELECT pgreact_api.request_watermark(
    'windows.reference', 'm18_windows.transfer_source', 'occurred_at',
    '2030-01-01T01:15:00Z');
SELECT pgreact_api.run('2030-01-02T00:00:04Z');
SELECT pgreact_api.run('2030-01-02T00:00:05Z');
RESET SESSION AUTHORIZATION;
DO $$
DECLARE evidence jsonb; correction jsonb; watermark jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'rule', rule_name, 'key', public_window_key, 'value', exact_value,
        'truth', truth_result, 'generation', support_generation,
        'final', is_final) ORDER BY rule_name, public_window_key)
    INTO evidence FROM pgreact.window_evidence WHERE program_name = 'windows.reference';
    SELECT jsonb_agg(to_jsonb(row_value) - 'next_cursor' ORDER BY correction_identity)
    INTO correction FROM pgreact_api.window_corrections('windows.reference', 100, NULL) row_value;
    SELECT to_jsonb(row_value) INTO watermark
    FROM pgreact_api.watermark_status('windows.reference') row_value;
    IF evidence IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'rule', 'windows.sum', 'key', jsonb_build_array(7,525960), 'value', '14',
        'truth', true, 'generation', 1, 'final', true))
       OR correction IS DISTINCT FROM '[
            {"rule_name":"windows.sum","after_truth":true,"after_value":"11",
             "before_truth":null,"before_value":null,"lower_frontier":1,
             "program_version":1,"public_window_key":[7,525960],"support_generation":1,
             "correction_identity":"windows.reference@1/windows.sum@1/[7,525960]/F1"},
            {"rule_name":"windows.sum","after_truth":true,"after_value":"14",
             "before_truth":true,"before_value":"11","lower_frontier":2,
             "program_version":1,"public_window_key":[7,525960],"support_generation":1,
             "correction_identity":"windows.reference@1/windows.sum@1/[7,525960]/F2"}
          ]'::jsonb
       OR watermark - 'history_floor' IS DISTINCT FROM jsonb_build_object(
            'input_relation', 'm18_windows.transfer_source',
            'event_time_column', 'occurred_at',
            'requested_watermark', '2030-01-01T01:15:00+00:00',
            'complete_watermark', '2030-01-01T01:15:00+00:00',
            'status', 'complete', 'barrier', NULL) THEN
        RAISE EXCEPTION 'M18 window transcript changed: %, %, %',
            evidence, correction, watermark;
    END IF;
END
$$;

-- Cleanup is part of the copy/run oracle.
SET SESSION AUTHORIZATION m18_author;
SELECT pgreact_api.remove_rule('risk.suspicious-transfer');
SELECT pgreact_api.remove_rule('risk.review-transfer');
SELECT pgreact_api.remove_rule('sla.overdue');
SELECT pgreact_api.remove_program('inventory.stock', 1);
SELECT pgreact_api.remove_program('knowledge.reference', 1);
SELECT pgreact_api.remove_program('windows.reference', 1);
RESET SESSION AUTHORIZATION;
DROP SCHEMA m18_risk, m18_inventory, m18_sla, m18_knowledge, m18_windows CASCADE;
\o
SELECT 'risk/fraud|constraint+review-command|exact';
SELECT 'inventory|derivation+aggregate|exact';
SELECT 'sla/deadline|overdue+escalation|exact';
SELECT 'derived-knowledge|positive-recursion+stratified-absence|exact';
SELECT 'event-time-windows|out-of-order+correction+finalization|exact';
SELECT 'cleanup|complete';

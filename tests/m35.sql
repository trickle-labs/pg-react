\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m35_reference;
CREATE TABLE m35_reference.orders_current (
    order_id bigint PRIMARY KEY,
    status text NOT NULL,
    amount bigint NOT NULL
);
INSERT INTO m35_reference.orders_current VALUES
    (1, 'review', 100), (2, 'review', 200), (4, 'review', 400);
CREATE VIEW m35_reference.orders_deployed AS
SELECT order_id, status, amount FROM m35_reference.orders_current;
CREATE TABLE m35_reference.orders_hypothetical (
    order_id bigint PRIMARY KEY,
    status text NOT NULL,
    amount bigint NOT NULL
);
INSERT INTO m35_reference.orders_hypothetical
SELECT * FROM m35_reference.orders_current;
CREATE TABLE m35_reference.rls_orders (
    order_id bigint PRIMARY KEY,
    status text NOT NULL,
    amount bigint NOT NULL
);
ALTER TABLE m35_reference.rls_orders ENABLE ROW LEVEL SECURITY;
CREATE TABLE m35_reference.candidates_current (
    subject_id bigint NOT NULL,
    candidate_id bigint PRIMARY KEY,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m35_reference.candidates_current VALUES
    (10, 100, 1, 'approve'), (20, 200, 1, 'hold');
CREATE VIEW m35_reference.candidates_deployed AS
SELECT subject_id, candidate_id, priority, result
FROM m35_reference.candidates_current;
CREATE TABLE m35_reference.candidates_hypothetical (
    subject_id bigint NOT NULL,
    candidate_id bigint PRIMARY KEY,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m35_reference.candidates_hypothetical
SELECT * FROM m35_reference.candidates_current;
CREATE TABLE m35_reference.customers_current (customer_id bigint PRIMARY KEY);
INSERT INTO m35_reference.customers_current VALUES (10), (20);
CREATE TABLE m35_reference.customers_hypothetical (customer_id bigint PRIMARY KEY);
INSERT INTO m35_reference.customers_hypothetical
SELECT * FROM m35_reference.customers_current;
CREATE TABLE m35_reference.policy_members_current (customer_id bigint PRIMARY KEY);
INSERT INTO m35_reference.policy_members_current VALUES (10), (20);
CREATE VIEW m35_reference.policy_members_deployed AS
SELECT customer_id FROM m35_reference.policy_members_current;

DO $m35$
DECLARE
    current_declaration pgreact_api.declaration;
    proposed_declaration pgreact_api.declaration;
    rls_declaration pgreact_api.declaration;
    deployed jsonb;
    comparison jsonb;
    changes jsonb;
    before_checksum text;
    after_checksum text;
    source_before text;
    source_after text;
    result_digest text;
    projected_rows jsonb;
    decision_declaration pgreact_api.declaration;
    decision_proposal pgreact_api.declaration;
    policy_declaration pgreact_api.declaration;
    policy_proposal pgreact_api.declaration;
    policy_member_declaration pgreact_api.declaration;
    decision_comparison jsonb;
    policy_comparison jsonb;
BEGIN
    current_declaration := pgreact.rule(
        'm35-order-rule', 'm35_reference.orders_deployed'::regclass, 'order_id'::name);
    proposed_declaration := pgreact.rule(
        'm35-order-rule', 'm35_reference.orders_hypothetical'::regclass, 'order_id'::name);
    deployed := pgreact.deploy(current_declaration, jsonb_build_object(
        'preview_digest', (pgreact.preview(current_declaration) -> 'summary' ->> 'preview_digest')));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M35 fixture deployment failed: %', deployed;
    END IF;
    PERFORM pgreact.run('2026-08-27 09:00:00+00');

    changes := jsonb_build_array(
        jsonb_build_object(
            'relation', 'm35_reference.orders_hypothetical',
            'operation', 'INSERT',
            'ordinal', 1,
            'key', jsonb_build_object('order_id', 3),
            'before', 'null'::jsonb,
            'after', jsonb_build_object('order_id', 3, 'status', 'review', 'amount', 300)),
        jsonb_build_object(
            'relation', 'm35_reference.orders_hypothetical',
            'operation', 'UPDATE',
            'ordinal', 2,
            'key', jsonb_build_object('order_id', 1),
            'before', jsonb_build_object('order_id', 1, 'status', 'review', 'amount', 100),
            'after', jsonb_build_object('order_id', 1, 'status', 'approved', 'amount', 100)),
        jsonb_build_object(
            'relation', 'm35_reference.orders_hypothetical',
            'operation', 'DELETE',
            'ordinal', 3,
            'key', jsonb_build_object('order_id', 2),
            'before', jsonb_build_object('order_id', 2, 'status', 'review', 'amount', 200),
            'after', 'null'::jsonb));

    before_checksum := pgreact_internal.m34_authoritative_checksum();
    source_before := pgreact_internal.m35_source_checksum(
        'm35_reference.orders_hypothetical'::regclass, 'order_id'::name);
    comparison := pgreact.compare(
        proposed_declaration,
        pgreact_api.target('rule', 'm35-order-rule'),
        changes,
        jsonb_build_object('evidence_limit', 10));
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    source_after := pgreact_internal.m35_source_checksum(
        'm35_reference.orders_hypothetical'::regclass, 'order_id'::name);
    IF comparison ->> 'contract_version' <> '22'
       OR comparison ->> 'simulation' <> 'hypothetical_fact_changes'
       OR comparison ->> 'state' <> 'ready'
       OR comparison -> 'summary' ->> 'current_count' <> '3'
       OR comparison -> 'summary' ->> 'proposed_count' <> '3'
       OR comparison -> 'summary' ->> 'hypothetical_change_count' <> '3'
       OR comparison -> 'proposed' IS DISTINCT FROM jsonb_build_array(
          jsonb_build_object(
              'subject_key', '1', 'result_key', '1', 'state', 'MATCH',
              'value', jsonb_build_object('order_id', 1, 'status', 'approved', 'amount', 100),
              'work', jsonb_build_object('would_be_work', true),
              'evidence', jsonb_build_object(
                  'source', 'm35_reference.orders_hypothetical',
                  'hypothetical', true, 'complete', true)),
          jsonb_build_object(
              'subject_key', '3', 'result_key', '3', 'state', 'MATCH',
              'value', jsonb_build_object('order_id', 3, 'status', 'review', 'amount', 300),
              'work', jsonb_build_object('would_be_work', true),
              'evidence', jsonb_build_object(
                  'source', 'm35_reference.orders_hypothetical',
                  'hypothetical', true, 'complete', true)),
          jsonb_build_object(
              'subject_key', '4', 'result_key', '4', 'state', 'MATCH',
              'value', jsonb_build_object('order_id', 4, 'status', 'review', 'amount', 400),
              'work', jsonb_build_object('would_be_work', true),
              'evidence', jsonb_build_object(
                  'source', 'm35_reference.orders_hypothetical',
                  'hypothetical', true, 'complete', true)))
       OR comparison -> 'summary' -> 'delta_counts' IS DISTINCT FROM
          jsonb_build_object('added', 1, 'removed', 1, 'changed', 1, 'unchanged', 1)
       OR comparison -> 'evidence' ->> 'complete' <> 'true'
       OR comparison -> 'evidence' -> 'changed_facts' IS DISTINCT FROM changes
       OR comparison -> 'snapshot' ->> 'source_checksum_before' <> source_before
       OR comparison -> 'snapshot' ->> 'source_checksum_after' <> source_after
       OR before_checksum <> after_checksum
       OR source_before <> source_after
       OR NOT (comparison -> 'findings' @> jsonb_build_array(
           jsonb_build_object('code', 'M35_NO_EFFECT')))
    THEN
        RAISE EXCEPTION 'M35 complete simulation mismatch: %', comparison;
    END IF;
    result_digest := comparison -> 'evidence' ->> 'change_set_digest';

    SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.order_id)
    INTO projected_rows
    FROM m35_reference.orders_hypothetical row_data;
    IF projected_rows IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('order_id', 1, 'status', 'review', 'amount', 100),
        jsonb_build_object('order_id', 2, 'status', 'review', 'amount', 200),
        jsonb_build_object('order_id', 4, 'status', 'review', 'amount', 400))
    THEN
        RAISE EXCEPTION 'M35 simulation changed source rows: %', projected_rows;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pgreact.compare_results(
            proposed_declaration,
            pgreact_api.target('rule', 'm35-order-rule'),
            changes,
            jsonb_build_object('evidence_limit', 10)) result_row
        WHERE result_row.result_set = 'delta'
          AND result_row.subject_key = '3'
          AND result_row.delta = 'ADDED'
          AND result_row.change_set_digest = result_digest
          AND result_row.source_checksum_before = source_before
          AND result_row.source_checksum_after = source_after
    ) THEN
        RAISE EXCEPTION 'M35 relational result did not expose the exact added row';
    END IF;

    comparison := pgreact.compare(
        proposed_declaration,
        pgreact_api.target('rule', 'm35-order-rule'),
        changes,
        jsonb_build_object('evidence_limit', 1));
    IF comparison ->> 'state' <> 'partial'
       OR comparison ->> 'truncated' <> 'true'
       OR comparison -> 'summary' ->> 'counts_exact' <> 'false'
       OR comparison -> 'summary' ->> 'delta_counts' IS NOT NULL
       OR NOT (comparison -> 'findings' @> jsonb_build_array(
           jsonb_build_object('code', 'M35_COMPARISON_INCOMPLETE')))
    THEN
        RAISE EXCEPTION 'M35 partial result mismatch: %', comparison;
    END IF;

    before_checksum := pgreact_internal.m34_authoritative_checksum();
    BEGIN
        PERFORM pgreact.compare(
            proposed_declaration,
            pgreact_api.target('rule', 'm35-order-rule'),
            jsonb_build_array(jsonb_build_object(
                'relation', 'm35_reference.orders_hypothetical',
                'operation', 'UPDATE',
                'ordinal', 1,
                'key', jsonb_build_object('order_id', 1),
                'before', jsonb_build_object('order_id', 1, 'status', 'wrong', 'amount', 100),
                'after', jsonb_build_object('order_id', 1, 'status', 'approved', 'amount', 100))),
            '{}'::jsonb);
        RAISE EXCEPTION 'M35 stale change unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF position('M35_CHANGE_STALE' IN SQLERRM) = 0 THEN
            RAISE;
        END IF;
    END;
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF before_checksum <> after_checksum THEN
        RAISE EXCEPTION 'M35 stale validation changed authoritative state';
    END IF;

    decision_declaration := pgreact.decision(
        'm35-decision', 'm35_reference.candidates_deployed'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['result']::name[], '2026-01-01 00:00:00+00');
    decision_proposal := pgreact.decision(
        'm35-decision', 'm35_reference.candidates_hypothetical'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['result']::name[], '2026-01-01 00:00:00+00');
    deployed := pgreact.deploy(decision_declaration, jsonb_build_object(
        'preview_digest', (pgreact.preview(decision_declaration) -> 'summary' ->> 'preview_digest')));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M35 decision fixture deployment failed: %', deployed;
    END IF;
    PERFORM pgreact.run('2026-08-27 09:00:01+00');
    decision_comparison := pgreact.compare(
        decision_proposal,
        pgreact_api.target('decision_program', 'm35-decision'),
        jsonb_build_array(
            jsonb_build_object(
                'relation', 'm35_reference.candidates_hypothetical', 'operation', 'UPDATE',
                'ordinal', 1, 'key', jsonb_build_object('candidate_id', 100),
                'before', jsonb_build_object('subject_id', 10, 'candidate_id', 100,
                                              'priority', 1, 'result', 'approve'),
                'after', jsonb_build_object('subject_id', 10, 'candidate_id', 100,
                                             'priority', 0, 'result', 'approve')),
            jsonb_build_object(
                'relation', 'm35_reference.candidates_hypothetical', 'operation', 'INSERT',
                'ordinal', 2, 'key', jsonb_build_object('candidate_id', 300),
                'before', 'null'::jsonb,
                'after', jsonb_build_object('subject_id', 30, 'candidate_id', 300,
                                             'priority', 1, 'result', 'approve'))),
        jsonb_build_object('evidence_limit', 10));
    IF decision_comparison ->> 'state' <> 'ready'
       OR decision_comparison -> 'summary' -> 'delta_counts' IS DISTINCT FROM
          jsonb_build_object('added', 1, 'removed', 0, 'changed', 1, 'unchanged', 1)
       OR decision_comparison -> 'evidence' ->> 'complete' <> 'true'
    THEN
        RAISE EXCEPTION 'M35 decision simulation mismatch: %', decision_comparison;
    END IF;

    policy_member_declaration := pgreact.rule(
        'm35-policy-member', 'm35_reference.policy_members_deployed'::regclass,
        'customer_id'::name);
    deployed := pgreact.deploy(policy_member_declaration, jsonb_build_object(
        'preview_digest', (pgreact.preview(policy_member_declaration) -> 'summary' ->> 'preview_digest')));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M35 policy member deployment failed: %', deployed;
    END IF;
    PERFORM pgreact.run('2026-08-27 09:00:02+00');
    policy_declaration := pgreact.policy_set(
        'm35-customers', '1', ARRAY[policy_member_declaration],
        'm35_reference.customers_current'::regclass,
        ARRAY['customer_id']::name[], '2026-01-01 00:00:00+00');
    policy_proposal := pgreact.policy_set(
        'm35-customers', '2', ARRAY[policy_member_declaration],
        'm35_reference.customers_hypothetical'::regclass,
        ARRAY['customer_id']::name[], '2026-01-01 00:00:00+00');
    deployed := pgreact.deploy(policy_declaration, jsonb_build_object(
        'preview_digest', (pgreact.preview(policy_declaration) -> 'summary' ->> 'preview_digest')));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M35 policy fixture deployment failed: %', deployed;
    END IF;
    PERFORM pgreact.run('2026-08-27 09:00:02+00');
    policy_comparison := pgreact.compare(
        policy_proposal,
        pgreact_api.target('policy_set', 'm35-customers', '1'),
        jsonb_build_array(
            jsonb_build_object(
                'relation', 'm35_reference.customers_hypothetical', 'operation', 'INSERT',
                'ordinal', 1, 'key', jsonb_build_object('customer_id', 30),
                'before', 'null'::jsonb,
                'after', jsonb_build_object('customer_id', 30)),
            jsonb_build_object(
                'relation', 'm35_reference.customers_hypothetical', 'operation', 'DELETE',
                'ordinal', 2, 'key', jsonb_build_object('customer_id', 20),
                'before', jsonb_build_object('customer_id', 20),
                'after', 'null'::jsonb)),
        jsonb_build_object('evidence_limit', 10));
    IF policy_comparison ->> 'state' <> 'ready'
       OR policy_comparison -> 'summary' -> 'delta_counts' IS DISTINCT FROM
          jsonb_build_object('added', 1, 'removed', 1, 'changed', 0, 'unchanged', 2)
       OR policy_comparison -> 'evidence' ->> 'complete' <> 'true'
    THEN
        RAISE EXCEPTION 'M35 policy simulation mismatch: %', policy_comparison;
    END IF;

    BEGIN
        PERFORM pgreact.compare(
            proposed_declaration,
            pgreact_api.target('rule', 'm35-order-rule'),
            jsonb_build_array(
                jsonb_build_object(
                    'relation', 'm35_reference.orders_hypothetical', 'operation', 'INSERT',
                    'ordinal', 1, 'key', jsonb_build_object('order_id', 3),
                    'before', 'null'::jsonb,
                    'after', jsonb_build_object('order_id', 3, 'status', 'review', 'amount', 300)),
                jsonb_build_object(
                    'relation', 'm35_reference.orders_hypothetical', 'operation', 'INSERT',
                    'ordinal', 1, 'key', jsonb_build_object('order_id', 5),
                    'before', 'null'::jsonb,
                    'after', jsonb_build_object('order_id', 5, 'status', 'review', 'amount', 500))),
            '{}'::jsonb);
        RAISE EXCEPTION 'M35 duplicate ordinal unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF position('M35_CHANGE_DUPLICATE' IN SQLERRM) = 0 THEN
            RAISE;
        END IF;
    END;

    rls_declaration := pgreact.rule(
        'm35-order-rule', 'm35_reference.rls_orders'::regclass, 'order_id'::name);
    BEGIN
        PERFORM pgreact.compare(
            rls_declaration,
            pgreact_api.target('rule', 'm35-order-rule'),
            '[]'::jsonb,
            '{}'::jsonb);
        RAISE EXCEPTION 'M35 RLS source unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF position('M35_RLS_UNSUPPORTED' IN SQLERRM) = 0 THEN
            RAISE;
        END IF;
    END;

    IF jsonb_array_length(pgreact_internal.m35_finding_registry() -> 'codes') <> 18 THEN
        RAISE EXCEPTION 'M35 finding registry is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgreact'
          AND p.prosecdef
          AND NOT (COALESCE(p.proconfig, ARRAY[]::text[]) @>
                   ARRAY['search_path=pg_catalog, pg_temp'])
    ) THEN
        RAISE EXCEPTION 'M35 public SECURITY DEFINER routine has unsafe search_path';
    END IF;
END
$m35$;

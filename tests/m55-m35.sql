\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m55_m35_reference;
CREATE TABLE m55_m35_reference.current_rows (
    order_id bigint PRIMARY KEY,
    status text NOT NULL
);
INSERT INTO m55_m35_reference.current_rows VALUES (1, 'review'), (2, 'review');
CREATE VIEW m55_m35_reference.deployed AS
    SELECT order_id, status FROM m55_m35_reference.current_rows;
CREATE TABLE m55_m35_reference.proposed_rows (
    order_id bigint PRIMARY KEY,
    status text NOT NULL
);
INSERT INTO m55_m35_reference.proposed_rows
SELECT * FROM m55_m35_reference.current_rows;

DO $m55$
DECLARE declaration pgreact_api.declaration;
    proposed pgreact_api.declaration;
    deployed jsonb;
    changes jsonb;
    comparison jsonb;
    before_checksum text;
    after_checksum text;
    source_checksum text;
BEGIN
    declaration := pgreact.rule(
        'm55-m35-rule', 'm55_m35_reference.deployed'::regclass, 'order_id');
    proposed := pgreact.rule(
        'm55-m35-rule', 'm55_m35_reference.proposed_rows'::regclass, 'order_id');
    deployed := pgreact.deploy(declaration, jsonb_build_object(
        'preview_digest', pgreact.preview(declaration) -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M55 M35 fixture deployment failed: %', deployed;
    END IF;
    PERFORM pgreact.run('2026-09-09 09:00:00+00');
    changes := jsonb_build_array(jsonb_build_object(
        'relation', 'm55_m35_reference.proposed_rows',
        'operation', 'UPDATE',
        'ordinal', 1,
        'key', jsonb_build_object('order_id', 1),
        'before', jsonb_build_object('order_id', 1, 'status', 'review'),
        'after', jsonb_build_object('order_id', 1, 'status', 'approved')));
    before_checksum := pgreact_internal.m34_authoritative_checksum();
    source_checksum := pgreact_internal.m35_source_checksum(
        'm55_m35_reference.proposed_rows'::regclass, 'order_id');
    comparison := pgreact.compare(
        proposed, pgreact_api.target('rule', 'm55-m35-rule'), changes,
        jsonb_build_object('evidence_limit', 10));
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF comparison ->> 'contract_version' <> '55'
       OR comparison ->> 'simulation' <> 'hypothetical_fact_changes'
       OR comparison ->> 'state' <> 'ready'
       OR comparison -> 'summary' -> 'delta_counts' IS DISTINCT FROM
          jsonb_build_object('added', 0, 'removed', 0, 'changed', 1, 'unchanged', 1)
       OR comparison -> 'snapshot' ->> 'source_checksum_before' <> source_checksum
       OR comparison -> 'snapshot' ->> 'source_checksum_after' <> source_checksum
       OR comparison -> 'snapshot' ->> 'authoritative_checksum_before' IS NULL
       OR comparison -> 'snapshot' -> 'provenance' ->> 'scope' <> 'target'
       OR comparison -> 'snapshot' -> 'provenance' ->> 'before' IS NULL
       OR before_checksum <> after_checksum
    THEN
        RAISE EXCEPTION 'M55 M35 comparison mismatch: %', comparison;
    END IF;
END
$m55$;

SELECT 'M55 four-argument comparison passed' AS result;

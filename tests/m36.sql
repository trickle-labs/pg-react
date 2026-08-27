\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m36_reference;
CREATE TABLE m36_reference.orders (
    order_id bigint PRIMARY KEY,
    status text NOT NULL,
    amount bigint NOT NULL
);
INSERT INTO m36_reference.orders VALUES
    (1, 'review', 100), (2, 'review', 200);
CREATE VIEW m36_reference.orders_deployed AS
SELECT order_id, status, amount FROM m36_reference.orders;

DO $m36$
DECLARE
    declaration pgreact_api.declaration;
    replay_declaration pgreact_api.declaration;
    deployed jsonb;
    snapshot jsonb;
    steps jsonb;
    replay jsonb;
    before_checksum text;
    after_checksum text;
    expected_replay_digest text;
BEGIN
    declaration := pgreact.rule(
        'm36-order-rule', 'm36_reference.orders_deployed'::regclass, 'order_id'::name);
    replay_declaration := pgreact.rule(
        'm36-order-rule', 'm36_reference.orders'::regclass, 'order_id'::name);
    deployed := pgreact.deploy(declaration, jsonb_build_object(
        'preview_digest', (pgreact.preview(declaration) -> 'summary' ->> 'preview_digest')));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M36 fixture deployment failed: %', deployed;
    END IF;
    PERFORM pgreact.run('2026-08-27 09:00:00+00');

    snapshot := jsonb_build_object(
        'relations', jsonb_build_array(jsonb_build_object(
            'relation', 'm36_reference.orders',
            'schema_fingerprint', pgreact_internal.m36_schema_fingerprint(
                'm36_reference.orders'::regclass),
            'rows', jsonb_build_array(
                jsonb_build_object('order_id', 1, 'status', 'review', 'amount', 100),
                jsonb_build_object('order_id', 2, 'status', 'review', 'amount', 200)))),
        'source_frontier', '2026-08-27 09:00:00+00',
        'sampled_time', '2026-08-27 09:00:00+00',
        'event_time_watermark', '2026-08-27 09:00:00+00');
    steps := jsonb_build_array(
        jsonb_build_object(
            'ordinal', 1,
            'source_frontier', '2026-08-27 09:00:01+00',
            'sampled_time', '2026-08-27 09:00:01+00',
            'event_time_watermark', '2026-08-27 09:00:01+00',
            'change_set', jsonb_build_array(jsonb_build_object(
                'relation', 'm36_reference.orders', 'operation', 'INSERT', 'ordinal', 1,
                'key', jsonb_build_object('order_id', 3),
                'before', 'null'::jsonb,
                'after', jsonb_build_object('order_id', 3, 'status', 'review', 'amount', 300)))),
        jsonb_build_object(
            'ordinal', 2,
            'source_frontier', '2026-08-27 09:00:02+00',
            'sampled_time', '2026-08-27 09:00:02+00',
            'event_time_watermark', '2026-08-27 09:00:02+00',
            'change_set', jsonb_build_array(jsonb_build_object(
                'relation', 'm36_reference.orders', 'operation', 'UPDATE', 'ordinal', 1,
                'key', jsonb_build_object('order_id', 1),
                'before', jsonb_build_object('order_id', 1, 'status', 'review', 'amount', 100),
                'after', jsonb_build_object('order_id', 1, 'status', 'approved', 'amount', 100)))),
        jsonb_build_object(
            'ordinal', 3,
            'source_frontier', '2026-08-27 09:00:03+00',
            'sampled_time', '2026-08-27 09:00:03+00',
            'event_time_watermark', '2026-08-27 09:00:03+00',
            'change_set', '[]'::jsonb,
            'final', true));

    before_checksum := pgreact_internal.m34_authoritative_checksum();
    replay := pgreact.replay(
        replay_declaration,
        pgreact_api.target('rule', 'm36-order-rule'),
        snapshot,
        steps,
        jsonb_build_object('evidence_limit', 10));
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF replay ->> 'contract_version' <> '23'
       OR replay ->> 'simulation' <> 'historical_replay'
       OR replay ->> 'state' <> 'ready'
       OR replay -> 'summary' IS DISTINCT FROM jsonb_build_object(
           'read_only', true,
           'initial_row_count', 2,
           'replay_step_count', 3,
           'replay_change_count', 2,
           'final_row_count', 3,
           'counts_exact', true,
           'affected_subject_count', 2)
       OR replay -> 'initial' -> 'rows' IS DISTINCT FROM jsonb_build_array(
           jsonb_build_object(
               'subject_key', '1', 'result_key', '1', 'state', 'MATCH',
               'value', jsonb_build_object('order_id', 1, 'status', 'review', 'amount', 100),
               'work', jsonb_build_object('would_be_work', true),
               'evidence', jsonb_build_object(
                   'source', 'm36_reference.orders', 'hypothetical', true, 'complete', true)),
           jsonb_build_object(
               'subject_key', '2', 'result_key', '2', 'state', 'MATCH',
               'value', jsonb_build_object('order_id', 2, 'status', 'review', 'amount', 200),
               'work', jsonb_build_object('would_be_work', true),
               'evidence', jsonb_build_object(
                   'source', 'm36_reference.orders', 'hypothetical', true, 'complete', true)))
       OR replay -> 'steps' -> 0 -> 'delta' -> 2 ->> 'change' <> 'ADDED'
       OR replay -> 'steps' -> 1 -> 'delta' -> 0 ->> 'change' <> 'CHANGED'
       OR replay -> 'steps' -> 2 -> 'delta' -> 0 ->> 'change' <> 'UNCHANGED'
       OR replay -> 'final' -> 'rows' IS DISTINCT FROM
          replay -> 'steps' -> 2 -> 'rows'
       OR replay -> 'evidence' ->> 'complete' <> 'true'
       OR replay -> 'findings' <> jsonb_build_array(jsonb_build_object(
           'code', 'M36_NO_EFFECT', 'severity', 'INFO', 'blocking', false,
           'target', 'm36-order-rule', 'field', '<replay>',
           'message', 'historical replay completed without changing source or pg-react state',
           'hint', 'Apply reviewed production changes separately if you want to change data.',
           'details', '{}'::jsonb))
       OR before_checksum <> after_checksum THEN
        RAISE EXCEPTION 'M36 complete replay mismatch: %', replay;
    END IF;
    expected_replay_digest := replay -> 'evidence' ->> 'replay_digest';
    IF NOT EXISTS (
        SELECT 1
        FROM pgreact.replay_results(
            replay_declaration,
            pgreact_api.target('rule', 'm36-order-rule'),
            snapshot,
            steps,
            jsonb_build_object('evidence_limit', 10)) result_row
        WHERE result_row.result_set = 'delta'
          AND result_row.step_ordinal = 1
          AND result_row.delta = 'ADDED'
          AND result_row.replay_digest = expected_replay_digest
          AND (result_row.current_value IS NULL OR result_row.current_value = 'null'::jsonb)
          AND result_row.proposed_value IS NOT DISTINCT FROM
              jsonb_build_object('order_id', 3, 'status', 'review', 'amount', 300)
    ) THEN
        RAISE EXCEPTION 'M36 relational result did not expose the exact added row';
    END IF;

    IF (SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.order_id)
        FROM m36_reference.orders row_data) IS DISTINCT FROM jsonb_build_array(
            jsonb_build_object('order_id', 1, 'status', 'review', 'amount', 100),
            jsonb_build_object('order_id', 2, 'status', 'review', 'amount', 200)) THEN
        RAISE EXCEPTION 'M36 replay changed source rows';
    END IF;

    BEGIN
        PERFORM pgreact.replay(
            replay_declaration,
            pgreact_api.target('rule', 'm36-order-rule'),
            snapshot,
            jsonb_build_array(jsonb_build_object(
                'ordinal', 1,
                'source_frontier', '2026-08-27 09:00:01+00',
                'sampled_time', '2026-08-27 09:00:01+00',
                'event_time_watermark', '2026-08-27 09:00:01+00',
                'change_set', jsonb_build_array(jsonb_build_object(
                    'relation', 'm36_reference.orders', 'operation', 'UPDATE', 'ordinal', 1,
                    'key', jsonb_build_object('order_id', 1),
                    'before', jsonb_build_object('order_id', 1, 'status', 'wrong', 'amount', 100),
                    'after', jsonb_build_object('order_id', 1, 'status', 'approved', 'amount', 100))))),
            '{}'::jsonb);
        RAISE EXCEPTION 'M36 stale replay unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF position('M36_REPLAY_STALE' IN SQLERRM) = 0 THEN
            RAISE;
        END IF;
    END;

    BEGIN
        PERFORM pgreact.replay(
            replay_declaration,
            pgreact_api.target('rule', 'm36-order-rule'),
            snapshot,
            jsonb_build_array(
                jsonb_build_object(
                    'ordinal', 2, 'source_frontier', '2026-08-27 09:00:02+00',
                    'sampled_time', '2026-08-27 09:00:02+00',
                    'event_time_watermark', '2026-08-27 09:00:02+00', 'change_set', '[]'::jsonb),
                jsonb_build_object(
                    'ordinal', 1, 'source_frontier', '2026-08-27 09:00:03+00',
                    'sampled_time', '2026-08-27 09:00:03+00',
                    'event_time_watermark', '2026-08-27 09:00:03+00', 'change_set', '[]'::jsonb)),
            '{}'::jsonb);
        RAISE EXCEPTION 'M36 nonmonotone replay unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF position('M36_REPLAY_NONMONOTONE' IN SQLERRM) = 0 THEN
            RAISE;
        END IF;
    END;

    IF jsonb_array_length(pgreact_internal.m36_finding_registry() -> 'codes') <> 28 THEN
        RAISE EXCEPTION 'M36 finding registry is incomplete';
    END IF;
END
$m36$;

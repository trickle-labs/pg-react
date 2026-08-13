\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE TEMP TABLE m17_before_late AS SELECT jsonb_build_object(
    'corrections',(SELECT jsonb_agg(to_jsonb(correction) ORDER BY correction_order)
                   FROM pgreact_internal.window_corrections correction),
    'lifecycle',(SELECT jsonb_agg(to_jsonb(event) ORDER BY lifecycle_order)
                 FROM pgreact_internal.window_lifecycle event),
    'evidence',(SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name,window_ordinal)
                FROM pgreact.window_evidence evidence),
    'finalizations',(SELECT jsonb_agg(to_jsonb(finalization) ORDER BY lateness_boundary)
                     FROM pgreact_internal.window_finalizations finalization)) AS state;
INSERT INTO m17_reference.items VALUES (8,7,1,'1970-01-01T01:45:00Z');
SET SESSION AUTHORIZATION m17_operator;
DO $$
DECLARE result jsonb;
BEGIN
    result := pgreact_api.run();
    IF result -> 'windows' IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'program','m17.reference','maintenance','late'))
       OR result -> 'programs' IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'program','m17.reference','frontier',10)) THEN
        RAISE EXCEPTION 'M17 finalized-input run result changed: %',result;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'program',jsonb_build_object(
            'lower_frontier',lower_frontier,'observed_frontier',observed_frontier,
            'barrier',barrier,'requested',requested_watermark,'complete',complete_watermark),
        'diagnostic',(SELECT jsonb_build_object(
            'contract_version',contract_version,'code',code,'severity',severity,
            'object_identity',object_identity,'sqlstate',sqlstate,'message',message,
            'hint',hint,'details',details)
            FROM pgreact_internal.window_diagnostics
            WHERE code='M17_INPUT_FINALIZED' ORDER BY diagnostic_order DESC LIMIT 1),
        'durable_state',jsonb_build_object(
            'corrections',(SELECT jsonb_agg(to_jsonb(correction) ORDER BY correction_order)
                           FROM pgreact_internal.window_corrections correction),
            'lifecycle',(SELECT jsonb_agg(to_jsonb(event) ORDER BY lifecycle_order)
                         FROM pgreact_internal.window_lifecycle event),
            'evidence',(SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name,window_ordinal)
                        FROM pgreact.window_evidence evidence),
            'finalizations',(SELECT jsonb_agg(to_jsonb(finalization) ORDER BY lateness_boundary)
                             FROM pgreact_internal.window_finalizations finalization)))
    INTO actual FROM pgreact_internal.window_programs WHERE active;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'program',jsonb_build_object(
            'lower_frontier',9,'observed_frontier',10,'barrier','LATE_INPUT',
            'requested','1970-01-01T03:15:00Z'::timestamptz,
            'complete','1970-01-01T03:15:00Z'::timestamptz),
        'diagnostic',jsonb_build_object(
            'contract_version',6,'code','M17_INPUT_FINALIZED','severity','ERROR',
            'object_identity','m17.reference/m17_reference.item_source.occurred_at',
            'sqlstate','55000','message','timed input changed finalized window [7,1]',
            'hint','Restore the authoritative input to the finalized aggregate, then reconcile the program.',
            'details',jsonb_build_object(
                'complete_watermark','1970-01-01T03:15:00.000000Z',
                'event_time','1970-01-01T01:45:00.000000Z',
                'lateness_boundary','1970-01-01T02:15:00.000000Z',
                'lower_frontier',10,'window_key',jsonb_build_array(7,1))),
        'durable_state',(SELECT state FROM m17_before_late)) THEN
        RAISE EXCEPTION 'M17 finalized-input barrier or rollback changed: %',actual;
    END IF;
END
$$;
SET SESSION AUTHORIZATION m17_operator;
DO $$
DECLARE mismatch_message text;
BEGIN
    BEGIN
        PERFORM pgreact_api.reconcile_program('m17.reference');
    EXCEPTION WHEN SQLSTATE '55000' THEN GET STACKED DIAGNOSTICS mismatch_message = MESSAGE_TEXT;
    END;
    IF mismatch_message <> 'M17_LATE_INPUT_UNRESOLVED: authoritative input still differs from finalized state' THEN
        RAISE EXCEPTION 'M17 unresolved reconciliation diagnostic changed: %',mismatch_message;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

DELETE FROM m17_reference.items WHERE item_id=8;
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.reconcile_program('m17.reference');
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'lower_frontier',lower_frontier,'observed_frontier',observed_frontier,
        'barrier',barrier,
        'durable_state',jsonb_build_object(
            'corrections',(SELECT jsonb_agg(to_jsonb(correction) ORDER BY correction_order)
                           FROM pgreact_internal.window_corrections correction),
            'lifecycle',(SELECT jsonb_agg(to_jsonb(event) ORDER BY lifecycle_order)
                         FROM pgreact_internal.window_lifecycle event),
            'evidence',(SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name,window_ordinal)
                        FROM pgreact.window_evidence evidence),
            'finalizations',(SELECT jsonb_agg(to_jsonb(finalization) ORDER BY lateness_boundary)
                             FROM pgreact_internal.window_finalizations finalization)),
        'audit',(SELECT jsonb_build_object('operation',operation,'details',details)
                 FROM pgreact_internal.window_audits
                 WHERE operation='LATE_INPUT_REPAIRED' ORDER BY audit_order DESC LIMIT 1))
    INTO actual FROM pgreact_internal.window_programs WHERE active;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'lower_frontier',11,'observed_frontier',11,'barrier',NULL,
        'durable_state',jsonb_set(
            (SELECT state FROM m17_before_late),
            '{evidence}',
            (SELECT jsonb_agg(jsonb_set(value,'{program_lower_frontier}','11'::jsonb)
                              ORDER BY ordinal)
             FROM jsonb_array_elements((SELECT state -> 'evidence' FROM m17_before_late))
                  WITH ORDINALITY AS evidence(value,ordinal))),
        'audit',jsonb_build_object('operation','LATE_INPUT_REPAIRED',
                                   'details',jsonb_build_object('program','m17.reference'))) THEN
        RAISE EXCEPTION 'M17 F11 reconciliation changed state or history: %',actual;
    END IF;
END
$$;

BEGIN;
UPDATE pgreact_internal.window_programs SET barrier='LATE_INPUT' WHERE active;
DELETE FROM pgreact_internal.window_finalizations
WHERE finalization_identity='[7,0]@1970-01-01T01:15:00.000000Z';
SET SESSION AUTHORIZATION m17_operator;
DO $$
DECLARE message text;
BEGIN
    BEGIN
        PERFORM pgreact_api.reconcile_program('m17.reference');
    EXCEPTION WHEN SQLSTATE '55000' THEN GET STACKED DIAGNOSTICS message = MESSAGE_TEXT;
    END;
    IF message <> 'M17_HISTORY_UNRECOVERABLE: correction or finalization identity is missing' THEN
        RAISE EXCEPTION 'M17 unrecoverable-history diagnostic changed: %',message;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
ROLLBACK;

CREATE TEMP TABLE m17_before_prune AS
SELECT jsonb_agg(to_jsonb(correction) ORDER BY correction_order) AS corrections,
       (SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name,window_ordinal)
        FROM pgreact.window_evidence evidence) AS evidence
FROM pgreact_internal.window_corrections correction;
SET SESSION AUTHORIZATION m17_operator;
DO $$
DECLARE first_result record; repeat_result record; invalid_message text;
BEGIN
    SELECT * INTO STRICT first_result
    FROM pgreact_api.prune_window_history('m17.reference','1970-01-01T01:15:00Z');
    SELECT * INTO STRICT repeat_result
    FROM pgreact_api.prune_window_history('m17.reference','1970-01-01T01:15:00Z');
    BEGIN
        PERFORM * FROM pgreact_api.window_corrections('m17.reference',0,NULL);
    EXCEPTION WHEN SQLSTATE '22023' THEN GET STACKED DIAGNOSTICS invalid_message = MESSAGE_TEXT;
    END;
    IF row(first_result.windows,first_result.corrections,first_result.blocked)
          IS DISTINCT FROM row(1::bigint,5::bigint,0::bigint)
       OR row(repeat_result.windows,repeat_result.corrections,repeat_result.blocked)
          IS DISTINCT FROM row(0::bigint,0::bigint,0::bigint)
       OR invalid_message <> 'M17_HISTORY_LIMIT: limit must be between 1 and 1000' THEN
        RAISE EXCEPTION 'M17 retention or history bound changed: %, %, %',
            first_result,repeat_result,invalid_message;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
DO $$
DECLARE removed text; retained text; actual jsonb;
BEGIN
    SELECT string_agg(value ->> 'correction_identity',E'\n'
                      ORDER BY value ->> 'rule_name')
    INTO removed
    FROM jsonb_array_elements((SELECT corrections FROM m17_before_prune)) AS before_value(value)
    WHERE NOT EXISTS (SELECT 1 FROM pgreact_internal.window_corrections current_value
                      WHERE current_value.correction_identity=value ->> 'correction_identity');
    SELECT string_agg(correction_identity,E'\n' ORDER BY rule_name)
    INTO retained FROM pgreact_internal.window_corrections
    WHERE public_window_key='[7,-1]'::jsonb;
    SELECT jsonb_build_object(
        'history_floor',history_floor,
        'evidence',(SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name,window_ordinal)
                    FROM pgreact.window_evidence evidence),
        'audit',(SELECT jsonb_build_object('operation',operation,'details',details)
                 FROM pgreact_internal.window_audits WHERE operation='PRUNE_WINDOW_HISTORY'
                 ORDER BY audit_order DESC LIMIT 1))
    INTO actual FROM pgreact_internal.window_programs WHERE active;
    IF removed IS DISTINCT FROM E'm17.reference@1/m17.count_all@1/[7,-1]/F1\nm17.reference@1/m17.count_amount@1/[7,-1]/F1\nm17.reference@1/m17.max_amount@1/[7,-1]/F1\nm17.reference@1/m17.min_amount@1/[7,-1]/F1\nm17.reference@1/m17.sum_amount@1/[7,-1]/F1'
       OR retained IS DISTINCT FROM E'm17.reference@1/m17.count_all@1/[7,-1]/F3\nm17.reference@1/m17.count_amount@1/[7,-1]/F3\nm17.reference@1/m17.max_amount@1/[7,-1]/F3\nm17.reference@1/m17.min_amount@1/[7,-1]/F3\nm17.reference@1/m17.sum_amount@1/[7,-1]/F3'
       OR actual IS DISTINCT FROM jsonb_build_object(
            'history_floor','1970-01-01T01:15:00Z'::timestamptz,
            'evidence',(SELECT evidence FROM m17_before_prune),
            'audit',jsonb_build_object('operation','PRUNE_WINDOW_HISTORY','details',jsonb_build_object(
                'cutoff','1970-01-01T01:15:00Z'::timestamptz,
                'windows',1,'corrections',5,'blocked',0))) THEN
        RAISE EXCEPTION 'M17 exact retained recovery horizon changed: %, %, %',removed,retained,actual;
    END IF;
END
$$;
SELECT 'M17 late correction, diagnostics, reconciliation, unrecoverable history, and retention passed';

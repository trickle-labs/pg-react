\set ON_ERROR_STOP on
BEGIN;
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.request_watermark(
    'm17.reference','m17_reference.item_source','occurred_at',:'target'::timestamptz);
SELECT pg_sleep(2);
COMMIT;

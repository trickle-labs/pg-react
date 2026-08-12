\set ON_ERROR_STOP on
ALTER EXTENSION pg_react UPDATE TO '0.11.0';

DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.doctor();
    IF actual -> 'contract_version' IS DISTINCT FROM '4'::jsonb
       OR actual -> 'status' IS DISTINCT FROM '"ready"'::jsonb THEN
        RAISE EXCEPTION 'M14 upgrade doctor changed: %', actual;
    END IF;
END
$$;

SELECT 'M14 populated 0.10.0 to 0.11.0 upgrade gate passed';


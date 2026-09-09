DO $v0440$
DECLARE expected jsonb := jsonb_build_object(
        'extension_version', '0.44.0',
        'target_provenance', true,
        'full_checksum_fallback', true,
        'one_pass_rule_validation', true,
        'comparison_contract', 'M38 wrapper preserved');
    observed jsonb;
BEGIN
    SELECT jsonb_build_object(
        'extension_version', (
            SELECT extversion FROM pg_extension WHERE extname = 'pg_react'),
        'target_provenance', position(
            'm55_target_provenance' IN pg_get_functiondef(
                'pgreact_internal.m34_authoritative_checksum()'::regprocedure)) > 0,
        'full_checksum_fallback', position(
            'm55_full_authoritative_checksum' IN pg_get_functiondef(
                'pgreact_internal.m34_authoritative_checksum()'::regprocedure)) > 0,
        'one_pass_rule_validation', position(
            'MATERIALIZED' IN pg_get_functiondef(
                'pgreact_internal.m34_rule_rows(oid,name,text,integer)'::regprocedure)) > 0,
        'comparison_contract', CASE WHEN position(
            'm38_annotate_compare' IN pg_get_functiondef(
                'pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)'::regprocedure)) > 0
            THEN 'M38 wrapper preserved' ELSE 'changed' END)
    INTO observed;
    IF observed IS DISTINCT FROM expected THEN
        RAISE EXCEPTION '0.44.0 runtime contract mismatch: expected %, observed %',
            expected, observed;
    END IF;
END
$v0440$;

SELECT 'v0.44.0 runtime contract passed' AS result;

\set ON_ERROR_STOP on

BEGIN;
SELECT pgreact.deploy_pack(
    manifest.definition,
    preview.plan_digest,
    manifest.mappings
)
FROM m5_fixture.manifests AS manifest
CROSS JOIN LATERAL (
    SELECT min(plan_digest) AS plan_digest
    FROM pgreact.preview_pack(manifest.definition, manifest.mappings)
) AS preview
WHERE manifest.version = '4';
SELECT pg_sleep(2);
COMMIT;

SELECT 'M5 held deployment committed' AS result;

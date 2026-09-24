\set ON_ERROR_STOP on
REASSIGN OWNED BY pgreact_mdm_worker TO postgres;
DROP OWNED BY pgreact_mdm_worker;
SELECT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_namespace AS namespace,
         LATERAL pg_catalog.aclexplode(namespace.nspacl) AS acl
    WHERE namespace.nspname = 'pgreact'
      AND acl.grantee = 'pgreact_mdm_worker'::regrole
      AND acl.grantor = 'mdm_helper_owner'::regrole
      AND acl.privilege_type = 'USAGE'
) AS v048_revoke_pgre_usage \gset
\if :v048_revoke_pgre_usage
SET ROLE mdm_helper_owner;
REVOKE USAGE ON SCHEMA pgreact FROM pgreact_mdm_worker;
RESET ROLE;
\endif
SELECT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_namespace AS namespace,
         LATERAL pg_catalog.aclexplode(namespace.nspacl) AS acl
    WHERE namespace.nspname = 'pgreact_mdm'
      AND acl.grantee = 'pgreact_mdm_worker'::regrole
      AND acl.grantor = 'mdm_helper_owner'::regrole
      AND acl.privilege_type = 'USAGE'
) AS v048_revoke_worker_usage \gset
\if :v048_revoke_worker_usage
SET ROLE mdm_helper_owner;
REVOKE USAGE ON SCHEMA pgreact_mdm FROM pgreact_mdm_worker;
RESET ROLE;
\endif
SELECT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_namespace AS namespace,
         LATERAL pg_catalog.aclexplode(namespace.nspacl) AS acl
    WHERE namespace.nspname = 'mdm_steward'
      AND acl.grantee = 'pgreact_mdm_worker'::regrole
      AND acl.grantor = 'mdm_helper_owner'::regrole
      AND acl.privilege_type = 'USAGE'
) AS v048_revoke_mdm_usage \gset
\if :v048_revoke_mdm_usage
SET ROLE mdm_helper_owner;
REVOKE USAGE ON SCHEMA mdm_steward FROM pgreact_mdm_worker;
RESET ROLE;
\endif

DO $install_guard_owner$
DECLARE guard_owner_oid oid;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = current_user AND rolsuper) THEN
        RAISE EXCEPTION 'PGREACT_MDM_RETENTION_DDL: provision the guard owner as a superuser';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'mdm_retention_guard_owner') THEN
        EXECUTE 'CREATE ROLE mdm_retention_guard_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS';
    END IF;

    SELECT oid INTO guard_owner_oid
    FROM pg_catalog.pg_roles
    WHERE rolname = 'mdm_retention_guard_owner';

    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE oid = guard_owner_oid
          AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole
               OR rolinherit OR rolreplication OR rolbypassrls))
       OR EXISTS (
        SELECT 1
        FROM pg_catalog.pg_auth_members
        WHERE roleid = guard_owner_oid OR member = guard_owner_oid) THEN
        RAISE EXCEPTION
            'PGREACT_MDM_RETENTION_DDL: guard owner role must remain isolated';
    END IF;
END
$install_guard_owner$;

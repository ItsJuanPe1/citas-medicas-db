-- =====================================================================
-- HU07 - PASO 1 (como SYSTEM / DBA). Se corre una sola vez.
--   * Roles ROLE_MEDICO y ROLE_RECEPCION
--   * Permiso para que PROYECTOPLSQL use DBMS_RLS
--   * Contexto de aplicacion CTX_CITAS (lo llena PKG_SEGURIDAD)
-- =====================================================================
alter session set "_ORACLE_SCRIPT"=true;

CREATE ROLE ROLE_MEDICO;
CREATE ROLE ROLE_RECEPCION;

GRANT EXECUTE_CATALOG_ROLE TO PROYECTOPLSQL;

CREATE OR REPLACE CONTEXT CTX_CITAS USING PROYECTOPLSQL.PKG_SEGURIDAD;

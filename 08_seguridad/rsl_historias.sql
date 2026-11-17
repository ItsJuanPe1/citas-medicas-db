-- =====================================================================
-- HU07 - PASO 3 (como PROYECTOPLSQL, despues de compilar PKG_SEGURIDAD).
-- Permisos por rol + politica DBMS_RLS sobre TBL_HISTORIA_CLINICA.
-- =====================================================================
-- Permisos de objeto (documentan el acceso de cada rol)
GRANT SELECT ON TBL_HISTORIA_CLINICA TO ROLE_MEDICO;
GRANT INSERT ON TBL_HISTORIA_CLINICA TO ROLE_MEDICO;
GRANT SELECT ON TBL_CITAS_MEDICAS    TO ROLE_MEDICO;
GRANT SELECT ON TBL_PACIENTES        TO ROLE_MEDICO;
GRANT SELECT ON TBL_AGENDAS_MEDICOS  TO ROLE_MEDICO;

GRANT SELECT, INSERT, UPDATE ON TBL_CITAS_MEDICAS   TO ROLE_RECEPCION;
GRANT SELECT, INSERT, UPDATE ON TBL_PACIENTES       TO ROLE_RECEPCION;
GRANT SELECT                 ON TBL_AGENDAS_MEDICOS TO ROLE_RECEPCION;
GRANT SELECT                 ON TBL_MEDICOS         TO ROLE_RECEPCION;
-- ROLE_RECEPCION NO recibe nada sobre TBL_HISTORIA_CLINICA.

-- Politica: se puede volver a correr
BEGIN
    DBMS_RLS.DROP_POLICY('PROYECTOPLSQL', 'TBL_HISTORIA_CLINICA', 'POL_HISTORIA_CLINICA');
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    DBMS_RLS.ADD_POLICY(
        object_schema   => 'PROYECTOPLSQL',
        object_name     => 'TBL_HISTORIA_CLINICA',
        policy_name     => 'POL_HISTORIA_CLINICA',
        function_schema => 'PROYECTOPLSQL',
        policy_function => 'PKG_SEGURIDAD.FN_POLITICA_HISTORIA',
        statement_types => 'SELECT',
        enable          => TRUE);
END;
/

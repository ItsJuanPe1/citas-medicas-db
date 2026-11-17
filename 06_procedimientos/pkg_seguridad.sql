-- =====================================================================
-- HU07: contexto de seguridad + funcion de la politica RLS de TBL_HISTORIA_CLINICA.
-- El back llama PRO_ESTABLECER_CONTEXTO en cada conexion que toma del pool.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_SEGURIDAD AS
    -- Guarda el rol, la entidad (id del medico/paciente) y el usuario de la peticion.
    -- pn_id_usuario lo usa TRG_HISTORIA_AUDITORIA (HU08) para saber quien hizo el cambio.
    PROCEDURE PRO_ESTABLECER_CONTEXTO(ps_rol VARCHAR2, pn_id_entidad NUMBER, pn_id_usuario NUMBER DEFAULT NULL);
    PROCEDURE PRO_LIMPIAR_CONTEXTO;
    -- Funcion de politica (DBMS_RLS): devuelve el filtro que se agrega a cada SELECT.
    FUNCTION FN_POLITICA_HISTORIA(ps_esquema VARCHAR2, ps_objeto VARCHAR2) RETURN VARCHAR2;
END PKG_SEGURIDAD;
/
CREATE OR REPLACE PACKAGE BODY PKG_SEGURIDAD AS

    PROCEDURE PRO_ESTABLECER_CONTEXTO(ps_rol VARCHAR2, pn_id_entidad NUMBER, pn_id_usuario NUMBER DEFAULT NULL) IS
    BEGIN
        DBMS_SESSION.SET_CONTEXT('CTX_CITAS', 'ROL', ps_rol);
        DBMS_SESSION.SET_CONTEXT('CTX_CITAS', 'ID_ENTIDAD', pn_id_entidad);
        DBMS_SESSION.SET_CONTEXT('CTX_CITAS', 'ID_USUARIO', pn_id_usuario);
    END PRO_ESTABLECER_CONTEXTO;

    PROCEDURE PRO_LIMPIAR_CONTEXTO IS
    BEGIN
        DBMS_SESSION.CLEAR_CONTEXT('CTX_CITAS');
    END PRO_LIMPIAR_CONTEXTO;

    FUNCTION FN_POLITICA_HISTORIA(ps_esquema VARCHAR2, ps_objeto VARCHAR2) RETURN VARCHAR2 IS
        vs_rol VARCHAR2(30) := SYS_CONTEXT('CTX_CITAS', 'ROL');
        vn_id  NUMBER       := TO_NUMBER(SYS_CONTEXT('CTX_CITAS', 'ID_ENTIDAD'));
    BEGIN
        IF vs_rol = 'MEDICO' THEN
            -- solo historias de citas que estan en SUS agendas (MEDICOS -> AGENDAS -> CITAS)
            IF vn_id IS NULL THEN RETURN '1 = 0'; END IF;
            RETURN 'ID_CITA IN (SELECT c.ID_CITA FROM ' || ps_esquema || '.TBL_CITAS_MEDICAS c'
                || ' JOIN ' || ps_esquema || '.TBL_AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA'
                || ' WHERE a.ID_MEDICO = ' || TO_CHAR(vn_id) || ')';
        ELSIF vs_rol = 'PACIENTE' THEN
            IF vn_id IS NULL THEN RETURN '1 = 0'; END IF;
            RETURN 'ID_CITA IN (SELECT c.ID_CITA FROM ' || ps_esquema || '.TBL_CITAS_MEDICAS c'
                || ' WHERE c.ID_PACIENTE = ' || TO_CHAR(vn_id) || ')';
        ELSIF vs_rol = 'RECEPCIONISTA' THEN
            RETURN '1 = 0';   -- recepcion no lee historias clinicas
        END IF;
        RETURN '1 = 1';       -- SUPERADMIN, GERENTE, FARMACEUTICO, jobs y scripts (sin contexto)
    END FN_POLITICA_HISTORIA;

END PKG_SEGURIDAD;
/
SHOW ERRORS

-- =====================================================================
-- PKG_HISTORIAS_CLINICAS  (HU03 registrar consulta; luego HU04, HU07, HU08)
-- No cambia tablas ni datos. Usa SEQ_HISTORIA_CLINICA y SEQ_LOG_AUDITORIAS.
-- Errores: rango 20101-20199.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_HISTORIAS_CLINICAS AS

    EXC_CITA_NO_EXISTE          EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CITA_NO_EXISTE,          -20101);
    EXC_CITA_NO_PROGRAMADA      EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CITA_NO_PROGRAMADA,      -20102);
    EXC_CITA_DE_OTRO_MEDICO     EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CITA_DE_OTRO_MEDICO,     -20103);
    EXC_DIAGNOSTICO_OBLIGATORIO EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_DIAGNOSTICO_OBLIGATORIO, -20104);
    EXC_TEXTO_MUY_LARGO         EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_TEXTO_MUY_LARGO,         -20105);

    -- HU03. Crea la historia clinica y marca la cita como ATENDIDA en la misma
    -- transaccion (un solo COMMIT). Si p_id_medico no es NULL, la cita debe ser de ese medico.
    PROCEDURE REGISTRAR_CONSULTA(
        p_id_cita     IN  NUMBER,
        p_diagnostico IN  VARCHAR2,
        p_notas       IN  VARCHAR2,
        p_id_usuario  IN  NUMBER,
        p_id_historia OUT NUMBER,
        p_id_medico   IN  NUMBER DEFAULT NULL
    );

END PKG_HISTORIAS_CLINICAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_HISTORIAS_CLINICAS AS

    FUNCTION id_param(p_nombre VARCHAR2, p_valor VARCHAR2) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        SELECT ID_PARAMETRO INTO v_id
          FROM PARAMETRICA_TIPOS
         WHERE NOMBRE = p_nombre AND VALOR = p_valor;
        RETURN v_id;
    END id_param;

    PROCEDURE REGISTRAR_CONSULTA(
        p_id_cita     IN  NUMBER,
        p_diagnostico IN  VARCHAR2,
        p_notas       IN  VARCHAR2,
        p_id_usuario  IN  NUMBER,
        p_id_historia OUT NUMBER,
        p_id_medico   IN  NUMBER DEFAULT NULL
    ) IS
        v_prog        NUMBER := id_param('ESTADO_CITA', 'PROGRAMADA');
        v_aten        NUMBER := id_param('ESTADO_CITA', 'ATENDIDA');
        v_diagnostico VARCHAR2(4000) := TRIM(p_diagnostico);
        v_notas       VARCHAR2(4000) := TRIM(p_notas);
        v_estado      NUMBER;
        v_medico      NUMBER;
        e_bloqueado   EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        IF v_diagnostico IS NULL OR LENGTH(v_diagnostico) < 3 THEN
            RAISE_APPLICATION_ERROR(-20104, 'El diagnostico es obligatorio (minimo 3 caracteres)');
        END IF;
        IF LENGTH(v_diagnostico) > 2000 THEN
            RAISE_APPLICATION_ERROR(-20105, 'El diagnostico no puede superar 2000 caracteres');
        END IF;
        IF LENGTH(v_notas) > 4000 THEN
            RAISE_APPLICATION_ERROR(-20105, 'Las notas no pueden superar 4000 caracteres');
        END IF;

        -- Bloquea la cita: dos registros simultaneos de la misma consulta no pueden pasar
        BEGIN
            SELECT c.ID_ESTADO, a.ID_MEDICO
              INTO v_estado, v_medico
              FROM CITAS_MEDICAS c
              JOIN AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
             WHERE c.ID_CITA = p_id_cita
               FOR UPDATE OF c.ID_ESTADO WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20101, 'La cita no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20102, 'La cita esta siendo modificada por otra persona, intenta de nuevo');
        END;

        IF p_id_medico IS NOT NULL AND p_id_medico <> v_medico THEN
            RAISE_APPLICATION_ERROR(-20103, 'La cita pertenece a otro medico');
        END IF;

        IF v_estado <> v_prog THEN
            RAISE_APPLICATION_ERROR(-20102, 'Solo se puede registrar la consulta de una cita PROGRAMADA');
        END IF;

        INSERT INTO HISTORIA_CLINICA (ID_HISTORIA, ID_CITA, DIAGNOSTICO, NOTAS_MEDICAS)
        VALUES (SEQ_HISTORIA_CLINICA.NEXTVAL, p_id_cita, v_diagnostico, v_notas)
        RETURNING ID_HISTORIA INTO p_id_historia;

        UPDATE CITAS_MEDICAS SET ID_ESTADO = v_aten WHERE ID_CITA = p_id_cita;

        -- La auditoria no guarda el contenido clinico, solo el cambio de estado
        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'REGISTRAR_CONSULTA', 'HISTORIA_CLINICA', p_id_historia,
                'id_cita=' || p_id_cita || '; estado=PROGRAMADA',
                'id_cita=' || p_id_cita || '; estado=ATENDIDA');

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END REGISTRAR_CONSULTA;

END PKG_HISTORIAS_CLINICAS;
/
SHOW ERRORS

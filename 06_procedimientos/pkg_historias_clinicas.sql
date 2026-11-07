-- =====================================================================
-- PKG_HISTORIAS_CLINICAS  (HU03 registrar consulta; luego HU04, HU07, HU08)
-- Inserta en HISTORIA_CLINICA y actualiza el estado de CITAS_MEDICAS. No modifica la estructura de ninguna tabla.
-- Errores: rango 20101-20199. (20106: cita vencida)
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_HISTORIAS_CLINICAS AS

    EXC_CITA_NO_EXISTE          EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CITA_NO_EXISTE,          -20101);
    EXC_CITA_NO_PROGRAMADA      EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CITA_NO_PROGRAMADA,      -20102);
    EXC_CITA_DE_OTRO_MEDICO     EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CITA_DE_OTRO_MEDICO,     -20103);
    EXC_DIAGNOSTICO_OBLIGATORIO EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_DIAGNOSTICO_OBLIGATORIO, -20104);
    EXC_TEXTO_MUY_LARGO         EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_TEXTO_MUY_LARGO,         -20105);
    EXC_CITA_VENCIDA            EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CITA_VENCIDA,            -20106);

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

    -- Pasa a NO_ASISTIO las citas PROGRAMADA cuyo horario ya termino. Un COMMIT al final.
    -- La llama un job del back cada minuto. Devuelve cuantas marco. Si el estado
    -- NO_ASISTIO no existe en PARAMETRICA_TIPOS no hace nada (ver db/03_datos).
    PROCEDURE MARCAR_NO_ASISTIDAS(p_marcadas OUT NUMBER);

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
        v_fin         TIMESTAMP;
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
            SELECT c.ID_ESTADO, a.ID_MEDICO, a.FECHA_HORA_FIN
              INTO v_estado, v_medico, v_fin
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

        -- Solo se atiende hasta la hora final de la cita
        IF v_fin < LOCALTIMESTAMP THEN
            RAISE_APPLICATION_ERROR(-20106, 'El horario de esta cita ya termino; no se puede registrar la consulta');
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

    PROCEDURE MARCAR_NO_ASISTIDAS(p_marcadas OUT NUMBER) IS
        v_prog NUMBER := id_param('ESTADO_CITA', 'PROGRAMADA');
        v_noas NUMBER;
    BEGIN
        p_marcadas := 0;
        BEGIN
            v_noas := id_param('ESTADO_CITA', 'NO_ASISTIO');
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RETURN;
        END;

        FOR r IN (SELECT c.ID_CITA
                    FROM CITAS_MEDICAS c
                    JOIN AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
                   WHERE c.ID_ESTADO = v_prog
                     AND a.FECHA_HORA_FIN < LOCALTIMESTAMP
                     FOR UPDATE OF c.ID_ESTADO SKIP LOCKED) LOOP
            UPDATE CITAS_MEDICAS SET ID_ESTADO = v_noas WHERE ID_CITA = r.ID_CITA;
            -- ID_USUARIO 0 = sistema
            INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
            VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, 0, 'MARCAR_NO_ASISTIO', 'CITAS_MEDICAS', r.ID_CITA,
                    'estado=PROGRAMADA', 'estado=NO_ASISTIO');
            p_marcadas := p_marcadas + 1;
        END LOOP;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END MARCAR_NO_ASISTIDAS;

END PKG_HISTORIAS_CLINICAS;
/
SHOW ERRORS

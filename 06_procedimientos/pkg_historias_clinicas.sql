-- =====================================================================
-- PKG_HISTORIAS_CLINICAS  (HU03 registrar consulta; luego HU04, HU07, HU08)
-- Inserta en TBL_HISTORIA_CLINICA y actualiza el estado de TBL_CITAS_MEDICAS. No modifica la estructura de ninguna tabla.
-- Errores: rango 20101-20199. (20106: cita vencida; 20109: cita que aun no inicia)
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_HISTORIAS_CLINICAS AS

    EX_CITA_NO_EXISTE          EXCEPTION; PRAGMA EXCEPTION_INIT(EX_CITA_NO_EXISTE,          -20101);
    EX_CITA_NO_PROGRAMADA      EXCEPTION; PRAGMA EXCEPTION_INIT(EX_CITA_NO_PROGRAMADA,      -20102);
    EX_CITA_DE_OTRO_MEDICO     EXCEPTION; PRAGMA EXCEPTION_INIT(EX_CITA_DE_OTRO_MEDICO,     -20103);
    EX_DIAGNOSTICO_OBLIGATORIO EXCEPTION; PRAGMA EXCEPTION_INIT(EX_DIAGNOSTICO_OBLIGATORIO, -20104);
    EX_TEXTO_MUY_LARGO         EXCEPTION; PRAGMA EXCEPTION_INIT(EX_TEXTO_MUY_LARGO,         -20105);
    EX_CITA_VENCIDA            EXCEPTION; PRAGMA EXCEPTION_INIT(EX_CITA_VENCIDA,            -20106);

    -- HU03. Crea la historia clinica y marca la cita como ATENDIDA en la misma
    -- transaccion (un solo COMMIT). Si pn_id_medico no es NULL, la cita debe ser de ese medico.
    PROCEDURE PRO_REGISTRAR_CONSULTA(
        pn_id_cita     IN  NUMBER,
        ps_diagnostico IN  VARCHAR2,
        ps_notas       IN  VARCHAR2,
        pn_id_usuario  IN  NUMBER,
        pn_id_historia OUT NUMBER,
        pn_id_medico   IN  NUMBER DEFAULT NULL
    );

    -- Pasa a NO_ASISTIO las citas PROGRAMADA cuyo horario ya termino. Un COMMIT al final.
    -- La llama un job del back cada minuto. Devuelve cuantas marco. Si el estado
    -- NO_ASISTIO no existe en TBL_PARAMETRICA_TIPOS no hace nada (ver db/03_datos).
    PROCEDURE PRO_MARCAR_NO_ASISTIDAS(pn_marcadas OUT NUMBER);

END PKG_HISTORIAS_CLINICAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_HISTORIAS_CLINICAS AS

    FUNCTION FN_ID_PARAM(ps_nombre VARCHAR2, ps_valor VARCHAR2) RETURN NUMBER IS
        vn_id NUMBER;
    BEGIN
        SELECT ID_PARAMETRO INTO vn_id
          FROM TBL_PARAMETRICA_TIPOS
         WHERE NOMBRE = ps_nombre AND VALOR = ps_valor;
        RETURN vn_id;
    END FN_ID_PARAM;

    PROCEDURE PRO_REGISTRAR_CONSULTA(
        pn_id_cita     IN  NUMBER,
        ps_diagnostico IN  VARCHAR2,
        ps_notas       IN  VARCHAR2,
        pn_id_usuario  IN  NUMBER,
        pn_id_historia OUT NUMBER,
        pn_id_medico   IN  NUMBER DEFAULT NULL
    ) IS
        vn_prog        NUMBER := FN_ID_PARAM('ESTADO_CITA', 'PROGRAMADA');
        vn_aten        NUMBER := FN_ID_PARAM('ESTADO_CITA', 'ATENDIDA');
        vs_diagnostico VARCHAR2(4000) := TRIM(ps_diagnostico);
        vs_notas       VARCHAR2(4000) := TRIM(ps_notas);
        vn_estado      NUMBER;
        vn_medico      NUMBER;
        vt_fin         TIMESTAMP;
        vt_inicio      TIMESTAMP;
        ex_bloqueado   EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        IF vs_diagnostico IS NULL OR LENGTH(vs_diagnostico) < 3 THEN
            RAISE_APPLICATION_ERROR(-20104, 'El diagnostico es obligatorio (minimo 3 caracteres)');
        END IF;
        IF LENGTH(vs_diagnostico) > 2000 THEN
            RAISE_APPLICATION_ERROR(-20105, 'El diagnostico no puede superar 2000 caracteres');
        END IF;
        IF LENGTH(vs_notas) > 4000 THEN
            RAISE_APPLICATION_ERROR(-20105, 'Las notas no pueden superar 4000 caracteres');
        END IF;

        -- Bloquea la cita: dos registros simultaneos de la misma consulta no pueden pasar
        BEGIN
            SELECT c.ID_ESTADO, a.ID_MEDICO, c.FECHA_HORA_FIN, c.FECHA_HORA_INICIO
              INTO vn_estado, vn_medico, vt_fin, vt_inicio
              FROM TBL_CITAS_MEDICAS c
              JOIN TBL_AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
             WHERE c.ID_CITA = pn_id_cita
               FOR UPDATE OF c.ID_ESTADO WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20101, 'La cita no existe');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20102, 'La cita esta siendo modificada por otra persona, intenta de nuevo');
        END;

        IF pn_id_medico IS NOT NULL AND pn_id_medico <> vn_medico THEN
            RAISE_APPLICATION_ERROR(-20103, 'La cita pertenece a otro medico');
        END IF;

        IF vn_estado <> vn_prog THEN
            RAISE_APPLICATION_ERROR(-20102, 'Solo se puede registrar la consulta de una cita PROGRAMADA');
        END IF;

        -- Solo se puede registrar desde la hora de inicio de la cita
        IF vt_inicio > LOCALTIMESTAMP THEN
            RAISE_APPLICATION_ERROR(-20109, 'Aun no es la hora de esta cita; la consulta se puede registrar desde que inicia');
        END IF;

        -- Solo se atiende hasta la hora final de la cita
        IF vt_fin < LOCALTIMESTAMP THEN
            RAISE_APPLICATION_ERROR(-20106, 'El horario de esta cita ya termino; no se puede registrar la consulta');
        END IF;

        INSERT INTO TBL_HISTORIA_CLINICA (ID_HISTORIA, ID_CITA, DIAGNOSTICO, NOTAS_MEDICAS)
        VALUES (SEQ_TBL_HISTORIA_CLINICA.NEXTVAL, pn_id_cita, vs_diagnostico, vs_notas)
        RETURNING ID_HISTORIA INTO pn_id_historia;

        UPDATE TBL_CITAS_MEDICAS SET ID_ESTADO = vn_aten WHERE ID_CITA = pn_id_cita;

        -- La auditoria no guarda el contenido clinico, solo el cambio de estado
        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'REGISTRAR_CONSULTA', 'TBL_HISTORIA_CLINICA', pn_id_historia,
                'id_cita=' || pn_id_cita || '; estado=PROGRAMADA',
                'id_cita=' || pn_id_cita || '; estado=ATENDIDA');

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_REGISTRAR_CONSULTA;

    PROCEDURE PRO_MARCAR_NO_ASISTIDAS(pn_marcadas OUT NUMBER) IS
        vn_prog NUMBER := FN_ID_PARAM('ESTADO_CITA', 'PROGRAMADA');
        vn_noas NUMBER;
    BEGIN
        pn_marcadas := 0;
        BEGIN
            vn_noas := FN_ID_PARAM('ESTADO_CITA', 'NO_ASISTIO');
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RETURN;
        END;

        FOR vr_r IN (SELECT c.ID_CITA
                    FROM TBL_CITAS_MEDICAS c
                    JOIN TBL_AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
                   WHERE c.ID_ESTADO = vn_prog
                     AND c.FECHA_HORA_FIN < LOCALTIMESTAMP
                     FOR UPDATE OF c.ID_ESTADO SKIP LOCKED) LOOP
            UPDATE TBL_CITAS_MEDICAS SET ID_ESTADO = vn_noas WHERE ID_CITA = vr_r.ID_CITA;
            -- ID_USUARIO 0 = sistema
            INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
            VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, 0, 'MARCAR_NO_ASISTIO', 'TBL_CITAS_MEDICAS', vr_r.ID_CITA,
                    'estado=PROGRAMADA', 'estado=NO_ASISTIO');
            pn_marcadas := pn_marcadas + 1;
        END LOOP;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_MARCAR_NO_ASISTIDAS;

END PKG_HISTORIAS_CLINICAS;
/
SHOW ERRORS

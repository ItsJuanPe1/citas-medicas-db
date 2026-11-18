-- =====================================================================
-- Carga citas PROGRAMADAS desde manana hasta el 28-feb-2027 sobre las agendas ya existentes
-- (corre antes horarios_medicos.sql / PRO_GUARDAR_HORARIO_SEMANAL para que haya agendas).
-- Respeta las reglas: cita de 1 hora dentro de la agenda, sin cruces del medico ni del paciente,
-- agenda OCUPADA cuando se llena. Deja huecos para la presentacion:
--   * solo ~60% de las horas de cada agenda se ocupa (cn_ocupacion),
--   * ~1 de cada 4 dias de cada medico queda completamente libre.
-- Se puede repetir: no pisa citas existentes (solo agrega en huecos). Hace COMMIT al final.
-- =====================================================================
SET SERVEROUTPUT ON
DECLARE
    cn_ocupacion CONSTANT NUMBER := 60;            -- % de horas que se ocupan
    cd_hasta     CONSTANT DATE   := DATE '2027-02-28';
    TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    vc_pac    t_ids;
    vn_prog   NUMBER;
    vn_canc   NUMBER;
    vn_ocup   NUMBER;
    vn_disp   NUMBER;
    vt        TIMESTAMP;
    vt_fin    TIMESTAMP;
    vn_n      NUMBER;
    vn_p      NUMBER;
    vn_usados NUMBER;
    vn_creadas NUMBER := 0;
BEGIN
    SELECT ID_PARAMETRO INTO vn_prog FROM TBL_PARAMETRICA_TIPOS WHERE NOMBRE = 'ESTADO_CITA'   AND VALOR = 'PROGRAMADA';
    SELECT ID_PARAMETRO INTO vn_canc FROM TBL_PARAMETRICA_TIPOS WHERE NOMBRE = 'ESTADO_CITA'   AND VALOR = 'CANCELADA';
    SELECT ID_PARAMETRO INTO vn_ocup FROM TBL_PARAMETRICA_TIPOS WHERE NOMBRE = 'ESTADO_AGENDA' AND VALOR = 'OCUPADA';
    SELECT ID_PARAMETRO INTO vn_disp FROM TBL_PARAMETRICA_TIPOS WHERE NOMBRE = 'ESTADO_AGENDA' AND VALOR = 'DISPONIBLE';
    SELECT ID_PACIENTE BULK COLLECT INTO vc_pac FROM TBL_PACIENTES;

    FOR vr_ag IN (SELECT ID_AGENDA, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN
                    FROM TBL_AGENDAS_MEDICOS
                   WHERE ID_ESTADO = vn_disp
                     AND FECHA_HORA_INICIO >= TRUNC(SYSDATE) + 1
                     AND FECHA_HORA_INICIO <  cd_hasta + 1
                   ORDER BY FECHA_HORA_INICIO) LOOP
        -- dia completamente libre para ese medico (para citas en vivo durante la presentacion)
        CONTINUE WHEN MOD(vr_ag.ID_MEDICO + TO_NUMBER(TO_CHAR(vr_ag.FECHA_HORA_INICIO, 'DDD')), 4) = 0;

        vt := vr_ag.FECHA_HORA_INICIO;
        WHILE vt + INTERVAL '1' HOUR <= vr_ag.FECHA_HORA_FIN LOOP
            vt_fin := vt + INTERVAL '1' HOUR;
            IF DBMS_RANDOM.VALUE(0, 100) < cn_ocupacion THEN
                SELECT COUNT(*) INTO vn_n
                  FROM TBL_CITAS_MEDICAS c JOIN TBL_AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
                 WHERE a.ID_MEDICO = vr_ag.ID_MEDICO AND c.ID_ESTADO <> vn_canc
                   AND c.FECHA_HORA_INICIO < vt_fin AND c.FECHA_HORA_FIN > vt;
                IF vn_n = 0 THEN
                    FOR vn_try IN 1 .. 5 LOOP
                        vn_p := vc_pac(TRUNC(DBMS_RANDOM.VALUE(1, vc_pac.COUNT + 1)));
                        SELECT COUNT(*) INTO vn_n FROM TBL_CITAS_MEDICAS c
                         WHERE c.ID_PACIENTE = vn_p AND c.ID_ESTADO <> vn_canc
                           AND c.FECHA_HORA_INICIO < vt_fin AND c.FECHA_HORA_FIN > vt;
                        IF vn_n = 0 THEN
                            INSERT INTO TBL_CITAS_MEDICAS (ID_CITA, ID_PACIENTE, ID_AGENDA, FECHA_HORA_INICIO, FECHA_HORA_FIN, ID_ESTADO)
                            VALUES (SEQ_TBL_CITAS_MEDICAS.NEXTVAL, vn_p, vr_ag.ID_AGENDA, vt, vt_fin, vn_prog);
                            vn_creadas := vn_creadas + 1;
                            EXIT;
                        END IF;
                    END LOOP;
                END IF;
            END IF;
            vt := vt_fin;
        END LOOP;

        -- si las citas llenaron todo el rango, la agenda queda OCUPADA
        SELECT NVL(SUM(ROUND((CAST(c.FECHA_HORA_FIN AS DATE) - CAST(c.FECHA_HORA_INICIO AS DATE)) * 24 * 60)), 0)
          INTO vn_usados FROM TBL_CITAS_MEDICAS c
         WHERE c.ID_AGENDA = vr_ag.ID_AGENDA AND c.ID_ESTADO <> vn_canc;
        IF vn_usados >= ROUND((CAST(vr_ag.FECHA_HORA_FIN AS DATE) - CAST(vr_ag.FECHA_HORA_INICIO AS DATE)) * 24 * 60) THEN
            UPDATE TBL_AGENDAS_MEDICOS SET ID_ESTADO = vn_ocup WHERE ID_AGENDA = vr_ag.ID_AGENDA;
        END IF;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Citas programadas creadas: ' || vn_creadas);
END;
/

-- Resumen por medico: citas programadas futuras y horas libres que quedan
SELECT m.NOMBRE || ' ' || m.APELLIDO AS MEDICO,
       (SELECT COUNT(*) FROM TBL_CITAS_MEDICAS c JOIN TBL_AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
         WHERE a.ID_MEDICO = m.ID_MEDICO AND c.FECHA_HORA_INICIO > SYSTIMESTAMP
           AND c.ID_ESTADO = (SELECT ID_PARAMETRO FROM TBL_PARAMETRICA_TIPOS WHERE NOMBRE='ESTADO_CITA' AND VALOR='PROGRAMADA')) AS PROGRAMADAS,
       (SELECT COUNT(*) FROM TBL_AGENDAS_MEDICOS a WHERE a.ID_MEDICO = m.ID_MEDICO AND a.FECHA_HORA_INICIO > SYSTIMESTAMP
           AND a.ID_ESTADO = (SELECT ID_PARAMETRO FROM TBL_PARAMETRICA_TIPOS WHERE NOMBRE='ESTADO_AGENDA' AND VALOR='DISPONIBLE')) AS AGENDAS_CON_HUECO
  FROM TBL_MEDICOS m ORDER BY 1;
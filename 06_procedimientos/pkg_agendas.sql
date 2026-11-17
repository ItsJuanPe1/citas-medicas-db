-- =====================================================================
-- PKG_AGENDAS: el medico define sus horarios. Una agenda es un RANGO de horas de un dia
-- (ej. martes 7:00 a 12:00) y dentro de ella se reservan varias citas (ver PKG_GESTION_CITAS).
-- Inserta y borra filas en TBL_AGENDAS_MEDICOS ligadas al ID_MEDICO. DIA_SEMANA de cada agenda permite repetir
-- el mismo horario cada semana. Errores: 20301-20399.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_AGENDAS AS

    -- Crea un rango de atencion del medico (mismo dia, hasta 12 horas, no en el pasado).
    PROCEDURE PRO_CREAR_AGENDA(
        pn_id_medico  IN  NUMBER,
        pt_inicio     IN  TIMESTAMP,
        pt_fin        IN  TIMESTAMP,
        pn_id_usuario IN  NUMBER,
        pn_id_agenda  OUT NUMBER
    );

    -- Horario semanal: lo que el medico atiende TODAS las semanas (ej. martes 16:00 a 19:00).
    -- ps_bloques: 'DIA~HH:MM~HH:MM|DIA~HH:MM~HH:MM' (DIA = LUNES..DOMINGO; vacio = sin horario).
    -- Borra las agendas futuras del medico que no tengan citas y
    -- crea las de las proximas pn_semanas semanas segun los bloques (una agenda por cada fecha).
    PROCEDURE PRO_GUARDAR_HORARIO_SEMANAL(
        pn_id_medico  IN  NUMBER,
        ps_bloques    IN  VARCHAR2,
        pn_id_usuario IN  NUMBER,
        pn_semanas    IN  NUMBER DEFAULT 52,
        pn_creadas    OUT NUMBER
    );

    -- Extiende hacia adelante los horarios que ya se repiten cada semana (mismo DIA_SEMANA y horas
    -- en 2+ fechas futuras), hasta pn_semanas semanas (no repite ni cruza las existentes). pn_id_medico NULL = todos los medicos.
    -- La llama un job del back para que el horario nunca se acabe (siempre quedan ~1 anio de agendas por delante).
    PROCEDURE PRO_GENERAR_AGENDAS_SEMANALES(
        pn_id_medico IN  NUMBER DEFAULT NULL,
        pn_semanas   IN  NUMBER DEFAULT 52,
        pn_creadas   OUT NUMBER
    );

    -- Borra una agenda SIN citas. Si pn_id_medico no es NULL, debe ser suya.
    PROCEDURE PRO_ELIMINAR_AGENDA(
        pn_id_agenda  IN NUMBER,
        pn_id_usuario IN NUMBER,
        pn_id_medico  IN NUMBER DEFAULT NULL
    );

END PKG_AGENDAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_AGENDAS AS

    FUNCTION FN_ID_PARAM(ps_nombre VARCHAR2, ps_valor VARCHAR2) RETURN NUMBER IS
        vn_id NUMBER;
    BEGIN
        SELECT ID_PARAMETRO INTO vn_id FROM TBL_PARAMETRICA_TIPOS
         WHERE NOMBRE = ps_nombre AND VALOR = ps_valor;
        RETURN vn_id;
    END FN_ID_PARAM;

    FUNCTION FN_DIA_SEMANA(pd_fecha DATE) RETURN VARCHAR2 IS
    BEGIN
        -- 2000-01-03 fue lunes; no depende del idioma de la sesion
        RETURN CASE MOD(TRUNC(pd_fecha) - DATE '2000-01-03', 7)
                   WHEN 0 THEN 'LUNES'  WHEN 1 THEN 'MARTES'  WHEN 2 THEN 'MIERCOLES'
                   WHEN 3 THEN 'JUEVES' WHEN 4 THEN 'VIERNES' WHEN 5 THEN 'SABADO'
                   ELSE 'DOMINGO' END;
    END FN_DIA_SEMANA;


    -- Cuantas agendas "vivas" (disponibles o con citas no canceladas) se cruzan con el rango
    FUNCTION FN_HAY_CRUCE(pn_medico NUMBER, pt_ini TIMESTAMP, pt_fin TIMESTAMP) RETURN NUMBER IS
        vn_disp NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'DISPONIBLE');
        vn_canc NUMBER := FN_ID_PARAM('ESTADO_CITA', 'CANCELADA');
        vn_n    NUMBER;
    BEGIN
        SELECT COUNT(*) INTO vn_n
          FROM TBL_AGENDAS_MEDICOS a
         WHERE a.ID_MEDICO = pn_medico
           AND a.FECHA_HORA_INICIO < pt_fin
           AND a.FECHA_HORA_FIN    > pt_ini
           AND (a.ID_ESTADO = vn_disp
                OR EXISTS (SELECT 1 FROM TBL_CITAS_MEDICAS c
                            WHERE c.ID_AGENDA = a.ID_AGENDA AND c.ID_ESTADO <> vn_canc));
        RETURN vn_n;
    END FN_HAY_CRUCE;

    -- Crea, para un dia de la semana y un rango de horas, las agendas de las proximas semanas
    -- que sean posteriores a pd_despues_de (fecha). No hace COMMIT. Devuelve cuantas creo.
    FUNCTION FN_CREAR_DIA(pn_medico NUMBER, ps_dia VARCHAR2, ps_desde VARCHAR2, ps_hasta VARCHAR2,
                       pd_despues_de DATE, pn_semanas NUMBER) RETURN NUMBER IS
        vn_disp  NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'DISPONIBLE');
        vn_n     NUMBER := 0;
        vd_fecha DATE;
        vt_ini   TIMESTAMP;
        vt_fin   TIMESTAMP;
    BEGIN
        FOR vn_d IN 0 .. (pn_semanas * 7) LOOP
            vd_fecha := TRUNC(SYSDATE) + vn_d;
            IF vd_fecha > pd_despues_de AND FN_DIA_SEMANA(vd_fecha) = ps_dia THEN
                vt_ini := TO_TIMESTAMP(TO_CHAR(vd_fecha, 'YYYY-MM-DD') || ' ' || ps_desde, 'YYYY-MM-DD HH24:MI');
                vt_fin := TO_TIMESTAMP(TO_CHAR(vd_fecha, 'YYYY-MM-DD') || ' ' || ps_hasta, 'YYYY-MM-DD HH24:MI');
                IF vt_ini > LOCALTIMESTAMP AND FN_HAY_CRUCE(pn_medico, vt_ini, vt_fin) = 0 THEN
                    INSERT INTO TBL_AGENDAS_MEDICOS (ID_AGENDA, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN, DIA_SEMANA, ID_ESTADO)
                    VALUES (SEQ_TBL_AGENDAS_MEDICOS.NEXTVAL, pn_medico, vt_ini, vt_fin, ps_dia, vn_disp);
                    vn_n := vn_n + 1;
                END IF;
            END IF;
        END LOOP;
        RETURN vn_n;
    END FN_CREAR_DIA;

    PROCEDURE PRO_GUARDAR_HORARIO_SEMANAL(
        pn_id_medico  IN  NUMBER,
        ps_bloques    IN  VARCHAR2,
        pn_id_usuario IN  NUMBER,
        pn_semanas    IN  NUMBER DEFAULT 52,
        pn_creadas    OUT NUMBER
    ) IS
        TYPE t_txt IS TABLE OF VARCHAR2(10) INDEX BY PLS_INTEGER;
        vc_dias     t_txt;
        vc_desde    t_txt;
        vc_hasta    t_txt;
        vn_disp     NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'DISPONIBLE');
        vn_medico   NUMBER;
        vn_n        NUMBER := CASE WHEN ps_bloques IS NULL THEN 0 ELSE REGEXP_COUNT(ps_bloques, '[^|]+') END;
        vs_item     VARCHAR2(60);
        vn_min      NUMBER;
        ex_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        IF pn_semanas IS NULL OR pn_semanas < 1 OR pn_semanas > 104 THEN
            RAISE_APPLICATION_ERROR(-20302, 'Las semanas a generar deben estar entre 1 y 104');
        END IF;
        IF vn_n > 21 THEN
            RAISE_APPLICATION_ERROR(-20302, 'Maximo 21 bloques por semana');
        END IF;

        -- Validacion de cada bloque
        FOR vn_i IN 1 .. vn_n LOOP
            vs_item     := REGEXP_SUBSTR(ps_bloques, '[^|]+', 1, vn_i);
            vc_dias(vn_i)  := UPPER(TRIM(REGEXP_SUBSTR(vs_item, '[^~]+', 1, 1)));
            vc_desde(vn_i) := TRIM(REGEXP_SUBSTR(vs_item, '[^~]+', 1, 2));
            vc_hasta(vn_i) := TRIM(REGEXP_SUBSTR(vs_item, '[^~]+', 1, 3));
            IF vc_dias(vn_i) IS NULL OR vc_dias(vn_i) NOT IN ('LUNES','MARTES','MIERCOLES','JUEVES','VIERNES','SABADO','DOMINGO') THEN
                RAISE_APPLICATION_ERROR(-20302, 'Dia invalido en el horario semanal');
            END IF;
            IF vc_desde(vn_i) IS NULL OR vc_hasta(vn_i) IS NULL
               OR NOT REGEXP_LIKE(vc_desde(vn_i), '^([01][0-9]|2[0-3]):[0-5][0-9]$')
               OR NOT REGEXP_LIKE(vc_hasta(vn_i), '^([01][0-9]|2[0-3]):[0-5][0-9]$') THEN
                RAISE_APPLICATION_ERROR(-20302, 'Las horas deben tener formato HH:MM');
            END IF;
            vn_min := (TO_NUMBER(SUBSTR(vc_hasta(vn_i), 1, 2)) * 60 + TO_NUMBER(SUBSTR(vc_hasta(vn_i), 4, 2)))
                   - (TO_NUMBER(SUBSTR(vc_desde(vn_i), 1, 2)) * 60 + TO_NUMBER(SUBSTR(vc_desde(vn_i), 4, 2)));
            IF vn_min < 60 OR vn_min > 720 OR MOD(vn_min, 60) <> 0 THEN
                RAISE_APPLICATION_ERROR(-20302, 'Cada bloque debe durar un numero exacto de horas (entre 1 y 12), porque cada cita dura 1 hora');
            END IF;
            FOR vn_j IN 1 .. vn_i - 1 LOOP
                IF vc_dias(vn_j) = vc_dias(vn_i) AND vc_desde(vn_j) < vc_hasta(vn_i) AND vc_hasta(vn_j) > vc_desde(vn_i) THEN
                    RAISE_APPLICATION_ERROR(-20302, 'Dos bloques del mismo dia se cruzan (' || vc_dias(vn_i) || ')');
                END IF;
            END LOOP;
        END LOOP;

        BEGIN
            SELECT ID_MEDICO INTO vn_medico FROM TBL_MEDICOS
             WHERE ID_MEDICO = pn_id_medico FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20305, 'El medico no existe');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20306, 'Se estan modificando los horarios de este medico, intenta de nuevo');
        END;

        -- Las agendas futuras SIN citas se rehacen; las que ya tienen citas no se tocan
        DELETE FROM TBL_AGENDAS_MEDICOS a
         WHERE a.ID_MEDICO = pn_id_medico
           AND a.FECHA_HORA_INICIO > LOCALTIMESTAMP
           AND a.ID_ESTADO = vn_disp
           AND NOT EXISTS (SELECT 1 FROM TBL_CITAS_MEDICAS c WHERE c.ID_AGENDA = a.ID_AGENDA);

        -- Cada bloque se repite en su dia de la semana durante las proximas pn_semanas semanas
        pn_creadas := 0;
        FOR vn_i IN 1 .. vn_n LOOP
            pn_creadas := pn_creadas + FN_CREAR_DIA(pn_id_medico, vc_dias(vn_i), vc_desde(vn_i), vc_hasta(vn_i), TRUNC(SYSDATE) - 1, pn_semanas);
        END LOOP;

        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'GUARDAR_HORARIO_SEMANAL', 'TBL_AGENDAS_MEDICOS', pn_id_medico,
                NULL, 'medico=' || pn_id_medico || '; bloques=' || vn_n || '; agendas_creadas=' || pn_creadas);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_GUARDAR_HORARIO_SEMANAL;

    PROCEDURE PRO_GENERAR_AGENDAS_SEMANALES(
        pn_id_medico IN  NUMBER DEFAULT NULL,
        pn_semanas   IN  NUMBER DEFAULT 52,
        pn_creadas   OUT NUMBER
    ) IS
    BEGIN
        pn_creadas := 0;
        -- SKIP LOCKED: si alguien esta guardando el horario de un medico, se salta y queda para la proxima vez
        FOR vr_m IN (SELECT ID_MEDICO FROM TBL_MEDICOS
                   WHERE (pn_id_medico IS NULL OR ID_MEDICO = pn_id_medico)
                     AND ID_MEDICO IN (SELECT ID_MEDICO FROM TBL_AGENDAS_MEDICOS WHERE FECHA_HORA_FIN > LOCALTIMESTAMP)
                     FOR UPDATE SKIP LOCKED) LOOP
            -- Patron semanal = mismo dia y mismas horas en 2 o mas fechas futuras distintas.
            -- Solo se extiende hacia adelante desde su ultima fecha (lo que el medico quito en medio no se recrea).
            FOR vr_pat IN (SELECT DIA_SEMANA,
                               TO_CHAR(FECHA_HORA_INICIO, 'HH24:MI') AS DESDE,
                               TO_CHAR(FECHA_HORA_FIN, 'HH24:MI')    AS HASTA,
                               MAX(TRUNC(CAST(FECHA_HORA_INICIO AS DATE))) AS ULTIMA
                          FROM TBL_AGENDAS_MEDICOS
                         WHERE ID_MEDICO = vr_m.ID_MEDICO AND FECHA_HORA_FIN > LOCALTIMESTAMP
                         GROUP BY DIA_SEMANA, TO_CHAR(FECHA_HORA_INICIO, 'HH24:MI'), TO_CHAR(FECHA_HORA_FIN, 'HH24:MI')
                        HAVING COUNT(DISTINCT TRUNC(CAST(FECHA_HORA_INICIO AS DATE))) >= 2) LOOP
                pn_creadas := pn_creadas + FN_CREAR_DIA(vr_m.ID_MEDICO, vr_pat.DIA_SEMANA, vr_pat.DESDE, vr_pat.HASTA, vr_pat.ULTIMA, pn_semanas);
            END LOOP;
        END LOOP;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_GENERAR_AGENDAS_SEMANALES;

    PROCEDURE PRO_CREAR_AGENDA(
        pn_id_medico  IN  NUMBER,
        pt_inicio     IN  TIMESTAMP,
        pt_fin        IN  TIMESTAMP,
        pn_id_usuario IN  NUMBER,
        pn_id_agenda  OUT NUMBER
    ) IS
        vn_disp     NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'DISPONIBLE');
        vn_canc     NUMBER := FN_ID_PARAM('ESTADO_CITA', 'CANCELADA');
        vn_medico   NUMBER;
        vn_cruces   NUMBER;
        vn_horas    NUMBER;
        vs_dia      VARCHAR2(10);
        ex_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        IF pt_inicio IS NULL OR pt_fin IS NULL THEN
            RAISE_APPLICATION_ERROR(-20302, 'Faltan datos: fecha, hora desde y hora hasta');
        END IF;
        IF pt_inicio <= LOCALTIMESTAMP THEN
            RAISE_APPLICATION_ERROR(-20301, 'No se pueden crear horarios en el pasado');
        END IF;
        IF pt_fin <= pt_inicio OR TRUNC(pt_fin) <> TRUNC(pt_inicio) THEN
            RAISE_APPLICATION_ERROR(-20302, 'La hora final debe ser posterior a la inicial, el mismo dia');
        END IF;
        vn_horas := (CAST(pt_fin AS DATE) - CAST(pt_inicio AS DATE)) * 24;
        IF vn_horas > 12 THEN
            RAISE_APPLICATION_ERROR(-20302, 'Un horario puede durar maximo 12 horas');
        END IF;
        IF vn_horas < 1 OR MOD(ROUND(vn_horas * 60), 60) <> 0 THEN
            RAISE_APPLICATION_ERROR(-20302, 'Un horario debe durar un numero exacto de horas, porque cada cita dura 1 hora');
        END IF;

        -- Bloquea al medico: dos pedidos a la vez no pueden crear rangos cruzados
        BEGIN
            SELECT ID_MEDICO INTO vn_medico FROM TBL_MEDICOS
             WHERE ID_MEDICO = pn_id_medico FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20305, 'El medico no existe');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20306, 'Se estan modificando los horarios de este medico, intenta de nuevo');
        END;

        -- Cruce con otro rango "vivo": disponible o con citas no canceladas
        SELECT COUNT(*) INTO vn_cruces
          FROM TBL_AGENDAS_MEDICOS a
         WHERE a.ID_MEDICO = pn_id_medico
           AND a.FECHA_HORA_INICIO < pt_fin
           AND a.FECHA_HORA_FIN    > pt_inicio
           AND (a.ID_ESTADO = vn_disp
                OR EXISTS (SELECT 1 FROM TBL_CITAS_MEDICAS c
                            WHERE c.ID_AGENDA = a.ID_AGENDA AND c.ID_ESTADO <> vn_canc));
        IF vn_cruces > 0 THEN
            RAISE_APPLICATION_ERROR(-20307, 'Ya tienes un horario que se cruza con ese rango');
        END IF;

        vs_dia := FN_DIA_SEMANA(CAST(pt_inicio AS DATE));  -- SQL no puede llamar funciones privadas del paquete
        INSERT INTO TBL_AGENDAS_MEDICOS (ID_AGENDA, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN, DIA_SEMANA, ID_ESTADO)
        VALUES (SEQ_TBL_AGENDAS_MEDICOS.NEXTVAL, pn_id_medico, pt_inicio, pt_fin, vs_dia, vn_disp)
        RETURNING ID_AGENDA INTO pn_id_agenda;

        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'CREAR_AGENDA', 'TBL_AGENDAS_MEDICOS', pn_id_agenda,
                NULL,
                'medico=' || pn_id_medico || '; ' || TO_CHAR(pt_inicio, 'YYYY-MM-DD HH24:MI') || ' a ' || TO_CHAR(pt_fin, 'HH24:MI'));

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_CREAR_AGENDA;

    PROCEDURE PRO_ELIMINAR_AGENDA(
        pn_id_agenda  IN NUMBER,
        pn_id_usuario IN NUMBER,
        pn_id_medico  IN NUMBER DEFAULT NULL
    ) IS
        vn_medico   NUMBER;
        vt_inicio   TIMESTAMP;
        vt_fin      TIMESTAMP;
        vn_citas    NUMBER;
        ex_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        BEGIN
            SELECT ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN
              INTO vn_medico, vt_inicio, vt_fin
              FROM TBL_AGENDAS_MEDICOS
             WHERE ID_AGENDA = pn_id_agenda
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20308, 'El horario no existe');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20306, 'El horario esta siendo modificado, intenta de nuevo');
        END;

        IF pn_id_medico IS NOT NULL AND pn_id_medico <> vn_medico THEN
            RAISE_APPLICATION_ERROR(-20309, 'El horario pertenece a otro medico');
        END IF;

        -- Con la agenda bloqueada nadie puede reservar a la vez (RESERVAR_CITA la bloquea primero)
        SELECT COUNT(*) INTO vn_citas FROM TBL_CITAS_MEDICAS WHERE ID_AGENDA = pn_id_agenda;
        IF vn_citas > 0 THEN
            RAISE_APPLICATION_ERROR(-20310, 'Solo se pueden quitar horarios sin citas (ni siquiera canceladas)');
        END IF;

        DELETE FROM TBL_AGENDAS_MEDICOS WHERE ID_AGENDA = pn_id_agenda;

        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'ELIMINAR_AGENDA', 'TBL_AGENDAS_MEDICOS', pn_id_agenda,
                'medico=' || vn_medico || '; ' || TO_CHAR(vt_inicio, 'YYYY-MM-DD HH24:MI') || ' a ' || TO_CHAR(vt_fin, 'HH24:MI'),
                'eliminada');

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_ELIMINAR_AGENDA;

END PKG_AGENDAS;
/
SHOW ERRORS

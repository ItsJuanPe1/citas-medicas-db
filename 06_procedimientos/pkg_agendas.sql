-- =====================================================================
-- PKG_AGENDAS: el medico define sus horarios. Una agenda es un RANGO de horas de un dia
-- (ej. martes 7:00 a 12:00) y dentro de ella se reservan varias citas (ver PKG_GESTION_CITAS).
-- Inserta y borra filas en AGENDAS_MEDICOS ligadas al ID_MEDICO. DIA_SEMANA de cada agenda permite repetir
-- el mismo horario cada semana. Errores: 20301-20399.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_AGENDAS AS

    -- Crea un rango de atencion del medico (mismo dia, hasta 12 horas, no en el pasado).
    PROCEDURE CREAR_AGENDA(
        p_id_medico  IN  NUMBER,
        p_inicio     IN  TIMESTAMP,
        p_fin        IN  TIMESTAMP,
        p_id_usuario IN  NUMBER,
        p_id_agenda  OUT NUMBER
    );

    -- Horario semanal: lo que el medico atiende TODAS las semanas (ej. martes 16:00 a 19:00).
    -- p_bloques: 'DIA~HH:MM~HH:MM|DIA~HH:MM~HH:MM' (DIA = LUNES..DOMINGO; vacio = sin horario).
    -- Borra las agendas futuras del medico que no tengan citas y
    -- crea las de las proximas p_semanas semanas segun los bloques (una agenda por cada fecha).
    PROCEDURE GUARDAR_HORARIO_SEMANAL(
        p_id_medico  IN  NUMBER,
        p_bloques    IN  VARCHAR2,
        p_id_usuario IN  NUMBER,
        p_semanas    IN  NUMBER DEFAULT 52,
        p_creadas    OUT NUMBER
    );

    -- Extiende hacia adelante los horarios que ya se repiten cada semana (mismo DIA_SEMANA y horas
    -- en 2+ fechas futuras), hasta p_semanas semanas (no repite ni cruza las existentes). p_id_medico NULL = todos los medicos.
    -- La llama un job del back para que el horario nunca se acabe (siempre quedan ~1 anio de agendas por delante).
    PROCEDURE GENERAR_AGENDAS_SEMANALES(
        p_id_medico IN  NUMBER DEFAULT NULL,
        p_semanas   IN  NUMBER DEFAULT 52,
        p_creadas   OUT NUMBER
    );

    -- Borra una agenda SIN citas. Si p_id_medico no es NULL, debe ser suya.
    PROCEDURE ELIMINAR_AGENDA(
        p_id_agenda  IN NUMBER,
        p_id_usuario IN NUMBER,
        p_id_medico  IN NUMBER DEFAULT NULL
    );

END PKG_AGENDAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_AGENDAS AS

    FUNCTION id_param(p_nombre VARCHAR2, p_valor VARCHAR2) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        SELECT ID_PARAMETRO INTO v_id FROM PARAMETRICA_TIPOS
         WHERE NOMBRE = p_nombre AND VALOR = p_valor;
        RETURN v_id;
    END id_param;

    FUNCTION dia_semana(p_fecha DATE) RETURN VARCHAR2 IS
    BEGIN
        -- 2000-01-03 fue lunes; no depende del idioma de la sesion
        RETURN CASE MOD(TRUNC(p_fecha) - DATE '2000-01-03', 7)
                   WHEN 0 THEN 'LUNES'  WHEN 1 THEN 'MARTES'  WHEN 2 THEN 'MIERCOLES'
                   WHEN 3 THEN 'JUEVES' WHEN 4 THEN 'VIERNES' WHEN 5 THEN 'SABADO'
                   ELSE 'DOMINGO' END;
    END dia_semana;


    -- Cuantas agendas "vivas" (disponibles o con citas no canceladas) se cruzan con el rango
    FUNCTION hay_cruce(p_medico NUMBER, p_ini TIMESTAMP, p_fin TIMESTAMP) RETURN NUMBER IS
        v_disp NUMBER := id_param('ESTADO_AGENDA', 'DISPONIBLE');
        v_canc NUMBER := id_param('ESTADO_CITA', 'CANCELADA');
        v_n    NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_n
          FROM AGENDAS_MEDICOS a
         WHERE a.ID_MEDICO = p_medico
           AND a.FECHA_HORA_INICIO < p_fin
           AND a.FECHA_HORA_FIN    > p_ini
           AND (a.ID_ESTADO = v_disp
                OR EXISTS (SELECT 1 FROM CITAS_MEDICAS c
                            WHERE c.ID_AGENDA = a.ID_AGENDA AND c.ID_ESTADO <> v_canc));
        RETURN v_n;
    END hay_cruce;

    -- Crea, para un dia de la semana y un rango de horas, las agendas de las proximas semanas
    -- que sean posteriores a p_despues_de (fecha). No hace COMMIT. Devuelve cuantas creo.
    FUNCTION crear_dia(p_medico NUMBER, p_dia VARCHAR2, p_desde VARCHAR2, p_hasta VARCHAR2,
                       p_despues_de DATE, p_semanas NUMBER) RETURN NUMBER IS
        v_disp  NUMBER := id_param('ESTADO_AGENDA', 'DISPONIBLE');
        v_n     NUMBER := 0;
        v_fecha DATE;
        v_ini   TIMESTAMP;
        v_fin   TIMESTAMP;
    BEGIN
        FOR d IN 0 .. (p_semanas * 7) LOOP
            v_fecha := TRUNC(SYSDATE) + d;
            IF v_fecha > p_despues_de AND dia_semana(v_fecha) = p_dia THEN
                v_ini := TO_TIMESTAMP(TO_CHAR(v_fecha, 'YYYY-MM-DD') || ' ' || p_desde, 'YYYY-MM-DD HH24:MI');
                v_fin := TO_TIMESTAMP(TO_CHAR(v_fecha, 'YYYY-MM-DD') || ' ' || p_hasta, 'YYYY-MM-DD HH24:MI');
                IF v_ini > LOCALTIMESTAMP AND hay_cruce(p_medico, v_ini, v_fin) = 0 THEN
                    INSERT INTO AGENDAS_MEDICOS (ID_AGENDA, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN, DIA_SEMANA, ID_ESTADO)
                    VALUES (SEQ_AGENDAS_MEDICOS.NEXTVAL, p_medico, v_ini, v_fin, p_dia, v_disp);
                    v_n := v_n + 1;
                END IF;
            END IF;
        END LOOP;
        RETURN v_n;
    END crear_dia;

    PROCEDURE GUARDAR_HORARIO_SEMANAL(
        p_id_medico  IN  NUMBER,
        p_bloques    IN  VARCHAR2,
        p_id_usuario IN  NUMBER,
        p_semanas    IN  NUMBER DEFAULT 52,
        p_creadas    OUT NUMBER
    ) IS
        TYPE t_txt IS TABLE OF VARCHAR2(10) INDEX BY PLS_INTEGER;
        v_dias     t_txt;
        v_desde    t_txt;
        v_hasta    t_txt;
        v_disp     NUMBER := id_param('ESTADO_AGENDA', 'DISPONIBLE');
        v_medico   NUMBER;
        v_n        NUMBER := CASE WHEN p_bloques IS NULL THEN 0 ELSE REGEXP_COUNT(p_bloques, '[^|]+') END;
        v_item     VARCHAR2(60);
        v_min      NUMBER;
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        IF p_semanas IS NULL OR p_semanas < 1 OR p_semanas > 104 THEN
            RAISE_APPLICATION_ERROR(-20302, 'Las semanas a generar deben estar entre 1 y 104');
        END IF;
        IF v_n > 21 THEN
            RAISE_APPLICATION_ERROR(-20302, 'Maximo 21 bloques por semana');
        END IF;

        -- Validacion de cada bloque
        FOR i IN 1 .. v_n LOOP
            v_item     := REGEXP_SUBSTR(p_bloques, '[^|]+', 1, i);
            v_dias(i)  := UPPER(TRIM(REGEXP_SUBSTR(v_item, '[^~]+', 1, 1)));
            v_desde(i) := TRIM(REGEXP_SUBSTR(v_item, '[^~]+', 1, 2));
            v_hasta(i) := TRIM(REGEXP_SUBSTR(v_item, '[^~]+', 1, 3));
            IF v_dias(i) IS NULL OR v_dias(i) NOT IN ('LUNES','MARTES','MIERCOLES','JUEVES','VIERNES','SABADO','DOMINGO') THEN
                RAISE_APPLICATION_ERROR(-20302, 'Dia invalido en el horario semanal');
            END IF;
            IF v_desde(i) IS NULL OR v_hasta(i) IS NULL
               OR NOT REGEXP_LIKE(v_desde(i), '^([01][0-9]|2[0-3]):[0-5][0-9]$')
               OR NOT REGEXP_LIKE(v_hasta(i), '^([01][0-9]|2[0-3]):[0-5][0-9]$') THEN
                RAISE_APPLICATION_ERROR(-20302, 'Las horas deben tener formato HH:MM');
            END IF;
            v_min := (TO_NUMBER(SUBSTR(v_hasta(i), 1, 2)) * 60 + TO_NUMBER(SUBSTR(v_hasta(i), 4, 2)))
                   - (TO_NUMBER(SUBSTR(v_desde(i), 1, 2)) * 60 + TO_NUMBER(SUBSTR(v_desde(i), 4, 2)));
            IF v_min < 30 OR v_min > 720 THEN
                RAISE_APPLICATION_ERROR(-20302, 'Cada bloque debe durar entre 30 minutos y 12 horas');
            END IF;
            FOR j IN 1 .. i - 1 LOOP
                IF v_dias(j) = v_dias(i) AND v_desde(j) < v_hasta(i) AND v_hasta(j) > v_desde(i) THEN
                    RAISE_APPLICATION_ERROR(-20302, 'Dos bloques del mismo dia se cruzan (' || v_dias(i) || ')');
                END IF;
            END LOOP;
        END LOOP;

        BEGIN
            SELECT ID_MEDICO INTO v_medico FROM MEDICOS
             WHERE ID_MEDICO = p_id_medico FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20305, 'El medico no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20306, 'Se estan modificando los horarios de este medico, intenta de nuevo');
        END;

        -- Las agendas futuras SIN citas se rehacen; las que ya tienen citas no se tocan
        DELETE FROM AGENDAS_MEDICOS a
         WHERE a.ID_MEDICO = p_id_medico
           AND a.FECHA_HORA_INICIO > LOCALTIMESTAMP
           AND a.ID_ESTADO = v_disp
           AND NOT EXISTS (SELECT 1 FROM CITAS_MEDICAS c WHERE c.ID_AGENDA = a.ID_AGENDA);

        -- Cada bloque se repite en su dia de la semana durante las proximas p_semanas semanas
        p_creadas := 0;
        FOR i IN 1 .. v_n LOOP
            p_creadas := p_creadas + crear_dia(p_id_medico, v_dias(i), v_desde(i), v_hasta(i), TRUNC(SYSDATE) - 1, p_semanas);
        END LOOP;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'GUARDAR_HORARIO_SEMANAL', 'AGENDAS_MEDICOS', p_id_medico,
                NULL, 'medico=' || p_id_medico || '; bloques=' || v_n || '; agendas_creadas=' || p_creadas);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END GUARDAR_HORARIO_SEMANAL;

    PROCEDURE GENERAR_AGENDAS_SEMANALES(
        p_id_medico IN  NUMBER DEFAULT NULL,
        p_semanas   IN  NUMBER DEFAULT 52,
        p_creadas   OUT NUMBER
    ) IS
    BEGIN
        p_creadas := 0;
        -- SKIP LOCKED: si alguien esta guardando el horario de un medico, se salta y queda para la proxima vez
        FOR m IN (SELECT ID_MEDICO FROM MEDICOS
                   WHERE (p_id_medico IS NULL OR ID_MEDICO = p_id_medico)
                     AND ID_MEDICO IN (SELECT ID_MEDICO FROM AGENDAS_MEDICOS WHERE FECHA_HORA_FIN > LOCALTIMESTAMP)
                     FOR UPDATE SKIP LOCKED) LOOP
            -- Patron semanal = mismo dia y mismas horas en 2 o mas fechas futuras distintas.
            -- Solo se extiende hacia adelante desde su ultima fecha (lo que el medico quito en medio no se recrea).
            FOR pat IN (SELECT DIA_SEMANA,
                               TO_CHAR(FECHA_HORA_INICIO, 'HH24:MI') AS DESDE,
                               TO_CHAR(FECHA_HORA_FIN, 'HH24:MI')    AS HASTA,
                               MAX(TRUNC(CAST(FECHA_HORA_INICIO AS DATE))) AS ULTIMA
                          FROM AGENDAS_MEDICOS
                         WHERE ID_MEDICO = m.ID_MEDICO AND FECHA_HORA_FIN > LOCALTIMESTAMP
                         GROUP BY DIA_SEMANA, TO_CHAR(FECHA_HORA_INICIO, 'HH24:MI'), TO_CHAR(FECHA_HORA_FIN, 'HH24:MI')
                        HAVING COUNT(DISTINCT TRUNC(CAST(FECHA_HORA_INICIO AS DATE))) >= 2) LOOP
                p_creadas := p_creadas + crear_dia(m.ID_MEDICO, pat.DIA_SEMANA, pat.DESDE, pat.HASTA, pat.ULTIMA, p_semanas);
            END LOOP;
        END LOOP;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END GENERAR_AGENDAS_SEMANALES;

    PROCEDURE CREAR_AGENDA(
        p_id_medico  IN  NUMBER,
        p_inicio     IN  TIMESTAMP,
        p_fin        IN  TIMESTAMP,
        p_id_usuario IN  NUMBER,
        p_id_agenda  OUT NUMBER
    ) IS
        v_disp     NUMBER := id_param('ESTADO_AGENDA', 'DISPONIBLE');
        v_canc     NUMBER := id_param('ESTADO_CITA', 'CANCELADA');
        v_medico   NUMBER;
        v_cruces   NUMBER;
        v_horas    NUMBER;
        v_dia      VARCHAR2(10);
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        IF p_inicio IS NULL OR p_fin IS NULL THEN
            RAISE_APPLICATION_ERROR(-20302, 'Faltan datos: fecha, hora desde y hora hasta');
        END IF;
        IF p_inicio <= LOCALTIMESTAMP THEN
            RAISE_APPLICATION_ERROR(-20301, 'No se pueden crear horarios en el pasado');
        END IF;
        IF p_fin <= p_inicio OR TRUNC(p_fin) <> TRUNC(p_inicio) THEN
            RAISE_APPLICATION_ERROR(-20302, 'La hora final debe ser posterior a la inicial, el mismo dia');
        END IF;
        v_horas := (CAST(p_fin AS DATE) - CAST(p_inicio AS DATE)) * 24;
        IF v_horas > 12 THEN
            RAISE_APPLICATION_ERROR(-20302, 'Un horario puede durar maximo 12 horas');
        END IF;
        IF v_horas < 0.5 THEN
            RAISE_APPLICATION_ERROR(-20302, 'Un horario debe durar al menos 30 minutos');
        END IF;

        -- Bloquea al medico: dos pedidos a la vez no pueden crear rangos cruzados
        BEGIN
            SELECT ID_MEDICO INTO v_medico FROM MEDICOS
             WHERE ID_MEDICO = p_id_medico FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20305, 'El medico no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20306, 'Se estan modificando los horarios de este medico, intenta de nuevo');
        END;

        -- Cruce con otro rango "vivo": disponible o con citas no canceladas
        SELECT COUNT(*) INTO v_cruces
          FROM AGENDAS_MEDICOS a
         WHERE a.ID_MEDICO = p_id_medico
           AND a.FECHA_HORA_INICIO < p_fin
           AND a.FECHA_HORA_FIN    > p_inicio
           AND (a.ID_ESTADO = v_disp
                OR EXISTS (SELECT 1 FROM CITAS_MEDICAS c
                            WHERE c.ID_AGENDA = a.ID_AGENDA AND c.ID_ESTADO <> v_canc));
        IF v_cruces > 0 THEN
            RAISE_APPLICATION_ERROR(-20307, 'Ya tienes un horario que se cruza con ese rango');
        END IF;

        v_dia := dia_semana(CAST(p_inicio AS DATE));  -- SQL no puede llamar funciones privadas del paquete
        INSERT INTO AGENDAS_MEDICOS (ID_AGENDA, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN, DIA_SEMANA, ID_ESTADO)
        VALUES (SEQ_AGENDAS_MEDICOS.NEXTVAL, p_id_medico, p_inicio, p_fin, v_dia, v_disp)
        RETURNING ID_AGENDA INTO p_id_agenda;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'CREAR_AGENDA', 'AGENDAS_MEDICOS', p_id_agenda,
                NULL,
                'medico=' || p_id_medico || '; ' || TO_CHAR(p_inicio, 'YYYY-MM-DD HH24:MI') || ' a ' || TO_CHAR(p_fin, 'HH24:MI'));

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END CREAR_AGENDA;

    PROCEDURE ELIMINAR_AGENDA(
        p_id_agenda  IN NUMBER,
        p_id_usuario IN NUMBER,
        p_id_medico  IN NUMBER DEFAULT NULL
    ) IS
        v_medico   NUMBER;
        v_inicio   TIMESTAMP;
        v_fin      TIMESTAMP;
        v_citas    NUMBER;
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        BEGIN
            SELECT ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN
              INTO v_medico, v_inicio, v_fin
              FROM AGENDAS_MEDICOS
             WHERE ID_AGENDA = p_id_agenda
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20308, 'El horario no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20306, 'El horario esta siendo modificado, intenta de nuevo');
        END;

        IF p_id_medico IS NOT NULL AND p_id_medico <> v_medico THEN
            RAISE_APPLICATION_ERROR(-20309, 'El horario pertenece a otro medico');
        END IF;

        -- Con la agenda bloqueada nadie puede reservar a la vez (RESERVAR_CITA la bloquea primero)
        SELECT COUNT(*) INTO v_citas FROM CITAS_MEDICAS WHERE ID_AGENDA = p_id_agenda;
        IF v_citas > 0 THEN
            RAISE_APPLICATION_ERROR(-20310, 'Solo se pueden quitar horarios sin citas (ni siquiera canceladas)');
        END IF;

        DELETE FROM AGENDAS_MEDICOS WHERE ID_AGENDA = p_id_agenda;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'ELIMINAR_AGENDA', 'AGENDAS_MEDICOS', p_id_agenda,
                'medico=' || v_medico || '; ' || TO_CHAR(v_inicio, 'YYYY-MM-DD HH24:MI') || ' a ' || TO_CHAR(v_fin, 'HH24:MI'),
                'eliminada');

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END ELIMINAR_AGENDA;

END PKG_AGENDAS;
/
SHOW ERRORS

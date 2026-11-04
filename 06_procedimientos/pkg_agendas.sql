-- =====================================================================
-- PKG_AGENDAS: el medico define sus propios horarios. Inserta y borra filas en AGENDAS_MEDICOS
-- (cada franja queda ligada al ID_MEDICO). No modifica la estructura de ninguna tabla.
-- Cada fila de AGENDAS_MEDICOS es una franja de una cita. Errores: 20301-20399.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_AGENDAS AS

    -- Crea franjas seguidas de p_duracion minutos entre p_inicio y p_fin (mismo dia).
    -- Si el rango no se divide exacto, el sobrante al final no se crea.
    PROCEDURE GENERAR_FRANJAS(
        p_id_medico IN  NUMBER,
        p_inicio    IN  TIMESTAMP,
        p_fin       IN  TIMESTAMP,
        p_duracion  IN  NUMBER,
        p_id_usuario IN NUMBER,
        p_creadas   OUT NUMBER
    );

    -- Borra una franja LIBRE. Si p_id_medico no es NULL, debe ser suya.
    PROCEDURE ELIMINAR_FRANJA(
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

    PROCEDURE GENERAR_FRANJAS(
        p_id_medico  IN  NUMBER,
        p_inicio     IN  TIMESTAMP,
        p_fin        IN  TIMESTAMP,
        p_duracion   IN  NUMBER,
        p_id_usuario IN  NUMBER,
        p_creadas    OUT NUMBER
    ) IS
        v_disp     NUMBER := id_param('ESTADO_AGENDA', 'DISPONIBLE');
        v_medico   NUMBER;
        v_minutos  NUMBER;
        v_n        NUMBER;
        v_cruces   NUMBER;
        v_ini      TIMESTAMP;
        v_id       NUMBER;
        v_primero  NUMBER;
        v_fin_real TIMESTAMP;
        v_dia      VARCHAR2(10);
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        IF p_inicio IS NULL OR p_fin IS NULL OR p_duracion IS NULL THEN
            RAISE_APPLICATION_ERROR(-20302, 'Faltan datos: fecha, hora desde, hora hasta y duracion');
        END IF;
        IF p_inicio <= LOCALTIMESTAMP THEN
            RAISE_APPLICATION_ERROR(-20301, 'No se pueden crear horarios en el pasado');
        END IF;
        IF p_fin <= p_inicio OR TRUNC(p_fin) <> TRUNC(p_inicio) THEN
            RAISE_APPLICATION_ERROR(-20302, 'La hora final debe ser posterior a la inicial, el mismo dia');
        END IF;
        IF p_duracion < 10 OR p_duracion > 120 THEN
            RAISE_APPLICATION_ERROR(-20303, 'La duracion de cada cita debe estar entre 10 y 120 minutos');
        END IF;

        v_minutos := ROUND((CAST(p_fin AS DATE) - CAST(p_inicio AS DATE)) * 24 * 60);
        v_n := FLOOR(v_minutos / p_duracion);
        IF v_n < 1 THEN
            RAISE_APPLICATION_ERROR(-20302, 'El rango es menor que la duracion de una cita');
        END IF;
        IF v_n > 40 THEN
            RAISE_APPLICATION_ERROR(-20304, 'Maximo 40 franjas por vez; reduce el rango o sube la duracion');
        END IF;
        v_fin_real := p_inicio + NUMTODSINTERVAL(v_n * p_duracion, 'MINUTE');

        -- Bloquea al medico: dos pedidos a la vez no pueden crear franjas cruzadas
        BEGIN
            SELECT ID_MEDICO INTO v_medico FROM MEDICOS
             WHERE ID_MEDICO = p_id_medico FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20305, 'El medico no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20306, 'Se estan modificando los horarios de este medico, intenta de nuevo');
        END;

        -- Cruce con franjas libres o con citas vigentes (las canceladas no cuentan)
        SELECT COUNT(*) INTO v_cruces
          FROM AGENDAS_MEDICOS a
         WHERE a.ID_MEDICO = p_id_medico
           AND a.FECHA_HORA_INICIO < v_fin_real
           AND a.FECHA_HORA_FIN    > p_inicio
           AND NOT EXISTS (SELECT 1
                             FROM CITAS_MEDICAS c
                             JOIN PARAMETRICA_TIPOS e ON e.ID_PARAMETRO = c.ID_ESTADO
                            WHERE c.ID_AGENDA = a.ID_AGENDA AND e.VALOR = 'CANCELADA');
        IF v_cruces > 0 THEN
            RAISE_APPLICATION_ERROR(-20307, 'Ya tienes horarios en ese rango; elige otro');
        END IF;

        v_ini := p_inicio;
        -- Todas las franjas son del mismo dia
        v_dia := dia_semana(CAST(p_inicio AS DATE));
        FOR i IN 1 .. v_n LOOP
            INSERT INTO AGENDAS_MEDICOS (ID_AGENDA, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN, DIA_SEMANA, ID_ESTADO)
            VALUES (SEQ_AGENDAS_MEDICOS.NEXTVAL, p_id_medico, v_ini,
                    v_ini + NUMTODSINTERVAL(p_duracion, 'MINUTE'), v_dia, v_disp)
            RETURNING ID_AGENDA INTO v_id;
            IF v_primero IS NULL THEN v_primero := v_id; END IF;
            v_ini := v_ini + NUMTODSINTERVAL(p_duracion, 'MINUTE');
        END LOOP;
        p_creadas := v_n;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'GENERAR_FRANJAS', 'AGENDAS_MEDICOS', v_primero,
                NULL,
                'medico=' || p_id_medico || '; franjas=' || v_n || '; duracion=' || p_duracion || 'min; ' ||
                TO_CHAR(p_inicio, 'YYYY-MM-DD HH24:MI') || ' a ' || TO_CHAR(v_fin_real, 'HH24:MI'));

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END GENERAR_FRANJAS;

    PROCEDURE ELIMINAR_FRANJA(
        p_id_agenda  IN NUMBER,
        p_id_usuario IN NUMBER,
        p_id_medico  IN NUMBER DEFAULT NULL
    ) IS
        v_disp     NUMBER := id_param('ESTADO_AGENDA', 'DISPONIBLE');
        v_estado   NUMBER;
        v_medico   NUMBER;
        v_inicio   TIMESTAMP;
        v_citas    NUMBER;
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        BEGIN
            SELECT ID_ESTADO, ID_MEDICO, FECHA_HORA_INICIO
              INTO v_estado, v_medico, v_inicio
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

        SELECT COUNT(*) INTO v_citas FROM CITAS_MEDICAS WHERE ID_AGENDA = p_id_agenda;
        IF v_estado <> v_disp OR v_citas > 0 THEN
            RAISE_APPLICATION_ERROR(-20310, 'Solo se pueden quitar horarios libres (sin cita)');
        END IF;

        DELETE FROM AGENDAS_MEDICOS WHERE ID_AGENDA = p_id_agenda;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'ELIMINAR_FRANJA', 'AGENDAS_MEDICOS', p_id_agenda,
                'medico=' || v_medico || '; inicio=' || TO_CHAR(v_inicio, 'YYYY-MM-DD HH24:MI'), 'eliminada');

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END ELIMINAR_FRANJA;

END PKG_AGENDAS;
/
SHOW ERRORS
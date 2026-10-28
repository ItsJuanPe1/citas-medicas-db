-- =====================================================================
-- PKG_GESTION_CITAS  (HU01 reservar, HU02 cancelar; luego HU09)
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_GESTION_CITAS AS

    EXC_MEDICO_OCUPADO       EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_MEDICO_OCUPADO,       -20001);
    EXC_AGENDA_INEXISTENTE   EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_AGENDA_INEXISTENTE,   -20002);
    EXC_PACIENTE_INEXISTENTE EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_PACIENTE_INEXISTENTE, -20003);
    EXC_HORARIO_PASADO       EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_HORARIO_PASADO,       -20004);
    EXC_PACIENTE_CON_CRUCE   EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_PACIENTE_CON_CRUCE,   -20005);
    EXC_CITA_INEXISTENTE     EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CITA_INEXISTENTE,     -20006);
    EXC_CITA_NO_CANCELABLE   EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CITA_NO_CANCELABLE,   -20007);
    EXC_CITA_AJENA           EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CITA_AJENA,           -20008);

    -- HU01
    PROCEDURE RESERVAR_CITA(
        p_id_paciente IN  NUMBER,
        p_id_agenda   IN  NUMBER,
        p_id_usuario  IN  NUMBER,
        p_id_cita     OUT NUMBER
    );

    -- HU02. Si p_id_paciente no es NULL, la cita debe ser de ese paciente.
    PROCEDURE CANCELAR_CITA(
        p_id_cita     IN NUMBER,
        p_id_usuario  IN NUMBER,
        p_id_paciente IN NUMBER DEFAULT NULL
    );

END PKG_GESTION_CITAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_GESTION_CITAS AS

    FUNCTION id_param(p_nombre VARCHAR2, p_valor VARCHAR2) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        SELECT ID_PARAMETRO INTO v_id
          FROM PARAMETRICA_TIPOS
         WHERE NOMBRE = p_nombre AND VALOR = p_valor;
        RETURN v_id;
    END id_param;

    ---------------------------------------------------------------- HU01
    PROCEDURE RESERVAR_CITA(
        p_id_paciente IN  NUMBER,
        p_id_agenda   IN  NUMBER,
        p_id_usuario  IN  NUMBER,
        p_id_cita     OUT NUMBER
    ) IS
        v_disp      NUMBER := id_param('ESTADO_AGENDA', 'DISPONIBLE');
        v_ocup      NUMBER := id_param('ESTADO_AGENDA', 'OCUPADA');
        v_prog      NUMBER := id_param('ESTADO_CITA',   'PROGRAMADA');
        v_estado    NUMBER;
        v_inicio    TIMESTAMP;
        v_fin       TIMESTAMP;
        v_existe    NUMBER;
        v_cruces    NUMBER;
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        SELECT COUNT(*) INTO v_existe FROM PACIENTES WHERE ID_PACIENTE = p_id_paciente;
        IF v_existe = 0 THEN
            RAISE_APPLICATION_ERROR(-20003, 'El paciente no existe');
        END IF;

        BEGIN
            SELECT ID_ESTADO, FECHA_HORA_INICIO, FECHA_HORA_FIN
              INTO v_estado, v_inicio, v_fin
              FROM AGENDAS_MEDICOS
             WHERE ID_AGENDA = p_id_agenda
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20002, 'El horario no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20001, 'El horario esta siendo reservado por otra persona, intenta de nuevo');
        END;

        IF v_estado <> v_disp THEN
            RAISE_APPLICATION_ERROR(-20001, 'El horario ya esta ocupado');
        END IF;

        IF v_inicio <= LOCALTIMESTAMP THEN
            RAISE_APPLICATION_ERROR(-20004, 'No se puede reservar un horario que ya paso');
        END IF;

        SELECT COUNT(*) INTO v_cruces
          FROM CITAS_MEDICAS c
          JOIN AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
         WHERE c.ID_PACIENTE = p_id_paciente
           AND c.ID_ESTADO   = v_prog
           AND a.FECHA_HORA_INICIO < v_fin
           AND a.FECHA_HORA_FIN    > v_inicio;
        IF v_cruces > 0 THEN
            RAISE_APPLICATION_ERROR(-20005, 'El paciente ya tiene una cita en ese horario');
        END IF;

        UPDATE AGENDAS_MEDICOS SET ID_ESTADO = v_ocup WHERE ID_AGENDA = p_id_agenda;

        INSERT INTO CITAS_MEDICAS (ID_CITA, ID_PACIENTE, ID_AGENDA, ID_ESTADO)
        VALUES (SEQ_CITAS_MEDICAS.NEXTVAL, p_id_paciente, p_id_agenda, v_prog)
        RETURNING ID_CITA INTO p_id_cita;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'RESERVAR_CITA', 'CITAS_MEDICAS', p_id_cita,
                NULL,
                'id_paciente=' || p_id_paciente || ', id_agenda=' || p_id_agenda || ', estado=PROGRAMADA');

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END RESERVAR_CITA;

    ---------------------------------------------------------------- HU02
    PROCEDURE CANCELAR_CITA(
        p_id_cita     IN NUMBER,
        p_id_usuario  IN NUMBER,
        p_id_paciente IN NUMBER DEFAULT NULL
    ) IS
        v_prog      NUMBER := id_param('ESTADO_CITA',   'PROGRAMADA');
        v_canc      NUMBER := id_param('ESTADO_CITA',   'CANCELADA');
        v_disp      NUMBER := id_param('ESTADO_AGENDA', 'DISPONIBLE');
        v_paciente  NUMBER;
        v_estado    NUMBER;
        v_agenda    NUMBER;
        v_medico    NUMBER;
        v_inicio    TIMESTAMP;
        v_fin       TIMESTAMP;
        v_dia       VARCHAR2(10);
        v_nueva     NUMBER;
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        BEGIN
            SELECT ID_PACIENTE, ID_ESTADO, ID_AGENDA
              INTO v_paciente, v_estado, v_agenda
              FROM CITAS_MEDICAS
             WHERE ID_CITA = p_id_cita
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20006, 'La cita no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20007, 'La cita esta siendo modificada por otra persona, intenta de nuevo');
        END;

        IF p_id_paciente IS NOT NULL AND p_id_paciente <> v_paciente THEN
            RAISE_APPLICATION_ERROR(-20008, 'La cita no pertenece a este paciente');
        END IF;

        IF v_estado <> v_prog THEN
            RAISE_APPLICATION_ERROR(-20007, 'Solo se pueden cancelar citas en estado PROGRAMADA');
        END IF;

        UPDATE CITAS_MEDICAS SET ID_ESTADO = v_canc WHERE ID_CITA = p_id_cita;

        -- La cita cancelada conserva su horario como historial (1 a 1).
        -- Si el horario aun no pasa, se crea uno nuevo DISPONIBLE para volver a reservar.
        SELECT ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN, DIA_SEMANA
          INTO v_medico, v_inicio, v_fin, v_dia
          FROM AGENDAS_MEDICOS
         WHERE ID_AGENDA = v_agenda;

        IF v_inicio > LOCALTIMESTAMP THEN
            INSERT INTO AGENDAS_MEDICOS (ID_AGENDA, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN, DIA_SEMANA, ID_ESTADO)
            VALUES (SEQ_AGENDAS_MEDICOS.NEXTVAL, v_medico, v_inicio, v_fin, v_dia, v_disp)
            RETURNING ID_AGENDA INTO v_nueva;
        END IF;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'CANCELAR_CITA', 'CITAS_MEDICAS', p_id_cita,
                'estado=PROGRAMADA',
                'estado=CANCELADA' || CASE WHEN v_nueva IS NOT NULL THEN ', nuevo_horario=' || v_nueva END);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END CANCELAR_CITA;

END PKG_GESTION_CITAS;
/
SHOW ERRORS

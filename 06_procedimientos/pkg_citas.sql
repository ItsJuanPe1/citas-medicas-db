-- =====================================================================
-- PKG_CITAS  (HU01 - Reserva de citas sin solapamiento)
-- Correr conectado como PROYECTOPLSQL, despues de tablas, datos y secuencias.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_CITAS AS

    -- Errores de negocio (se propagan al back como ORA-200xx)
    EXC_MEDICO_OCUPADO      EXCEPTION;  PRAGMA EXCEPTION_INIT(EXC_MEDICO_OCUPADO,      -20001);
    EXC_AGENDA_INEXISTENTE  EXCEPTION;  PRAGMA EXCEPTION_INIT(EXC_AGENDA_INEXISTENTE,  -20002);
    EXC_PACIENTE_INEXISTENTE EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_PACIENTE_INEXISTENTE, -20003);
    EXC_HORARIO_PASADO      EXCEPTION;  PRAGMA EXCEPTION_INIT(EXC_HORARIO_PASADO,      -20004);
    EXC_PACIENTE_CON_CRUCE  EXCEPTION;  PRAGMA EXCEPTION_INIT(EXC_PACIENTE_CON_CRUCE,  -20005);

    -- Reserva el horario p_id_agenda para el paciente. Hace COMMIT al terminar.
    PROCEDURE RESERVAR_CITA(
        p_id_paciente IN  NUMBER,
        p_id_agenda   IN  NUMBER,
        p_id_usuario  IN  NUMBER,   -- quien reserva (para la auditoria)
        p_id_cita     OUT NUMBER
    );

END PKG_CITAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_CITAS AS

    FUNCTION id_param(p_nombre VARCHAR2, p_valor VARCHAR2) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        SELECT ID_PARAMETRO INTO v_id
          FROM PARAMETRICA_TIPOS
         WHERE NOMBRE = p_nombre AND VALOR = p_valor;
        RETURN v_id;
    END id_param;

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
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);  -- recurso ocupado (timeout del FOR UPDATE)
    BEGIN
        -- El paciente debe existir
        SELECT COUNT(*) INTO v_existe FROM PACIENTES WHERE ID_PACIENTE = p_id_paciente;
        IF v_existe = 0 THEN
            RAISE_APPLICATION_ERROR(-20003, 'El paciente no existe');
        END IF;

        -- Bloqueo pesimista del horario: una segunda sesion espera hasta 5 s
        -- a que la primera haga COMMIT/ROLLBACK y despues lee el estado ya actualizado.
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

        -- El paciente no puede tener otra cita PROGRAMADA que se cruce con este horario
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

END PKG_CITAS;
/
SHOW ERRORS

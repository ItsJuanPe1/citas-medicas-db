-- =====================================================================
-- PKG_GESTION_CITAS  (HU01 reservar, HU02 cancelar; luego HU09)
-- Modelo 1 a N: una agenda es un RANGO de horas del medico (ej. martes 7:00 a 12:00)
-- y puede tener varias citas; cada cita guarda su propia hora de inicio y fin.
-- Estado de la agenda: DISPONIBLE mientras queden minutos libres; OCUPADA cuando las citas
-- (no canceladas) llenan todo el rango. Al cancelar una cita la agenda vuelve a DISPONIBLE.
-- Errores: 20001-20099.
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
    EXC_MOTIVO_OBLIGATORIO   EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_MOTIVO_OBLIGATORIO,   -20009);
    EXC_DURACION_INVALIDA    EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_DURACION_INVALIDA,    -20010);
    EXC_FUERA_DE_AGENDA      EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_FUERA_DE_AGENDA,      -20011);

    -- HU01. p_inicio y p_fin definen la cita y deben caer dentro del rango de la agenda.
    -- Dura entre 10 y 120 minutos. No puede cruzarse con otra cita del medico ni del paciente.
    PROCEDURE RESERVAR_CITA(
        p_id_paciente IN  NUMBER,
        p_id_agenda   IN  NUMBER,
        p_inicio      IN  TIMESTAMP,
        p_fin         IN  TIMESTAMP,
        p_id_usuario  IN  NUMBER,
        p_id_cita     OUT NUMBER
    );

    -- HU02. El motivo es opcional; si se envia, minimo 5 caracteres (se guarda en la auditoria).
    -- Si p_id_paciente no es NULL, la cita debe ser de ese paciente.
    PROCEDURE CANCELAR_CITA(
        p_id_cita     IN NUMBER,
        p_id_usuario  IN NUMBER,
        p_motivo      IN VARCHAR2,
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

    -- Minutos entre dos TIMESTAMP
    FUNCTION minutos(p_ini TIMESTAMP, p_fin TIMESTAMP) RETURN NUMBER IS
    BEGIN
        RETURN ROUND((CAST(p_fin AS DATE) - CAST(p_ini AS DATE)) * 24 * 60);
    END minutos;

    ---------------------------------------------------------------- HU01
    PROCEDURE RESERVAR_CITA(
        p_id_paciente IN  NUMBER,
        p_id_agenda   IN  NUMBER,
        p_inicio      IN  TIMESTAMP,
        p_fin         IN  TIMESTAMP,
        p_id_usuario  IN  NUMBER,
        p_id_cita     OUT NUMBER
    ) IS
        v_disp      NUMBER := id_param('ESTADO_AGENDA', 'DISPONIBLE');
        v_ocup      NUMBER := id_param('ESTADO_AGENDA', 'OCUPADA');
        v_prog      NUMBER := id_param('ESTADO_CITA',   'PROGRAMADA');
        v_canc      NUMBER := id_param('ESTADO_CITA',   'CANCELADA');
        v_est_ag    NUMBER;
        v_medico    NUMBER;
        v_ag_ini    TIMESTAMP;
        v_ag_fin    TIMESTAMP;
        v_existe    NUMBER;
        v_cruces    NUMBER;
        v_min       NUMBER;
        v_usados    NUMBER;
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        IF p_inicio IS NULL OR p_fin IS NULL OR p_fin <= p_inicio THEN
            RAISE_APPLICATION_ERROR(-20010, 'La cita necesita una hora de inicio y una de fin (la fin despues del inicio)');
        END IF;
        v_min := minutos(p_inicio, p_fin);
        IF v_min < 10 OR v_min > 120 THEN
            RAISE_APPLICATION_ERROR(-20010, 'La cita debe durar entre 10 y 120 minutos');
        END IF;

        SELECT COUNT(*) INTO v_existe FROM PACIENTES WHERE ID_PACIENTE = p_id_paciente;
        IF v_existe = 0 THEN
            RAISE_APPLICATION_ERROR(-20003, 'El paciente no existe');
        END IF;

        -- Bloquea la agenda: las reservas de un mismo rango se hacen de a una
        BEGIN
            SELECT ID_ESTADO, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN
              INTO v_est_ag, v_medico, v_ag_ini, v_ag_fin
              FROM AGENDAS_MEDICOS
             WHERE ID_AGENDA = p_id_agenda
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20002, 'El horario no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20001, 'El horario esta siendo reservado por otra persona, intenta de nuevo');
        END;

        IF v_est_ag <> v_disp THEN
            RAISE_APPLICATION_ERROR(-20001, 'El horario del medico ya esta completo');
        END IF;

        IF p_inicio <= LOCALTIMESTAMP THEN
            RAISE_APPLICATION_ERROR(-20004, 'No se puede reservar un horario que ya paso');
        END IF;

        IF p_inicio < v_ag_ini OR p_fin > v_ag_fin THEN
            RAISE_APPLICATION_ERROR(-20011, 'La cita debe quedar dentro del horario del medico');
        END IF;

        -- El medico no puede tener dos citas a la vez (EXC_MEDICO_OCUPADO)
        SELECT COUNT(*) INTO v_cruces
          FROM CITAS_MEDICAS c
          JOIN AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
         WHERE a.ID_MEDICO = v_medico
           AND c.ID_ESTADO <> v_canc
           AND c.FECHA_HORA_INICIO < p_fin
           AND c.FECHA_HORA_FIN    > p_inicio;
        IF v_cruces > 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'El medico ya tiene una cita en ese horario');
        END IF;

        -- Ni el paciente
        SELECT COUNT(*) INTO v_cruces
          FROM CITAS_MEDICAS c
         WHERE c.ID_PACIENTE = p_id_paciente
           AND c.ID_ESTADO   <> v_canc
           AND c.FECHA_HORA_INICIO < p_fin
           AND c.FECHA_HORA_FIN    > p_inicio;
        IF v_cruces > 0 THEN
            RAISE_APPLICATION_ERROR(-20005, 'El paciente ya tiene una cita en ese horario');
        END IF;

        INSERT INTO CITAS_MEDICAS (ID_CITA, ID_PACIENTE, ID_AGENDA, FECHA_HORA_INICIO, FECHA_HORA_FIN, ID_ESTADO)
        VALUES (SEQ_CITAS_MEDICAS.NEXTVAL, p_id_paciente, p_id_agenda, p_inicio, p_fin, v_prog)
        RETURNING ID_CITA INTO p_id_cita;

        -- Si las citas ya llenan todo el rango, la agenda queda OCUPADA
        -- (SQL no puede llamar la funcion privada minutos(), por eso la cuenta va escrita aqui)
        SELECT NVL(SUM(ROUND((CAST(c.FECHA_HORA_FIN AS DATE) - CAST(c.FECHA_HORA_INICIO AS DATE)) * 24 * 60)), 0)
          INTO v_usados
          FROM CITAS_MEDICAS c
         WHERE c.ID_AGENDA = p_id_agenda AND c.ID_ESTADO <> v_canc;
        IF v_usados >= minutos(v_ag_ini, v_ag_fin) THEN
            UPDATE AGENDAS_MEDICOS SET ID_ESTADO = v_ocup WHERE ID_AGENDA = p_id_agenda;
        END IF;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'RESERVAR_CITA', 'CITAS_MEDICAS', p_id_cita,
                NULL,
                'id_paciente=' || p_id_paciente || ', id_agenda=' || p_id_agenda
                || ', cita=' || TO_CHAR(p_inicio, 'YYYY-MM-DD HH24:MI') || ' a ' || TO_CHAR(p_fin, 'HH24:MI')
                || ', estado=PROGRAMADA');

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
        p_motivo      IN VARCHAR2,
        p_id_paciente IN NUMBER DEFAULT NULL
    ) IS
        v_motivo    VARCHAR2(255) := SUBSTR(TRIM(p_motivo), 1, 255);
        v_prog      NUMBER := id_param('ESTADO_CITA',   'PROGRAMADA');
        v_canc      NUMBER := id_param('ESTADO_CITA',   'CANCELADA');
        v_disp      NUMBER := id_param('ESTADO_AGENDA', 'DISPONIBLE');
        v_ocup      NUMBER := id_param('ESTADO_AGENDA', 'OCUPADA');
        v_paciente  NUMBER;
        v_estado    NUMBER;
        v_agenda    NUMBER;
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        IF v_motivo IS NOT NULL AND LENGTH(v_motivo) < 5 THEN
            RAISE_APPLICATION_ERROR(-20009, 'El motivo de la cancelacion debe tener minimo 5 caracteres');
        END IF;

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

        -- Libera el horario: la agenda vuelve a DISPONIBLE y ese tramo se puede reservar de nuevo
        UPDATE AGENDAS_MEDICOS SET ID_ESTADO = v_disp
         WHERE ID_AGENDA = v_agenda AND ID_ESTADO = v_ocup;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'CANCELAR_CITA', 'CITAS_MEDICAS', p_id_cita,
                'estado=PROGRAMADA',
                'estado=CANCELADA' || CASE WHEN v_motivo IS NOT NULL THEN '; motivo=' || v_motivo END);  -- el motivo va al final: el back lo lee con REGEXP

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END CANCELAR_CITA;

END PKG_GESTION_CITAS;
/
SHOW ERRORS

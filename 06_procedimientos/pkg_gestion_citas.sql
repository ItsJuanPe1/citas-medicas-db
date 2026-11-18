-- =====================================================================
-- PKG_GESTION_CITAS  (HU01 reservar, HU02 cancelar, HU09 cancelacion masiva, reprogramacion por cambio de horario)
-- Modelo 1 a N: una agenda es un RANGO de horas del medico (ej. martes 7:00 a 12:00)
-- y puede tener varias citas; cada cita guarda su propia hora de inicio y fin.
-- Estado de la agenda: DISPONIBLE mientras queden minutos libres; OCUPADA cuando las citas
-- (no canceladas) llenan todo el rango. Al cancelar una cita la agenda vuelve a DISPONIBLE.
-- Errores: 20001-20099.
-- Usa PKG_AUDITORIA (compilarlo antes).
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_GESTION_CITAS AS

    EX_MEDICO_OCUPADO       EXCEPTION; PRAGMA EXCEPTION_INIT(EX_MEDICO_OCUPADO,       -20001);
    EX_AGENDA_INEXISTENTE   EXCEPTION; PRAGMA EXCEPTION_INIT(EX_AGENDA_INEXISTENTE,   -20002);
    EX_PACIENTE_INEXISTENTE EXCEPTION; PRAGMA EXCEPTION_INIT(EX_PACIENTE_INEXISTENTE, -20003);
    EX_HORARIO_PASADO       EXCEPTION; PRAGMA EXCEPTION_INIT(EX_HORARIO_PASADO,       -20004);
    EX_PACIENTE_CON_CRUCE   EXCEPTION; PRAGMA EXCEPTION_INIT(EX_PACIENTE_CON_CRUCE,   -20005);
    EX_CITA_INEXISTENTE     EXCEPTION; PRAGMA EXCEPTION_INIT(EX_CITA_INEXISTENTE,     -20006);
    EX_CITA_NO_CANCELABLE   EXCEPTION; PRAGMA EXCEPTION_INIT(EX_CITA_NO_CANCELABLE,   -20007);
    EX_CITA_AJENA           EXCEPTION; PRAGMA EXCEPTION_INIT(EX_CITA_AJENA,           -20008);
    EX_MOTIVO_OBLIGATORIO   EXCEPTION; PRAGMA EXCEPTION_INIT(EX_MOTIVO_OBLIGATORIO,   -20009);
    EX_DURACION_INVALIDA    EXCEPTION; PRAGMA EXCEPTION_INIT(EX_DURACION_INVALIDA,    -20010);
    EX_FUERA_DE_AGENDA      EXCEPTION; PRAGMA EXCEPTION_INIT(EX_FUERA_DE_AGENDA,      -20011);
    EX_MEDICO_INEXISTENTE   EXCEPTION; PRAGMA EXCEPTION_INIT(EX_MEDICO_INEXISTENTE,   -20012);
    EX_FECHA_INVALIDA       EXCEPTION; PRAGMA EXCEPTION_INIT(EX_FECHA_INVALIDA,       -20013);

    -- HU01. pt_inicio y pt_fin definen la cita y deben caer dentro del rango de la agenda.
    -- Dura entre 10 y 120 minutos. No puede cruzarse con otra cita del medico ni del paciente.
    PROCEDURE PRO_RESERVAR_CITA(
        pn_id_paciente IN  NUMBER,
        pn_id_agenda   IN  NUMBER,
        pt_inicio      IN  TIMESTAMP,
        pt_fin         IN  TIMESTAMP,
        pn_id_usuario  IN  NUMBER,
        pn_id_cita     OUT NUMBER
    );

    -- HU02. El motivo es opcional; si se envia, minimo 5 caracteres (se guarda en la auditoria).
    -- Si pn_id_paciente no es NULL, la cita debe ser de ese paciente.
    PROCEDURE PRO_CANCELAR_CITA(
        pn_id_cita     IN NUMBER,
        pn_id_usuario  IN NUMBER,
        ps_motivo      IN VARCHAR2,
        pn_id_paciente IN NUMBER DEFAULT NULL
    );

    -- HU09. Cancela todas las citas PROGRAMADAS de un medico en una fecha (BULK COLLECT + FORALL),
    -- deja la trazabilidad en la bitacora y bloquea las agendas de ese dia (quedan OCUPADA) para
    -- que nadie reserve con un medico que no va a atender. El motivo es opcional (minimo 5 caracteres).
    -- pn_canceladas devuelve cuantas citas se cancelaron (puede ser 0).
    PROCEDURE PRO_CANCELAR_CITAS_MEDICO(
        pn_id_medico  IN  NUMBER,
        pd_fecha      IN  DATE,
        ps_motivo     IN  VARCHAR2,
        pn_id_usuario IN  NUMBER,
        pn_canceladas OUT NUMBER
    );

    -- Reprogramacion. El medico cambio su horario y esta agenda ya no existe: cada cita PROGRAMADA
    -- de la agenda pasa al SIGUIENTE DIA LIBRE del mismo medico (a la misma hora si esta libre ese dia;
    -- si no, a la primera hora libre). Se busca hasta 60 dias adelante, sin cruzar citas del medico
    -- ni del paciente. Si no hay hueco, la cita se cancela con un motivo que lo explica.
    -- En ambos casos queda una fila en la bitacora (REPROGRAMAR_CITA o CANCELAR_CITA) con la
    -- explicacion al final ('motivo=...'), que el paciente ve en "Mis citas".
    -- Al terminar la agenda se borra si quedo sin citas; si conserva citas canceladas queda OCUPADA.
    -- pn_confirmar = 1 hace COMMIT (uso directo); 0 lo deja a quien llama (PKG_AGENDAS).
    PROCEDURE PRO_REPROGRAMAR_AGENDA(
        pn_id_agenda     IN  NUMBER,
        pn_id_usuario    IN  NUMBER,
        pn_reprogramadas OUT NUMBER,
        pn_canceladas    OUT NUMBER,
        pn_confirmar     IN  NUMBER DEFAULT 1
    );

END PKG_GESTION_CITAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_GESTION_CITAS AS

    FUNCTION FN_ID_PARAM(ps_nombre VARCHAR2, ps_valor VARCHAR2) RETURN NUMBER IS
        vn_id NUMBER;
    BEGIN
        SELECT ID_PARAMETRO INTO vn_id
          FROM TBL_PARAMETRICA_TIPOS
         WHERE NOMBRE = ps_nombre AND VALOR = ps_valor;
        RETURN vn_id;
    END FN_ID_PARAM;

    -- Minutos entre dos TIMESTAMP
    FUNCTION FN_MINUTOS(pt_ini TIMESTAMP, pt_fin TIMESTAMP) RETURN NUMBER IS
    BEGIN
        RETURN ROUND((CAST(pt_fin AS DATE) - CAST(pt_ini AS DATE)) * 24 * 60);
    END FN_MINUTOS;

    ---------------------------------------------------------------- HU01
    PROCEDURE PRO_RESERVAR_CITA(
        pn_id_paciente IN  NUMBER,
        pn_id_agenda   IN  NUMBER,
        pt_inicio      IN  TIMESTAMP,
        pt_fin         IN  TIMESTAMP,
        pn_id_usuario  IN  NUMBER,
        pn_id_cita     OUT NUMBER
    ) IS
        vn_disp      NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'DISPONIBLE');
        vn_ocup      NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'OCUPADA');
        vn_prog      NUMBER := FN_ID_PARAM('ESTADO_CITA',   'PROGRAMADA');
        vn_canc      NUMBER := FN_ID_PARAM('ESTADO_CITA',   'CANCELADA');
        vn_est_ag    NUMBER;
        vn_medico    NUMBER;
        vt_ag_ini    TIMESTAMP;
        vt_ag_fin    TIMESTAMP;
        vn_existe    NUMBER;
        vn_cruces    NUMBER;
        vn_min       NUMBER;
        vn_usados    NUMBER;
        ex_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        IF pt_inicio IS NULL OR pt_fin IS NULL OR pt_fin <= pt_inicio THEN
            RAISE_APPLICATION_ERROR(-20010, 'La cita necesita una hora de inicio y una de fin (la fin despues del inicio)');
        END IF;
        vn_min := FN_MINUTOS(pt_inicio, pt_fin);
        IF vn_min <> 60 THEN
            RAISE_APPLICATION_ERROR(-20010, 'Cada cita dura exactamente 1 hora');
        END IF;

        SELECT COUNT(*) INTO vn_existe FROM TBL_PACIENTES WHERE ID_PACIENTE = pn_id_paciente;
        IF vn_existe = 0 THEN
            RAISE_APPLICATION_ERROR(-20003, 'El paciente no existe');
        END IF;

        -- Bloquea la agenda: las reservas de un mismo rango se hacen de a una
        BEGIN
            SELECT ID_ESTADO, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN
              INTO vn_est_ag, vn_medico, vt_ag_ini, vt_ag_fin
              FROM TBL_AGENDAS_MEDICOS
             WHERE ID_AGENDA = pn_id_agenda
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20002, 'El horario no existe');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20001, 'El horario esta siendo reservado por otra persona, intenta de nuevo');
        END;

        IF vn_est_ag <> vn_disp THEN
            RAISE_APPLICATION_ERROR(-20001, 'El horario del medico ya esta completo');
        END IF;

        IF pt_inicio <= LOCALTIMESTAMP THEN
            RAISE_APPLICATION_ERROR(-20004, 'No se puede reservar un horario que ya paso');
        END IF;

        IF pt_inicio < vt_ag_ini OR pt_fin > vt_ag_fin THEN
            RAISE_APPLICATION_ERROR(-20011, 'La cita debe quedar dentro del horario del medico');
        END IF;

        -- El medico no puede tener dos citas a la vez (EX_MEDICO_OCUPADO)
        SELECT COUNT(*) INTO vn_cruces
          FROM TBL_CITAS_MEDICAS c
          JOIN TBL_AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
         WHERE a.ID_MEDICO = vn_medico
           AND c.ID_ESTADO <> vn_canc
           AND c.FECHA_HORA_INICIO < pt_fin
           AND c.FECHA_HORA_FIN    > pt_inicio;
        IF vn_cruces > 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'El medico ya tiene una cita en ese horario');
        END IF;

        -- Ni el paciente
        SELECT COUNT(*) INTO vn_cruces
          FROM TBL_CITAS_MEDICAS c
         WHERE c.ID_PACIENTE = pn_id_paciente
           AND c.ID_ESTADO   <> vn_canc
           AND c.FECHA_HORA_INICIO < pt_fin
           AND c.FECHA_HORA_FIN    > pt_inicio;
        IF vn_cruces > 0 THEN
            RAISE_APPLICATION_ERROR(-20005, 'El paciente ya tiene una cita en ese horario');
        END IF;

        INSERT INTO TBL_CITAS_MEDICAS (ID_CITA, ID_PACIENTE, ID_AGENDA, FECHA_HORA_INICIO, FECHA_HORA_FIN, ID_ESTADO)
        VALUES (SEQ_TBL_CITAS_MEDICAS.NEXTVAL, pn_id_paciente, pn_id_agenda, pt_inicio, pt_fin, vn_prog)
        RETURNING ID_CITA INTO pn_id_cita;

        -- Si las citas ya llenan todo el rango, la agenda queda OCUPADA
        -- (SQL no puede llamar la funcion privada minutos(), por eso la cuenta va escrita aqui)
        SELECT NVL(SUM(ROUND((CAST(c.FECHA_HORA_FIN AS DATE) - CAST(c.FECHA_HORA_INICIO AS DATE)) * 24 * 60)), 0)
          INTO vn_usados
          FROM TBL_CITAS_MEDICAS c
         WHERE c.ID_AGENDA = pn_id_agenda AND c.ID_ESTADO <> vn_canc;
        IF vn_usados >= FN_MINUTOS(vt_ag_ini, vt_ag_fin) THEN
            UPDATE TBL_AGENDAS_MEDICOS SET ID_ESTADO = vn_ocup WHERE ID_AGENDA = pn_id_agenda;
        END IF;

        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'RESERVAR_CITA', 'TBL_CITAS_MEDICAS', pn_id_cita,
                NULL,
                'id_paciente=' || pn_id_paciente || ', id_agenda=' || pn_id_agenda
                || ', cita=' || TO_CHAR(pt_inicio, 'YYYY-MM-DD HH24:MI') || ' a ' || TO_CHAR(pt_fin, 'HH24:MI')
                || ', estado=PROGRAMADA');

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_RESERVAR_CITA;

    ---------------------------------------------------------------- HU02
    PROCEDURE PRO_CANCELAR_CITA(
        pn_id_cita     IN NUMBER,
        pn_id_usuario  IN NUMBER,
        ps_motivo      IN VARCHAR2,
        pn_id_paciente IN NUMBER DEFAULT NULL
    ) IS
        vs_motivo    VARCHAR2(255) := SUBSTR(TRIM(ps_motivo), 1, 255);
        vn_prog      NUMBER := FN_ID_PARAM('ESTADO_CITA',   'PROGRAMADA');
        vn_canc      NUMBER := FN_ID_PARAM('ESTADO_CITA',   'CANCELADA');
        vn_disp      NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'DISPONIBLE');
        vn_ocup      NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'OCUPADA');
        vn_paciente  NUMBER;
        vn_estado    NUMBER;
        vn_agenda    NUMBER;
        ex_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        IF vs_motivo IS NOT NULL AND LENGTH(vs_motivo) < 5 THEN
            RAISE_APPLICATION_ERROR(-20009, 'El motivo de la cancelacion debe tener minimo 5 caracteres');
        END IF;

        BEGIN
            SELECT ID_PACIENTE, ID_ESTADO, ID_AGENDA
              INTO vn_paciente, vn_estado, vn_agenda
              FROM TBL_CITAS_MEDICAS
             WHERE ID_CITA = pn_id_cita
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20006, 'La cita no existe');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20007, 'La cita esta siendo modificada por otra persona, intenta de nuevo');
        END;

        IF pn_id_paciente IS NOT NULL AND pn_id_paciente <> vn_paciente THEN
            RAISE_APPLICATION_ERROR(-20008, 'La cita no pertenece a este paciente');
        END IF;

        IF vn_estado <> vn_prog THEN
            RAISE_APPLICATION_ERROR(-20007, 'Solo se pueden cancelar citas en estado PROGRAMADA');
        END IF;

        UPDATE TBL_CITAS_MEDICAS SET ID_ESTADO = vn_canc WHERE ID_CITA = pn_id_cita;

        -- Libera el horario: la agenda vuelve a DISPONIBLE y ese tramo se puede reservar de nuevo
        UPDATE TBL_AGENDAS_MEDICOS SET ID_ESTADO = vn_disp
         WHERE ID_AGENDA = vn_agenda AND ID_ESTADO = vn_ocup;

        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'CANCELAR_CITA', 'TBL_CITAS_MEDICAS', pn_id_cita,
                'estado=PROGRAMADA',
                'estado=CANCELADA' || CASE WHEN vs_motivo IS NOT NULL THEN '; motivo=' || vs_motivo END);  -- el motivo va al final: el back lo lee con REGEXP

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_CANCELAR_CITA;

    ---------------------------------------------------------------- HU09
    PROCEDURE PRO_CANCELAR_CITAS_MEDICO(
        pn_id_medico  IN  NUMBER,
        pd_fecha      IN  DATE,
        ps_motivo     IN  VARCHAR2,
        pn_id_usuario IN  NUMBER,
        pn_canceladas OUT NUMBER
    ) IS
        TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
        vc_citas     t_ids;
        vd_dia       DATE := TRUNC(pd_fecha);
        vs_motivo    VARCHAR2(255) := SUBSTR(TRIM(ps_motivo), 1, 255);
        vs_despues   VARCHAR2(500);
        vn_prog      NUMBER := FN_ID_PARAM('ESTADO_CITA',   'PROGRAMADA');
        vn_canc      NUMBER := FN_ID_PARAM('ESTADO_CITA',   'CANCELADA');
        vn_disp      NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'DISPONIBLE');
        vn_ocup      NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'OCUPADA');
        vn_existe    NUMBER;
        vn_bloqueadas NUMBER;
        ex_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        IF vd_dia IS NULL OR vd_dia < TRUNC(SYSDATE) THEN
            RAISE_APPLICATION_ERROR(-20013, 'La fecha debe ser hoy o una fecha futura');
        END IF;
        IF vs_motivo IS NOT NULL AND LENGTH(vs_motivo) < 5 THEN
            RAISE_APPLICATION_ERROR(-20009, 'El motivo debe tener minimo 5 caracteres');
        END IF;

        SELECT COUNT(*) INTO vn_existe FROM TBL_MEDICOS WHERE ID_MEDICO = pn_id_medico;
        IF vn_existe = 0 THEN
            RAISE_APPLICATION_ERROR(-20012, 'El medico no existe');
        END IF;

        -- Trae y bloquea de una vez todas las citas programadas del medico ese dia
        BEGIN
            SELECT c.ID_CITA
              BULK COLLECT INTO vc_citas
              FROM TBL_CITAS_MEDICAS c
              JOIN TBL_AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
             WHERE a.ID_MEDICO = pn_id_medico
               AND c.ID_ESTADO = vn_prog
               AND c.FECHA_HORA_INICIO >= vd_dia
               AND c.FECHA_HORA_INICIO <  vd_dia + 1
             ORDER BY c.ID_CITA
               FOR UPDATE OF c.ID_ESTADO WAIT 5;
        EXCEPTION
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20007, 'Hay citas de ese dia en uso por otra persona, intenta de nuevo');
        END;

        pn_canceladas := vc_citas.COUNT;
        vs_despues := 'estado=CANCELADA; motivo=Inasistencia del medico'
                      || CASE WHEN vs_motivo IS NOT NULL THEN ': ' || vs_motivo END;

        IF vc_citas.COUNT > 0 THEN
            FORALL vn_i IN 1 .. vc_citas.COUNT
                UPDATE TBL_CITAS_MEDICAS SET ID_ESTADO = vn_canc WHERE ID_CITA = vc_citas(vn_i);

            -- una fila por cita, con la misma accion que HU02: el paciente ve el motivo en su pantalla
            FORALL vn_i IN 1 .. vc_citas.COUNT
                INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
                VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'CANCELAR_CITA', 'TBL_CITAS_MEDICAS',
                        vc_citas(vn_i), 'estado=PROGRAMADA', vs_despues);
        END IF;

        -- Las agendas de ese dia dejan de estar disponibles
        UPDATE TBL_AGENDAS_MEDICOS SET ID_ESTADO = vn_ocup
         WHERE ID_MEDICO = pn_id_medico
           AND FECHA_HORA_INICIO >= vd_dia AND FECHA_HORA_INICIO < vd_dia + 1
           AND ID_ESTADO = vn_disp;
        vn_bloqueadas := SQL%ROWCOUNT;

        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'CANCELACION_MASIVA', 'TBL_AGENDAS_MEDICOS', pn_id_medico,
                'citas programadas=' || pn_canceladas,
                'fecha=' || TO_CHAR(vd_dia, 'YYYY-MM-DD') || '; canceladas=' || pn_canceladas
                || '; agendas bloqueadas=' || vn_bloqueadas
                || CASE WHEN vs_motivo IS NOT NULL THEN '; motivo=' || vs_motivo END);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_CANCELAR_CITAS_MEDICO;

    ---------------------------------------------------------------- Reprogramacion
    -- Primer hueco libre del medico desde el dia siguiente a pt_original. Prefiere la misma hora del dia;
    -- si ese dia no esta libre a esa hora, toma la primera hora libre del dia. Deja bloqueadas las agendas
    -- revisadas (FOR UPDATE SKIP LOCKED) para que nadie reserve mientras se mueve la cita.
    PROCEDURE PRO_BUSCAR_HUECO(
        pn_medico          IN  NUMBER,
        pn_paciente        IN  NUMBER,
        pn_cita            IN  NUMBER,
        pt_original        IN  TIMESTAMP,
        pn_minutos         IN  NUMBER,
        pn_agenda_excluida IN  NUMBER,
        pn_agenda          OUT NUMBER,
        pt_hueco           OUT TIMESTAMP
    ) IS
        cn_dias_busqueda CONSTANT NUMBER := 60;
        vn_disp      NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'DISPONIBLE');
        vn_canc      NUMBER := FN_ID_PARAM('ESTADO_CITA',   'CANCELADA');
        vd_primero   DATE := TRUNC(CAST(pt_original AS DATE)) + 1;
        vd_dia       DATE;
        vs_hora_pref VARCHAR2(5) := TO_CHAR(pt_original, 'HH24:MI');
        vn_alt       NUMBER;
        vt_alt       TIMESTAMP;
        vt           TIMESTAMP;

        FUNCTION FN_LIBRE(pt_ini TIMESTAMP) RETURN BOOLEAN IS
            vt_fin TIMESTAMP := pt_ini + NUMTODSINTERVAL(pn_minutos, 'MINUTE');
            vn_n   NUMBER;
        BEGIN
            SELECT COUNT(*) INTO vn_n
              FROM TBL_CITAS_MEDICAS c
              JOIN TBL_AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
             WHERE a.ID_MEDICO = pn_medico AND c.ID_ESTADO <> vn_canc
               AND c.ID_CITA <> pn_cita
               AND c.FECHA_HORA_INICIO < vt_fin AND c.FECHA_HORA_FIN > pt_ini;
            IF vn_n > 0 THEN RETURN FALSE; END IF;
            SELECT COUNT(*) INTO vn_n
              FROM TBL_CITAS_MEDICAS c
             WHERE c.ID_PACIENTE = pn_paciente AND c.ID_ESTADO <> vn_canc
               AND c.ID_CITA <> pn_cita
               AND c.FECHA_HORA_INICIO < vt_fin AND c.FECHA_HORA_FIN > pt_ini;
            RETURN vn_n = 0;
        END FN_LIBRE;
    BEGIN
        pn_agenda := NULL;
        pt_hueco  := NULL;
        FOR vr_ag IN (SELECT ID_AGENDA, FECHA_HORA_INICIO, FECHA_HORA_FIN
                        FROM TBL_AGENDAS_MEDICOS
                       WHERE ID_MEDICO = pn_medico
                         AND ID_ESTADO = vn_disp
                         AND ID_AGENDA <> pn_agenda_excluida
                         AND FECHA_HORA_INICIO >= vd_primero
                         AND FECHA_HORA_INICIO <  vd_primero + cn_dias_busqueda
                         AND FECHA_HORA_INICIO >  LOCALTIMESTAMP
                       ORDER BY FECHA_HORA_INICIO
                         FOR UPDATE OF ID_ESTADO SKIP LOCKED) LOOP
            -- cambio de dia: si el dia anterior tuvo algun hueco, ese es el siguiente dia libre
            IF vd_dia IS NOT NULL AND TRUNC(CAST(vr_ag.FECHA_HORA_INICIO AS DATE)) <> vd_dia AND vn_alt IS NOT NULL THEN
                EXIT;
            END IF;
            vd_dia := TRUNC(CAST(vr_ag.FECHA_HORA_INICIO AS DATE));
            vt := vr_ag.FECHA_HORA_INICIO;
            WHILE vt + NUMTODSINTERVAL(pn_minutos, 'MINUTE') <= vr_ag.FECHA_HORA_FIN LOOP
                IF FN_LIBRE(vt) THEN
                    IF TO_CHAR(vt, 'HH24:MI') = vs_hora_pref THEN
                        pn_agenda := vr_ag.ID_AGENDA;
                        pt_hueco  := vt;
                        RETURN;
                    END IF;
                    IF vn_alt IS NULL THEN
                        vn_alt := vr_ag.ID_AGENDA;
                        vt_alt := vt;
                    END IF;
                END IF;
                vt := vt + NUMTODSINTERVAL(pn_minutos, 'MINUTE');
            END LOOP;
        END LOOP;
        pn_agenda := vn_alt;
        pt_hueco  := vt_alt;
    END PRO_BUSCAR_HUECO;

    PROCEDURE PRO_REPROGRAMAR_AGENDA(
        pn_id_agenda     IN  NUMBER,
        pn_id_usuario    IN  NUMBER,
        pn_reprogramadas OUT NUMBER,
        pn_canceladas    OUT NUMBER,
        pn_confirmar     IN  NUMBER DEFAULT 1
    ) IS
        vn_prog      NUMBER := FN_ID_PARAM('ESTADO_CITA',   'PROGRAMADA');
        vn_canc      NUMBER := FN_ID_PARAM('ESTADO_CITA',   'CANCELADA');
        vn_ocup      NUMBER := FN_ID_PARAM('ESTADO_AGENDA', 'OCUPADA');
        vn_medico    NUMBER;
        vn_nueva     NUMBER;
        vt_nuevo     TIMESTAMP;
        vt_ag_ini    TIMESTAMP;
        vt_ag_fin    TIMESTAMP;
        vn_minutos   NUMBER;
        vn_usados    NUMBER;
        vn_resto     NUMBER;
        vs_motivo    VARCHAR2(500);
        cs_fmt       CONSTANT VARCHAR2(20) := 'DD/MM/YYYY HH24:MI';
        ex_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        pn_reprogramadas := 0;
        pn_canceladas    := 0;

        BEGIN
            SELECT ID_MEDICO INTO vn_medico FROM TBL_AGENDAS_MEDICOS
             WHERE ID_AGENDA = pn_id_agenda FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20002, 'El horario no existe');
        END;

        FOR vr_c IN (SELECT ID_CITA, ID_PACIENTE, FECHA_HORA_INICIO, FECHA_HORA_FIN
                       FROM TBL_CITAS_MEDICAS
                      WHERE ID_AGENDA = pn_id_agenda AND ID_ESTADO = vn_prog
                      ORDER BY FECHA_HORA_INICIO
                        FOR UPDATE OF ID_ESTADO WAIT 5) LOOP

            PRO_BUSCAR_HUECO(vn_medico, vr_c.ID_PACIENTE, vr_c.ID_CITA, vr_c.FECHA_HORA_INICIO,
                             FN_MINUTOS(vr_c.FECHA_HORA_INICIO, vr_c.FECHA_HORA_FIN), pn_id_agenda,
                             vn_nueva, vt_nuevo);

            IF vn_nueva IS NOT NULL THEN
                UPDATE TBL_CITAS_MEDICAS
                   SET ID_AGENDA = vn_nueva,
                       FECHA_HORA_INICIO = vt_nuevo,
                       FECHA_HORA_FIN = vt_nuevo + (vr_c.FECHA_HORA_FIN - vr_c.FECHA_HORA_INICIO)
                 WHERE ID_CITA = vr_c.ID_CITA;

                -- la agenda que recibe la cita pasa a OCUPADA si ya quedo llena
                SELECT FECHA_HORA_INICIO, FECHA_HORA_FIN INTO vt_ag_ini, vt_ag_fin
                  FROM TBL_AGENDAS_MEDICOS WHERE ID_AGENDA = vn_nueva;
                vn_minutos := FN_MINUTOS(vt_ag_ini, vt_ag_fin);
                SELECT NVL(SUM(ROUND((CAST(c.FECHA_HORA_FIN AS DATE) - CAST(c.FECHA_HORA_INICIO AS DATE)) * 24 * 60)), 0)
                  INTO vn_usados
                  FROM TBL_CITAS_MEDICAS c
                 WHERE c.ID_AGENDA = vn_nueva AND c.ID_ESTADO <> vn_canc;
                IF vn_usados >= vn_minutos THEN
                    UPDATE TBL_AGENDAS_MEDICOS SET ID_ESTADO = vn_ocup WHERE ID_AGENDA = vn_nueva;
                END IF;

                vs_motivo := 'El medico cambio su horario. Tu cita del ' || TO_CHAR(vr_c.FECHA_HORA_INICIO, cs_fmt)
                             || ' paso al ' || TO_CHAR(vt_nuevo, cs_fmt) || ', el siguiente dia con horario libre';
                PKG_AUDITORIA.PRO_REGISTRAR('REPROGRAMAR_CITA', 'TBL_CITAS_MEDICAS', vr_c.ID_CITA,
                    'id_agenda=' || pn_id_agenda || '; cita=' || TO_CHAR(vr_c.FECHA_HORA_INICIO, 'YYYY-MM-DD HH24:MI'),
                    'id_agenda=' || vn_nueva || '; cita=' || TO_CHAR(vt_nuevo, 'YYYY-MM-DD HH24:MI') || '; motivo=' || vs_motivo,
                    pn_id_usuario);
                pn_reprogramadas := pn_reprogramadas + 1;
            ELSE
                UPDATE TBL_CITAS_MEDICAS SET ID_ESTADO = vn_canc WHERE ID_CITA = vr_c.ID_CITA;
                vs_motivo := 'El medico cambio su horario y no hay otro horario libre en los proximos 60 dias para tu cita del '
                             || TO_CHAR(vr_c.FECHA_HORA_INICIO, cs_fmt) || '. Reserva una nueva cita';
                PKG_AUDITORIA.PRO_REGISTRAR('CANCELAR_CITA', 'TBL_CITAS_MEDICAS', vr_c.ID_CITA,
                    'estado=PROGRAMADA', 'estado=CANCELADA; motivo=' || vs_motivo, pn_id_usuario);
                pn_canceladas := pn_canceladas + 1;
            END IF;
        END LOOP;

        -- La agenda vieja: sin citas se borra; con citas canceladas se deja OCUPADA para que nadie la reserve
        SELECT COUNT(*) INTO vn_resto FROM TBL_CITAS_MEDICAS WHERE ID_AGENDA = pn_id_agenda;
        IF vn_resto = 0 THEN
            DELETE FROM TBL_AGENDAS_MEDICOS WHERE ID_AGENDA = pn_id_agenda;
        ELSE
            UPDATE TBL_AGENDAS_MEDICOS SET ID_ESTADO = vn_ocup WHERE ID_AGENDA = pn_id_agenda;
        END IF;

        IF pn_confirmar = 1 THEN
            COMMIT;
        END IF;
    EXCEPTION
        WHEN ex_bloqueado THEN
            IF pn_confirmar = 1 THEN ROLLBACK; END IF;
            RAISE_APPLICATION_ERROR(-20007, 'Hay citas en uso por otra persona, intenta de nuevo');
        WHEN OTHERS THEN
            IF pn_confirmar = 1 THEN ROLLBACK; END IF;
            RAISE;
    END PRO_REPROGRAMAR_AGENDA;

END PKG_GESTION_CITAS;
/
SHOW ERRORS

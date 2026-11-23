-- =====================================================================
-- PKG_REPORTES  (HU10 reporte en lote de atencion y prescripcion)
-- Solo lee: no modifica ninguna tabla. Errores: 20601-20699.
-- Usa cursores explicitos (totales del periodo) y un SYS_REFCURSOR (detalle por medico).
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_REPORTES AS

    EX_PERIODO_INVALIDO EXCEPTION; PRAGMA EXCEPTION_INIT(EX_PERIODO_INVALIDO, -20601);
    EX_PERIODO_LARGO    EXCEPTION; PRAGMA EXCEPTION_INIT(EX_PERIODO_LARGO,    -20602);

    -- Resumen del periodo [pd_desde, pd_hasta] (ambos dias incluidos, maximo 366 dias).
    -- Las citas se cuentan por su fecha de inicio y las recetas por su fecha de emision.
    -- pc_medicos: una fila por medico con sus citas atendidas, canceladas, no asistio,
    -- programadas y las recetas emitidas (ordenado por citas atendidas).
    PROCEDURE PRO_REPORTE_PERIODO(
        pd_desde              IN  DATE,
        pd_hasta              IN  DATE,
        pn_programadas        OUT NUMBER,
        pn_atendidas          OUT NUMBER,
        pn_canceladas         OUT NUMBER,
        pn_no_asistio         OUT NUMBER,
        pn_recetas            OUT NUMBER,
        pn_rec_entregadas     OUT NUMBER,
        pn_rec_parciales      OUT NUMBER,
        pn_rec_no_entregadas  OUT NUMBER,
        pc_medicos            OUT SYS_REFCURSOR
    );

END PKG_REPORTES;
/

CREATE OR REPLACE PACKAGE BODY PKG_REPORTES AS

    PROCEDURE PRO_REPORTE_PERIODO(
        pd_desde              IN  DATE,
        pd_hasta              IN  DATE,
        pn_programadas        OUT NUMBER,
        pn_atendidas          OUT NUMBER,
        pn_canceladas         OUT NUMBER,
        pn_no_asistio         OUT NUMBER,
        pn_recetas            OUT NUMBER,
        pn_rec_entregadas     OUT NUMBER,
        pn_rec_parciales      OUT NUMBER,
        pn_rec_no_entregadas  OUT NUMBER,
        pc_medicos            OUT SYS_REFCURSOR
    ) IS
        vd_ini DATE;
        vd_fin DATE;   -- primer dia FUERA del periodo

        -- Citas del periodo agrupadas por estado
        CURSOR vc_citas_estado IS
            SELECT e.VALOR AS ESTADO, COUNT(*) AS TOTAL
              FROM TBL_CITAS_MEDICAS c
              JOIN TBL_PARAMETRICA_TIPOS e ON e.ID_PARAMETRO = c.ID_ESTADO
             WHERE c.FECHA_HORA_INICIO >= vd_ini AND c.FECHA_HORA_INICIO < vd_fin
             GROUP BY e.VALOR;

        -- Recetas emitidas en el periodo agrupadas por estado
        CURSOR vc_recetas_estado IS
            SELECT e.VALOR AS ESTADO, COUNT(*) AS TOTAL
              FROM TBL_RECETAS_MEDICAS r
              JOIN TBL_PARAMETRICA_TIPOS e ON e.ID_PARAMETRO = r.ID_ESTADO
             WHERE r.FECHA_EMISION >= vd_ini AND r.FECHA_EMISION < vd_fin
             GROUP BY e.VALOR;
    BEGIN
        IF pd_desde IS NULL OR pd_hasta IS NULL OR TRUNC(pd_hasta) < TRUNC(pd_desde) THEN
            RAISE_APPLICATION_ERROR(-20601, 'El periodo no es valido: indica las dos fechas y que la final no sea anterior a la inicial');
        END IF;
        IF TRUNC(pd_hasta) - TRUNC(pd_desde) > 365 THEN
            RAISE_APPLICATION_ERROR(-20602, 'El periodo no puede ser mayor a 366 dias');
        END IF;
        vd_ini := TRUNC(pd_desde);
        vd_fin := TRUNC(pd_hasta) + 1;

        pn_programadas := 0; pn_atendidas := 0; pn_canceladas := 0; pn_no_asistio := 0;
        pn_recetas := 0; pn_rec_entregadas := 0; pn_rec_parciales := 0; pn_rec_no_entregadas := 0;

        FOR vr_c IN vc_citas_estado LOOP
            CASE vr_c.ESTADO
                WHEN 'PROGRAMADA' THEN pn_programadas := vr_c.TOTAL;
                WHEN 'ATENDIDA'   THEN pn_atendidas   := vr_c.TOTAL;
                WHEN 'CANCELADA'  THEN pn_canceladas  := vr_c.TOTAL;
                WHEN 'NO_ASISTIO' THEN pn_no_asistio  := vr_c.TOTAL;
                ELSE NULL;
            END CASE;
        END LOOP;

        FOR vr_r IN vc_recetas_estado LOOP
            pn_recetas := pn_recetas + vr_r.TOTAL;
            CASE vr_r.ESTADO
                WHEN 'ENTREGADA'    THEN pn_rec_entregadas    := vr_r.TOTAL;
                WHEN 'PARCIALMENTE' THEN pn_rec_parciales     := vr_r.TOTAL;
                WHEN 'NO ENTREGADA' THEN pn_rec_no_entregadas := vr_r.TOTAL;
                ELSE NULL;
            END CASE;
        END LOOP;

        -- Detalle por medico (el back lo recorre fila por fila)
        OPEN pc_medicos FOR
            SELECT m.ID_MEDICO,
                   m.NOMBRE || ' ' || m.APELLIDO AS MEDICO,
                   esp.VALOR AS ESPECIALIDAD,
                   COUNT(CASE WHEN e.VALOR = 'ATENDIDA'   THEN 1 END) AS ATENDIDAS,
                   COUNT(CASE WHEN e.VALOR = 'CANCELADA'  THEN 1 END) AS CANCELADAS,
                   COUNT(CASE WHEN e.VALOR = 'NO_ASISTIO' THEN 1 END) AS NO_ASISTIO,
                   COUNT(CASE WHEN e.VALOR = 'PROGRAMADA' THEN 1 END) AS PROGRAMADAS,
                   NVL(rec.TOTAL_RECETAS, 0) AS RECETAS
              FROM TBL_MEDICOS m
              JOIN TBL_PARAMETRICA_TIPOS esp ON esp.ID_PARAMETRO = m.ID_ESPECIALIDAD
              LEFT JOIN TBL_AGENDAS_MEDICOS a ON a.ID_MEDICO = m.ID_MEDICO
              LEFT JOIN TBL_CITAS_MEDICAS c   ON c.ID_AGENDA = a.ID_AGENDA
                                             AND c.FECHA_HORA_INICIO >= vd_ini AND c.FECHA_HORA_INICIO < vd_fin
              LEFT JOIN TBL_PARAMETRICA_TIPOS e ON e.ID_PARAMETRO = c.ID_ESTADO
              LEFT JOIN (
                  SELECT a2.ID_MEDICO, COUNT(*) AS TOTAL_RECETAS
                    FROM TBL_RECETAS_MEDICAS r
                    JOIN TBL_HISTORIA_CLINICA h ON h.ID_HISTORIA = r.ID_HISTORIA
                    JOIN TBL_CITAS_MEDICAS c2   ON c2.ID_CITA = h.ID_CITA
                    JOIN TBL_AGENDAS_MEDICOS a2 ON a2.ID_AGENDA = c2.ID_AGENDA
                   WHERE r.FECHA_EMISION >= vd_ini AND r.FECHA_EMISION < vd_fin
                   GROUP BY a2.ID_MEDICO
              ) rec ON rec.ID_MEDICO = m.ID_MEDICO
             GROUP BY m.ID_MEDICO, m.NOMBRE, m.APELLIDO, esp.VALOR, rec.TOTAL_RECETAS
             ORDER BY ATENDIDAS DESC, MEDICO;
    END PRO_REPORTE_PERIODO;

END PKG_REPORTES;
/
SHOW ERRORS

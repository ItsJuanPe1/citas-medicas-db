-- =====================================================================
-- HU04: no se puede crear una historia clinica de una cita que no este PROGRAMADA.
-- Red de seguridad: aunque alguien inserte directo en HISTORIA_CLINICA (sin pasar por
-- PKG_HISTORIAS_CLINICAS.REGISTRAR_CONSULTA), la regla se cumple. Errores: 20107, 20108, 20109 (cita que aun no inicia).
-- No modifica la estructura de ninguna tabla.
-- =====================================================================
CREATE OR REPLACE TRIGGER TRG_HISTORIA_CITA_PROGRAMADA
BEFORE INSERT ON HISTORIA_CLINICA
FOR EACH ROW
DECLARE
    v_estado VARCHAR2(100);
    v_inicio TIMESTAMP;
BEGIN
    BEGIN
        SELECT e.VALOR, c.FECHA_HORA_INICIO
          INTO v_estado, v_inicio
          FROM CITAS_MEDICAS c
          JOIN PARAMETRICA_TIPOS e ON e.ID_PARAMETRO = c.ID_ESTADO
         WHERE c.ID_CITA = :NEW.ID_CITA;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20107, 'No se puede crear la historia: la cita no existe');
    END;

    IF v_estado <> 'PROGRAMADA' THEN
        RAISE_APPLICATION_ERROR(-20108,
            'No se puede crear la historia: la cita esta ' || v_estado || ' y debe estar PROGRAMADA');
    END IF;

    IF v_inicio > LOCALTIMESTAMP THEN
        RAISE_APPLICATION_ERROR(-20109, 'No se puede crear la historia: la cita aun no ha iniciado');
    END IF;
END TRG_HISTORIA_CITA_PROGRAMADA;
/
SHOW ERRORS

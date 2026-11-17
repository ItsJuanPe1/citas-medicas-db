-- =====================================================================
-- HU06: alerta de stock minimo.
-- Cuando un UPDATE BAJA la cantidad disponible y deja el stock por debajo de
-- CANTIDAD_MINIMA, se inserta una alerta en TBL_LOG_AUDITORIAS.
-- Solo alerta al bajar (no al reponer) para no llenar el log con cada cambio.
-- ID_USUARIO = 0 (sistema), igual que las demas filas automaticas.
-- No modifica la estructura de ninguna tabla.
-- =====================================================================
CREATE OR REPLACE TRIGGER TRG_STOCK_MINIMO
AFTER UPDATE OF CANTIDAD_DISPONIBLE ON TBL_STOCK_FARMACIA
FOR EACH ROW
WHEN (NEW.CANTIDAD_DISPONIBLE < NEW.CANTIDAD_MINIMA
      AND NEW.CANTIDAD_DISPONIBLE < OLD.CANTIDAD_DISPONIBLE)
DECLARE
    vs_nombre TBL_MEDICAMENTOS.NOMBRE%TYPE;
BEGIN
    BEGIN
        SELECT NOMBRE INTO vs_nombre
          FROM TBL_MEDICAMENTOS
         WHERE ID_MEDICAMENTO = :NEW.ID_MEDICAMENTO;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN vs_nombre := 'ID ' || :NEW.ID_MEDICAMENTO;
    END;

    INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
    VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, 0, 'ALERTA_STOCK_MINIMO', 'TBL_STOCK_FARMACIA', :NEW.ID_STOCK,
            'Disponible: ' || :OLD.CANTIDAD_DISPONIBLE,
            SUBSTR('Stock bajo el minimo: ' || vs_nombre || ' | disponible ' || :NEW.CANTIDAD_DISPONIBLE
                   || ' | minimo ' || :NEW.CANTIDAD_MINIMA, 1, 4000));
END TRG_STOCK_MINIMO;
/
SHOW ERRORS

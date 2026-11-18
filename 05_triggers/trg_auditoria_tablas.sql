-- =====================================================================
-- Auditoria de tablas sensibles (medicamentos, stock, recetas y detalle de receta).
-- Cada INSERT, UPDATE o DELETE arma el valor anterior (:OLD) y el nuevo (:NEW) y llama a
-- PKG_AUDITORIA.PRO_REGISTRAR, que es quien escribe en TBL_LOG_AUDITORIAS. ACCION = INSERT / UPDATE / DELETE; TABLA_AFECTADA dice la tabla.
-- El usuario sale del contexto CTX_CITAS (PKG_AUDITORIA.FN_USUARIO_ACTUAL); sin contexto queda 0 = sistema.
-- Un UPDATE que no cambia ningun valor no genera fila.
-- Las historias clinicas se auditan en TRG_HISTORIA_AUDITORIA (HU08).
-- Correr DESPUES de PKG_AUDITORIA y de cargar los datos (si no, la carga masiva llena la bitacora).
-- =====================================================================

CREATE OR REPLACE TRIGGER TRG_AUD_MEDICAMENTOS
AFTER INSERT OR UPDATE OR DELETE ON TBL_MEDICAMENTOS
FOR EACH ROW
DECLARE
    vs_accion  VARCHAR2(10);
    vn_id      NUMBER;
    vs_antes   VARCHAR2(4000);
    vs_despues VARCHAR2(4000);
BEGIN
    IF INSERTING THEN
        vs_accion := 'INSERT'; vn_id := :NEW.ID_MEDICAMENTO;
    ELSIF UPDATING THEN
        vs_accion := 'UPDATE'; vn_id := :NEW.ID_MEDICAMENTO;
    ELSE
        vs_accion := 'DELETE'; vn_id := :OLD.ID_MEDICAMENTO;
    END IF;

    IF NOT INSERTING THEN
        vs_antes := SUBSTR('id_tipo=' || :OLD.ID_TIPO_MEDICAMENTO
                  || '; nombre=' || :OLD.NOMBRE
                  || '; descripcion=' || :OLD.DESCRIPCION
                  || '; presentacion=' || :OLD.PRESENTACION, 1, 4000);
    END IF;
    IF NOT DELETING THEN
        vs_despues := SUBSTR('id_tipo=' || :NEW.ID_TIPO_MEDICAMENTO
                  || '; nombre=' || :NEW.NOMBRE
                  || '; descripcion=' || :NEW.DESCRIPCION
                  || '; presentacion=' || :NEW.PRESENTACION, 1, 4000);
    END IF;

    IF UPDATING AND vs_antes = vs_despues THEN
        RETURN;
    END IF;

    PKG_AUDITORIA.PRO_REGISTRAR(vs_accion, 'TBL_MEDICAMENTOS', vn_id, vs_antes, vs_despues);
END TRG_AUD_MEDICAMENTOS;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER TRG_AUD_STOCK_FARMACIA
AFTER INSERT OR UPDATE OR DELETE ON TBL_STOCK_FARMACIA
FOR EACH ROW
DECLARE
    vs_accion  VARCHAR2(10);
    vn_id      NUMBER;
    vs_antes   VARCHAR2(4000);
    vs_despues VARCHAR2(4000);
BEGIN
    IF INSERTING THEN
        vs_accion := 'INSERT'; vn_id := :NEW.ID_STOCK;
    ELSIF UPDATING THEN
        vs_accion := 'UPDATE'; vn_id := :NEW.ID_STOCK;
    ELSE
        vs_accion := 'DELETE'; vn_id := :OLD.ID_STOCK;
    END IF;

    IF NOT INSERTING THEN
        vs_antes := SUBSTR('id_medicamento=' || :OLD.ID_MEDICAMENTO
                  || '; disponible=' || :OLD.CANTIDAD_DISPONIBLE
                  || '; minimo=' || :OLD.CANTIDAD_MINIMA, 1, 4000);
    END IF;
    IF NOT DELETING THEN
        vs_despues := SUBSTR('id_medicamento=' || :NEW.ID_MEDICAMENTO
                  || '; disponible=' || :NEW.CANTIDAD_DISPONIBLE
                  || '; minimo=' || :NEW.CANTIDAD_MINIMA, 1, 4000);
    END IF;

    IF UPDATING AND vs_antes = vs_despues THEN
        RETURN;
    END IF;

    PKG_AUDITORIA.PRO_REGISTRAR(vs_accion, 'TBL_STOCK_FARMACIA', vn_id, vs_antes, vs_despues);
END TRG_AUD_STOCK_FARMACIA;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER TRG_AUD_RECETAS_MEDICAS
AFTER INSERT OR UPDATE OR DELETE ON TBL_RECETAS_MEDICAS
FOR EACH ROW
DECLARE
    vs_accion  VARCHAR2(10);
    vn_id      NUMBER;
    vs_antes   VARCHAR2(4000);
    vs_despues VARCHAR2(4000);
BEGIN
    IF INSERTING THEN
        vs_accion := 'INSERT'; vn_id := :NEW.ID_RECETA;
    ELSIF UPDATING THEN
        vs_accion := 'UPDATE'; vn_id := :NEW.ID_RECETA;
    ELSE
        vs_accion := 'DELETE'; vn_id := :OLD.ID_RECETA;
    END IF;

    IF NOT INSERTING THEN
        vs_antes := SUBSTR('id_historia=' || :OLD.ID_HISTORIA
                  || '; id_estado=' || :OLD.ID_ESTADO
                  || '; emision=' || TO_CHAR(:OLD.FECHA_EMISION, 'YYYY-MM-DD HH24:MI'), 1, 4000);
    END IF;
    IF NOT DELETING THEN
        vs_despues := SUBSTR('id_historia=' || :NEW.ID_HISTORIA
                  || '; id_estado=' || :NEW.ID_ESTADO
                  || '; emision=' || TO_CHAR(:NEW.FECHA_EMISION, 'YYYY-MM-DD HH24:MI'), 1, 4000);
    END IF;

    IF UPDATING AND vs_antes = vs_despues THEN
        RETURN;
    END IF;

    PKG_AUDITORIA.PRO_REGISTRAR(vs_accion, 'TBL_RECETAS_MEDICAS', vn_id, vs_antes, vs_despues);
END TRG_AUD_RECETAS_MEDICAS;
/
SHOW ERRORS

CREATE OR REPLACE TRIGGER TRG_AUD_DETALLE_RECETA
AFTER INSERT OR UPDATE OR DELETE ON TBL_DETALLE_RECETA
FOR EACH ROW
DECLARE
    vs_accion  VARCHAR2(10);
    vn_id      NUMBER;
    vs_antes   VARCHAR2(4000);
    vs_despues VARCHAR2(4000);
BEGIN
    IF INSERTING THEN
        vs_accion := 'INSERT'; vn_id := :NEW.ID_DETALLE;
    ELSIF UPDATING THEN
        vs_accion := 'UPDATE'; vn_id := :NEW.ID_DETALLE;
    ELSE
        vs_accion := 'DELETE'; vn_id := :OLD.ID_DETALLE;
    END IF;

    IF NOT INSERTING THEN
        vs_antes := SUBSTR('id_receta=' || :OLD.ID_RECETA
                  || '; id_medicamento=' || :OLD.ID_MEDICAMENTO
                  || '; id_farmaceutico=' || :OLD.ID_FARMACEUTICO
                  || '; id_estado=' || :OLD.ID_ESTADO
                  || '; cantidad=' || :OLD.CANTIDAD
                  || '; pendiente=' || :OLD.CANTIDAD_PENDIENTE
                  || '; dosis=' || :OLD.DOSIS, 1, 4000);
    END IF;
    IF NOT DELETING THEN
        vs_despues := SUBSTR('id_receta=' || :NEW.ID_RECETA
                  || '; id_medicamento=' || :NEW.ID_MEDICAMENTO
                  || '; id_farmaceutico=' || :NEW.ID_FARMACEUTICO
                  || '; id_estado=' || :NEW.ID_ESTADO
                  || '; cantidad=' || :NEW.CANTIDAD
                  || '; pendiente=' || :NEW.CANTIDAD_PENDIENTE
                  || '; dosis=' || :NEW.DOSIS, 1, 4000);
    END IF;

    IF UPDATING AND vs_antes = vs_despues THEN
        RETURN;
    END IF;

    PKG_AUDITORIA.PRO_REGISTRAR(vs_accion, 'TBL_DETALLE_RECETA', vn_id, vs_antes, vs_despues);
END TRG_AUD_DETALLE_RECETA;
/
SHOW ERRORS

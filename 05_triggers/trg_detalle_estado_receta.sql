-- =====================================================================
-- Calcula el ESTADO_RECETA de la receta cada vez que cambia un TBL_DETALLE_RECETA:
--   todo pendiente        -> NO ENTREGADA
--   nada pendiente        -> ENTREGADA
--   mezcla                -> PARCIALMENTE
-- Trigger compuesto: junta las recetas tocadas por fila y recalcula al final de la
-- sentencia (asi no lee TBL_DETALLE_RECETA mientras cambia: evita ORA-04091).
-- No modifica la estructura de ninguna tabla.
-- =====================================================================
CREATE OR REPLACE TRIGGER TRG_DETALLE_ESTADO_RECETA
FOR INSERT OR UPDATE ON TBL_DETALLE_RECETA
COMPOUND TRIGGER

    TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    vc_recetas t_ids;

    AFTER EACH ROW IS
    BEGIN
        vc_recetas(NVL(vc_recetas.LAST, 0) + 1) := :NEW.ID_RECETA;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        vn_total NUMBER;
        vn_sin   NUMBER;
        vn_todo  NUMBER;
        vn_nuevo NUMBER;
    BEGIN
        FOR vn_i IN 1 .. vc_recetas.COUNT LOOP
            SELECT COUNT(*),
                   NVL(SUM(CASE WHEN CANTIDAD_PENDIENTE = CANTIDAD THEN 1 ELSE 0 END), 0),
                   NVL(SUM(CASE WHEN CANTIDAD_PENDIENTE = 0        THEN 1 ELSE 0 END), 0)
              INTO vn_total, vn_sin, vn_todo
              FROM TBL_DETALLE_RECETA
             WHERE ID_RECETA = vc_recetas(vn_i);

            SELECT ID_PARAMETRO INTO vn_nuevo
              FROM TBL_PARAMETRICA_TIPOS
             WHERE NOMBRE = 'ESTADO_RECETA'
               AND VALOR = CASE WHEN vn_todo = vn_total THEN 'ENTREGADA'
                                WHEN vn_sin  = vn_total THEN 'NO ENTREGADA'
                                ELSE 'PARCIALMENTE' END;

            UPDATE TBL_RECETAS_MEDICAS
               SET ID_ESTADO = vn_nuevo
             WHERE ID_RECETA = vc_recetas(vn_i) AND ID_ESTADO <> vn_nuevo;
        END LOOP;
        vc_recetas.DELETE;
    END AFTER STATEMENT;

END TRG_DETALLE_ESTADO_RECETA;
/
SHOW ERRORS

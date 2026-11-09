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
    g_recetas t_ids;

    AFTER EACH ROW IS
    BEGIN
        g_recetas(NVL(g_recetas.LAST, 0) + 1) := :NEW.ID_RECETA;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_total NUMBER;
        v_sin   NUMBER;
        v_todo  NUMBER;
        v_nuevo NUMBER;
    BEGIN
        FOR i IN 1 .. g_recetas.COUNT LOOP
            SELECT COUNT(*),
                   NVL(SUM(CASE WHEN CANTIDAD_PENDIENTE = CANTIDAD THEN 1 ELSE 0 END), 0),
                   NVL(SUM(CASE WHEN CANTIDAD_PENDIENTE = 0        THEN 1 ELSE 0 END), 0)
              INTO v_total, v_sin, v_todo
              FROM TBL_DETALLE_RECETA
             WHERE ID_RECETA = g_recetas(i);

            SELECT ID_PARAMETRO INTO v_nuevo
              FROM TBL_PARAMETRICA_TIPOS
             WHERE NOMBRE = 'ESTADO_RECETA'
               AND VALOR = CASE WHEN v_todo = v_total THEN 'ENTREGADA'
                                WHEN v_sin  = v_total THEN 'NO ENTREGADA'
                                ELSE 'PARCIALMENTE' END;

            UPDATE TBL_RECETAS_MEDICAS
               SET ID_ESTADO = v_nuevo
             WHERE ID_RECETA = g_recetas(i) AND ID_ESTADO <> v_nuevo;
        END LOOP;
        g_recetas.DELETE;
    END AFTER STATEMENT;

END TRG_DETALLE_ESTADO_RECETA;
/
SHOW ERRORS

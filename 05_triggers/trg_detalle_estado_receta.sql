-- =====================================================================
-- TRG_DETALLE_ESTADO_RECETA
-- Recalcula el ID_ESTADO en TBL_RECETAS_MEDICAS cuando cambia un TBL_DETALLE_RECETA.
-- =====================================================================
CREATE OR REPLACE TRIGGER TRG_DETALLE_ESTADO_RECETA
FOR INSERT OR UPDATE ON TBL_DETALLE_RECETA
COMPOUND TRIGGER

    -- Colección indexada por ID_RECETA para deduplicar automáticamente
    TYPE t_recetas_map IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER;
    g_recetas t_recetas_map;

    AFTER EACH ROW IS
    BEGIN
        IF :NEW.ID_RECETA IS NOT NULL THEN
            g_recetas(:NEW.ID_RECETA) := TRUE;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_idx   PLS_INTEGER;
        v_total NUMBER;
        v_sin   NUMBER;
        v_todo  NUMBER;
        v_nuevo NUMBER;
    BEGIN
        v_idx := g_recetas.FIRST;
        
        WHILE v_idx IS NOT NULL LOOP
            -- Conteo de detalles de la receta actual
            SELECT COUNT(*),
                   NVL(SUM(CASE WHEN CANTIDAD_PENDIENTE = CANTIDAD THEN 1 ELSE 0 END), 0),
                   NVL(SUM(CASE WHEN CANTIDAD_PENDIENTE = 0        THEN 1 ELSE 0 END), 0)
              INTO v_total, v_sin, v_todo
              FROM TBL_DETALLE_RECETA
             WHERE ID_RECETA = v_idx;

            IF v_total > 0 THEN
                -- Obtiene el ID del estado paramétrico correspondiente
                SELECT ID_PARAMETRO INTO v_nuevo
                  FROM TBL_PARAMETRICA_TIPOS
                 WHERE NOMBRE = 'ESTADO_RECETA'
                   AND VALOR = CASE WHEN v_todo = v_total THEN 'ENTREGADA'
                                    WHEN v_sin  = v_total THEN 'NO ENTREGADA'
                                    ELSE 'PARCIALMENTE' END;

                -- Actualiza la receta solo si el estado cambió
                UPDATE TBL_RECETAS_MEDICAS
                   SET ID_ESTADO = v_nuevo
                 WHERE ID_RECETA = v_idx 
                   AND (ID_ESTADO IS NULL OR ID_ESTADO <> v_nuevo);
            END IF;

            v_idx := g_recetas.NEXT(v_idx);
        END LOOP;

        g_recetas.DELETE;
    END AFTER STATEMENT;

END TRG_DETALLE_ESTADO_RECETA;
/
SHOW ERRORS;

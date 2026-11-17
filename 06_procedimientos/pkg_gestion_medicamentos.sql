-- =====================================================================
-- PKG_GESTION_MEDICAMENTOS  (HU05 prescribir y entregar; luego HU06 stock minimo)
-- Inserta en TBL_RECETAS_MEDICAS y TBL_DETALLE_RECETA, y descuenta TBL_STOCK_FARMACIA.
-- No modifica la estructura de ninguna tabla. Errores: 20201-20299.
--   - PRESCRIBIR_RECETA: el medico crea la receta de una historia clinica (no toca el stock).
--   - ENTREGAR_MEDICAMENTO: el farmaceutico entrega y se descuenta el stock con FOR UPDATE.
--     Si el stock no alcanza se entrega parcial y queda CANTIDAD_PENDIENTE.
-- El estado de la receta lo calcula TRG_DETALLE_ESTADO_RECETA.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_GESTION_MEDICAMENTOS AS

    EX_HISTORIA_NO_EXISTE   EXCEPTION; PRAGMA EXCEPTION_INIT(EX_HISTORIA_NO_EXISTE,   -20201);
    EX_HISTORIA_OTRO_MEDICO EXCEPTION; PRAGMA EXCEPTION_INIT(EX_HISTORIA_OTRO_MEDICO, -20202);
    EX_RECETA_YA_EXISTE     EXCEPTION; PRAGMA EXCEPTION_INIT(EX_RECETA_YA_EXISTE,     -20203);
    EX_RECETA_INVALIDA      EXCEPTION; PRAGMA EXCEPTION_INIT(EX_RECETA_INVALIDA,      -20204);
    EX_MEDICAMENTO_NO_EXISTE EXCEPTION; PRAGMA EXCEPTION_INIT(EX_MEDICAMENTO_NO_EXISTE, -20205);
    EX_DETALLE_NO_EXISTE    EXCEPTION; PRAGMA EXCEPTION_INIT(EX_DETALLE_NO_EXISTE,    -20206);
    EX_SIN_STOCK            EXCEPTION; PRAGMA EXCEPTION_INIT(EX_SIN_STOCK,            -20207);
    EX_YA_ENTREGADO         EXCEPTION; PRAGMA EXCEPTION_INIT(EX_YA_ENTREGADO,         -20208);
    EX_BLOQUEADO            EXCEPTION; PRAGMA EXCEPTION_INIT(EX_BLOQUEADO,            -20209);
    EX_CANTIDAD_INVALIDA    EXCEPTION; PRAGMA EXCEPTION_INIT(EX_CANTIDAD_INVALIDA,    -20210);

    -- ps_items: medicamentos separados por '|', y cada uno como id~cantidad~dosis
    --          ej.: '3~2~1 cada 8 horas|7~1~una al dia'   (maximo 20, sin repetir medicamento)
    -- Si pn_id_medico no es NULL, la historia debe ser de una cita de ese medico.
    PROCEDURE PRO_PRESCRIBIR_RECETA(
        pn_id_historia IN  NUMBER,
        ps_items       IN  VARCHAR2,
        pn_id_usuario  IN  NUMBER,
        pn_id_receta   OUT NUMBER,
        pn_id_medico   IN  NUMBER DEFAULT NULL
    );

    -- Entrega y descuenta del stock. pn_cantidad = cuantas unidades entregar (entrega parcial);
    -- NULL = todo lo pendiente, o lo que alcance en stock.
    PROCEDURE PRO_ENTREGAR_MEDICAMENTO(
        pn_id_detalle      IN  NUMBER,
        pn_id_usuario      IN  NUMBER,
        pn_id_farmaceutico IN  NUMBER,        -- NULL si lo hace el superadmin
        pn_entregadas      OUT NUMBER,
        pn_pendientes      OUT NUMBER,
        pn_cantidad        IN  NUMBER DEFAULT NULL
    );

END PKG_GESTION_MEDICAMENTOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_GESTION_MEDICAMENTOS AS

    FUNCTION FN_ID_PARAM(ps_nombre VARCHAR2, ps_valor VARCHAR2) RETURN NUMBER IS
        vn_id NUMBER;
    BEGIN
        SELECT ID_PARAMETRO INTO vn_id
          FROM TBL_PARAMETRICA_TIPOS
         WHERE NOMBRE = ps_nombre AND VALOR = ps_valor;
        RETURN vn_id;
    END FN_ID_PARAM;

    ------------------------------------------------------------ PRESCRIBIR
    PROCEDURE PRO_PRESCRIBIR_RECETA(
        pn_id_historia IN  NUMBER,
        ps_items       IN  VARCHAR2,
        pn_id_usuario  IN  NUMBER,
        pn_id_receta   OUT NUMBER,
        pn_id_medico   IN  NUMBER DEFAULT NULL
    ) IS
        vn_no_entregada NUMBER := FN_ID_PARAM('ESTADO_RECETA', 'NO ENTREGADA');
        vn_det_no       NUMBER := FN_ID_PARAM('ESTADO_DETALLE_RECETA', 'NO ENTREGADO');
        vn_medico       NUMBER;
        vn_existe       NUMBER;
        vn_n            NUMBER;
        vs_item         VARCHAR2(400);
        vn_id_med       NUMBER;
        vn_cant         NUMBER;
        vs_dosis        VARCHAR2(100);
        vs_vistos       VARCHAR2(4000) := ':';
        ex_bloqueado    EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        -- Bloquea la historia: dos recetas simultaneas para la misma historia no pueden pasar
        BEGIN
            SELECT a.ID_MEDICO
              INTO vn_medico
              FROM TBL_HISTORIA_CLINICA h
              JOIN TBL_CITAS_MEDICAS c   ON c.ID_CITA   = h.ID_CITA
              JOIN TBL_AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
             WHERE h.ID_HISTORIA = pn_id_historia
               FOR UPDATE OF h.ID_HISTORIA WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20201, 'La historia clinica no existe');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20209, 'Se esta modificando esta historia, intenta de nuevo');
        END;

        IF pn_id_medico IS NOT NULL AND pn_id_medico <> vn_medico THEN
            RAISE_APPLICATION_ERROR(-20202, 'La historia pertenece a otro medico');
        END IF;

        SELECT COUNT(*) INTO vn_existe FROM TBL_RECETAS_MEDICAS WHERE ID_HISTORIA = pn_id_historia;
        IF vn_existe > 0 THEN
            RAISE_APPLICATION_ERROR(-20203, 'Esta consulta ya tiene una receta');
        END IF;

        vn_n := CASE WHEN ps_items IS NULL THEN 0 ELSE REGEXP_COUNT(ps_items, '[^|]+') END;
        IF vn_n < 1 THEN
            RAISE_APPLICATION_ERROR(-20204, 'La receta debe tener al menos un medicamento');
        END IF;
        IF vn_n > 20 THEN
            RAISE_APPLICATION_ERROR(-20204, 'Una receta puede tener maximo 20 medicamentos');
        END IF;

        INSERT INTO TBL_RECETAS_MEDICAS (ID_RECETA, ID_HISTORIA, ID_ESTADO)
        VALUES (SEQ_TBL_RECETAS_MEDICAS.NEXTVAL, pn_id_historia, vn_no_entregada)
        RETURNING ID_RECETA INTO pn_id_receta;

        FOR vn_i IN 1 .. vn_n LOOP
            vs_item := REGEXP_SUBSTR(ps_items, '[^|]+', 1, vn_i);
            BEGIN
                vn_id_med := TO_NUMBER(REGEXP_SUBSTR(vs_item, '[^~]+', 1, 1));
                vn_cant   := TO_NUMBER(REGEXP_SUBSTR(vs_item, '[^~]+', 1, 2));
            EXCEPTION
                WHEN VALUE_ERROR OR INVALID_NUMBER THEN
                    RAISE_APPLICATION_ERROR(-20204, 'Formato de medicamentos invalido');
            END;
            vs_dosis := SUBSTR(TRIM(REGEXP_SUBSTR(vs_item, '[^~]+', 1, 3)), 1, 100);

            IF vn_id_med IS NULL OR vn_cant IS NULL THEN
                RAISE_APPLICATION_ERROR(-20204, 'Formato de medicamentos invalido');
            END IF;
            IF vn_cant < 1 OR vn_cant > 99999 OR vn_cant <> TRUNC(vn_cant) THEN
                RAISE_APPLICATION_ERROR(-20210, 'La cantidad debe ser un entero entre 1 y 99999');
            END IF;
            IF INSTR(vs_vistos, ':' || vn_id_med || ':') > 0 THEN
                RAISE_APPLICATION_ERROR(-20204, 'Un medicamento no puede repetirse en la misma receta');
            END IF;
            vs_vistos := vs_vistos || vn_id_med || ':';

            SELECT COUNT(*) INTO vn_existe FROM TBL_MEDICAMENTOS WHERE ID_MEDICAMENTO = vn_id_med;
            IF vn_existe = 0 THEN
                RAISE_APPLICATION_ERROR(-20205, 'El medicamento ' || vn_id_med || ' no existe');
            END IF;

            INSERT INTO TBL_DETALLE_RECETA (ID_DETALLE, ID_RECETA, ID_MEDICAMENTO, ID_ESTADO,
                                        CANTIDAD, CANTIDAD_PENDIENTE, DOSIS)
            VALUES (SEQ_TBL_DETALLE_RECETA.NEXTVAL, pn_id_receta, vn_id_med, vn_det_no,
                    vn_cant, vn_cant, vs_dosis);
        END LOOP;

        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'PRESCRIBIR_RECETA', 'TBL_RECETAS_MEDICAS', pn_id_receta,
                NULL, 'id_historia=' || pn_id_historia || '; medicamentos=' || vn_n);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_PRESCRIBIR_RECETA;

    ------------------------------------------------------------ ENTREGAR
    PROCEDURE PRO_ENTREGAR_MEDICAMENTO(
        pn_id_detalle      IN  NUMBER,
        pn_id_usuario      IN  NUMBER,
        pn_id_farmaceutico IN  NUMBER,
        pn_entregadas      OUT NUMBER,
        pn_pendientes      OUT NUMBER,
        pn_cantidad        IN  NUMBER DEFAULT NULL
    ) IS
        vn_entregado NUMBER := FN_ID_PARAM('ESTADO_DETALLE_RECETA', 'ENTREGADO');
        vn_med       NUMBER;
        vn_pend      NUMBER;
        vn_disp      NUMBER;
        ex_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        -- Siempre en este orden: primero el detalle, luego el stock (evita bloqueos cruzados)
        BEGIN
            SELECT ID_MEDICAMENTO, CANTIDAD_PENDIENTE
              INTO vn_med, vn_pend
              FROM TBL_DETALLE_RECETA
             WHERE ID_DETALLE = pn_id_detalle
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20206, 'El medicamento de la receta no existe');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20209, 'Este medicamento se esta entregando en otro puesto, intenta de nuevo');
        END;

        IF vn_pend = 0 THEN
            RAISE_APPLICATION_ERROR(-20208, 'Este medicamento ya fue entregado completo');
        END IF;

        BEGIN
            SELECT CANTIDAD_DISPONIBLE
              INTO vn_disp
              FROM TBL_STOCK_FARMACIA
             WHERE ID_MEDICAMENTO = vn_med
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20207, 'No hay stock registrado de este medicamento');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20209, 'El stock se esta actualizando, intenta de nuevo');
        END;

        IF vn_disp <= 0 THEN
            RAISE_APPLICATION_ERROR(-20207, 'No hay stock disponible de este medicamento');
        END IF;

        IF pn_cantidad IS NULL THEN
            pn_entregadas := LEAST(vn_pend, vn_disp);
        ELSE
            IF pn_cantidad < 1 OR pn_cantidad <> TRUNC(pn_cantidad) OR pn_cantidad > vn_pend THEN
                RAISE_APPLICATION_ERROR(-20210, 'La cantidad a entregar debe ser un entero entre 1 y ' || vn_pend);
            END IF;
            IF pn_cantidad > vn_disp THEN
                RAISE_APPLICATION_ERROR(-20207, 'Stock insuficiente: solo hay ' || vn_disp || ' disponibles');
            END IF;
            pn_entregadas := pn_cantidad;
        END IF;
        pn_pendientes := vn_pend - pn_entregadas;

        UPDATE TBL_STOCK_FARMACIA
           SET CANTIDAD_DISPONIBLE = CANTIDAD_DISPONIBLE - pn_entregadas
         WHERE ID_MEDICAMENTO = vn_med;

        UPDATE TBL_DETALLE_RECETA
           SET CANTIDAD_PENDIENTE = pn_pendientes,
               ID_FARMACEUTICO    = NVL(pn_id_farmaceutico, ID_FARMACEUTICO),
               ID_ESTADO          = CASE WHEN pn_pendientes = 0 THEN vn_entregado ELSE ID_ESTADO END
         WHERE ID_DETALLE = pn_id_detalle;

        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'ENTREGAR_MEDICAMENTO', 'TBL_DETALLE_RECETA', pn_id_detalle,
                'pendiente=' || vn_pend || '; stock=' || vn_disp,
                'pendiente=' || pn_pendientes || '; stock=' || (vn_disp - pn_entregadas));

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_ENTREGAR_MEDICAMENTO;

END PKG_GESTION_MEDICAMENTOS;
/
SHOW ERRORS

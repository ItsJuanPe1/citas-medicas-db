-- =====================================================================
-- PKG_GESTION_MEDICAMENTOS  (HU05 prescribir y entregar; luego HU06 stock minimo)
-- Inserta en RECETAS_MEDICAS y DETALLE_RECETA, y descuenta STOCK_FARMACIA.
-- No modifica la estructura de ninguna tabla. Errores: 20201-20299.
--   - PRESCRIBIR_RECETA: el medico crea la receta de una historia clinica (no toca el stock).
--   - ENTREGAR_MEDICAMENTO: el farmaceutico entrega y se descuenta el stock con FOR UPDATE.
--     Si el stock no alcanza se entrega parcial y queda CANTIDAD_PENDIENTE.
-- El estado de la receta lo calcula TRG_DETALLE_ESTADO_RECETA.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_GESTION_MEDICAMENTOS AS

    EXC_HISTORIA_NO_EXISTE   EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_HISTORIA_NO_EXISTE,   -20201);
    EXC_HISTORIA_OTRO_MEDICO EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_HISTORIA_OTRO_MEDICO, -20202);
    EXC_RECETA_YA_EXISTE     EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_RECETA_YA_EXISTE,     -20203);
    EXC_RECETA_INVALIDA      EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_RECETA_INVALIDA,      -20204);
    EXC_MEDICAMENTO_NO_EXISTE EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_MEDICAMENTO_NO_EXISTE, -20205);
    EXC_DETALLE_NO_EXISTE    EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_DETALLE_NO_EXISTE,    -20206);
    EXC_SIN_STOCK            EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_SIN_STOCK,            -20207);
    EXC_YA_ENTREGADO         EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_YA_ENTREGADO,         -20208);
    EXC_BLOQUEADO            EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_BLOQUEADO,            -20209);
    EXC_CANTIDAD_INVALIDA    EXCEPTION; PRAGMA EXCEPTION_INIT(EXC_CANTIDAD_INVALIDA,    -20210);

    -- p_items: medicamentos separados por '|', y cada uno como id~cantidad~dosis
    --          ej.: '3~2~1 cada 8 horas|7~1~una al dia'   (maximo 20, sin repetir medicamento)
    -- Si p_id_medico no es NULL, la historia debe ser de una cita de ese medico.
    PROCEDURE PRESCRIBIR_RECETA(
        p_id_historia IN  NUMBER,
        p_items       IN  VARCHAR2,
        p_id_usuario  IN  NUMBER,
        p_id_receta   OUT NUMBER,
        p_id_medico   IN  NUMBER DEFAULT NULL
    );

    -- Entrega lo que alcance del pendiente (todo, o lo que haya en stock) y lo descuenta.
    PROCEDURE ENTREGAR_MEDICAMENTO(
        p_id_detalle      IN  NUMBER,
        p_id_usuario      IN  NUMBER,
        p_id_farmaceutico IN  NUMBER,        -- NULL si lo hace el superadmin
        p_entregadas      OUT NUMBER,
        p_pendientes      OUT NUMBER
    );

END PKG_GESTION_MEDICAMENTOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_GESTION_MEDICAMENTOS AS

    FUNCTION id_param(p_nombre VARCHAR2, p_valor VARCHAR2) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        SELECT ID_PARAMETRO INTO v_id
          FROM PARAMETRICA_TIPOS
         WHERE NOMBRE = p_nombre AND VALOR = p_valor;
        RETURN v_id;
    END id_param;

    ------------------------------------------------------------ PRESCRIBIR
    PROCEDURE PRESCRIBIR_RECETA(
        p_id_historia IN  NUMBER,
        p_items       IN  VARCHAR2,
        p_id_usuario  IN  NUMBER,
        p_id_receta   OUT NUMBER,
        p_id_medico   IN  NUMBER DEFAULT NULL
    ) IS
        v_no_entregada NUMBER := id_param('ESTADO_RECETA', 'NO ENTREGADA');
        v_det_no       NUMBER := id_param('ESTADO_DETALLE_RECETA', 'NO ENTREGADO');
        v_medico       NUMBER;
        v_existe       NUMBER;
        v_n            NUMBER;
        v_item         VARCHAR2(400);
        v_id_med       NUMBER;
        v_cant         NUMBER;
        v_dosis        VARCHAR2(100);
        v_vistos       VARCHAR2(4000) := ':';
        e_bloqueado    EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        -- Bloquea la historia: dos recetas simultaneas para la misma historia no pueden pasar
        BEGIN
            SELECT a.ID_MEDICO
              INTO v_medico
              FROM HISTORIA_CLINICA h
              JOIN CITAS_MEDICAS c   ON c.ID_CITA   = h.ID_CITA
              JOIN AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
             WHERE h.ID_HISTORIA = p_id_historia
               FOR UPDATE OF h.ID_HISTORIA WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20201, 'La historia clinica no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20209, 'Se esta modificando esta historia, intenta de nuevo');
        END;

        IF p_id_medico IS NOT NULL AND p_id_medico <> v_medico THEN
            RAISE_APPLICATION_ERROR(-20202, 'La historia pertenece a otro medico');
        END IF;

        SELECT COUNT(*) INTO v_existe FROM RECETAS_MEDICAS WHERE ID_HISTORIA = p_id_historia;
        IF v_existe > 0 THEN
            RAISE_APPLICATION_ERROR(-20203, 'Esta consulta ya tiene una receta');
        END IF;

        v_n := CASE WHEN p_items IS NULL THEN 0 ELSE REGEXP_COUNT(p_items, '[^|]+') END;
        IF v_n < 1 THEN
            RAISE_APPLICATION_ERROR(-20204, 'La receta debe tener al menos un medicamento');
        END IF;
        IF v_n > 20 THEN
            RAISE_APPLICATION_ERROR(-20204, 'Una receta puede tener maximo 20 medicamentos');
        END IF;

        INSERT INTO RECETAS_MEDICAS (ID_RECETA, ID_HISTORIA, ID_ESTADO)
        VALUES (SEQ_RECETAS_MEDICAS.NEXTVAL, p_id_historia, v_no_entregada)
        RETURNING ID_RECETA INTO p_id_receta;

        FOR i IN 1 .. v_n LOOP
            v_item := REGEXP_SUBSTR(p_items, '[^|]+', 1, i);
            BEGIN
                v_id_med := TO_NUMBER(REGEXP_SUBSTR(v_item, '[^~]+', 1, 1));
                v_cant   := TO_NUMBER(REGEXP_SUBSTR(v_item, '[^~]+', 1, 2));
            EXCEPTION
                WHEN VALUE_ERROR OR INVALID_NUMBER THEN
                    RAISE_APPLICATION_ERROR(-20204, 'Formato de medicamentos invalido');
            END;
            v_dosis := SUBSTR(TRIM(REGEXP_SUBSTR(v_item, '[^~]+', 1, 3)), 1, 100);

            IF v_id_med IS NULL OR v_cant IS NULL THEN
                RAISE_APPLICATION_ERROR(-20204, 'Formato de medicamentos invalido');
            END IF;
            IF v_cant < 1 OR v_cant > 99999 OR v_cant <> TRUNC(v_cant) THEN
                RAISE_APPLICATION_ERROR(-20210, 'La cantidad debe ser un entero entre 1 y 99999');
            END IF;
            IF INSTR(v_vistos, ':' || v_id_med || ':') > 0 THEN
                RAISE_APPLICATION_ERROR(-20204, 'Un medicamento no puede repetirse en la misma receta');
            END IF;
            v_vistos := v_vistos || v_id_med || ':';

            SELECT COUNT(*) INTO v_existe FROM MEDICAMENTOS WHERE ID_MEDICAMENTO = v_id_med;
            IF v_existe = 0 THEN
                RAISE_APPLICATION_ERROR(-20205, 'El medicamento ' || v_id_med || ' no existe');
            END IF;

            INSERT INTO DETALLE_RECETA (ID_DETALLE, ID_RECETA, ID_MEDICAMENTO, ID_ESTADO,
                                        CANTIDAD, CANTIDAD_PENDIENTE, DOSIS)
            VALUES (SEQ_DETALLE_RECETA.NEXTVAL, p_id_receta, v_id_med, v_det_no,
                    v_cant, v_cant, v_dosis);
        END LOOP;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'PRESCRIBIR_RECETA', 'RECETAS_MEDICAS', p_id_receta,
                NULL, 'id_historia=' || p_id_historia || '; medicamentos=' || v_n);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRESCRIBIR_RECETA;

    ------------------------------------------------------------ ENTREGAR
    PROCEDURE ENTREGAR_MEDICAMENTO(
        p_id_detalle      IN  NUMBER,
        p_id_usuario      IN  NUMBER,
        p_id_farmaceutico IN  NUMBER,
        p_entregadas      OUT NUMBER,
        p_pendientes      OUT NUMBER
    ) IS
        v_entregado NUMBER := id_param('ESTADO_DETALLE_RECETA', 'ENTREGADO');
        v_med       NUMBER;
        v_pend      NUMBER;
        v_disp      NUMBER;
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        -- Siempre en este orden: primero el detalle, luego el stock (evita bloqueos cruzados)
        BEGIN
            SELECT ID_MEDICAMENTO, CANTIDAD_PENDIENTE
              INTO v_med, v_pend
              FROM DETALLE_RECETA
             WHERE ID_DETALLE = p_id_detalle
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20206, 'El medicamento de la receta no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20209, 'Este medicamento se esta entregando en otro puesto, intenta de nuevo');
        END;

        IF v_pend = 0 THEN
            RAISE_APPLICATION_ERROR(-20208, 'Este medicamento ya fue entregado completo');
        END IF;

        BEGIN
            SELECT CANTIDAD_DISPONIBLE
              INTO v_disp
              FROM STOCK_FARMACIA
             WHERE ID_MEDICAMENTO = v_med
               FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20207, 'No hay stock registrado de este medicamento');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20209, 'El stock se esta actualizando, intenta de nuevo');
        END;

        IF v_disp <= 0 THEN
            RAISE_APPLICATION_ERROR(-20207, 'No hay stock disponible de este medicamento');
        END IF;

        p_entregadas := LEAST(v_pend, v_disp);
        p_pendientes := v_pend - p_entregadas;

        UPDATE STOCK_FARMACIA
           SET CANTIDAD_DISPONIBLE = CANTIDAD_DISPONIBLE - p_entregadas
         WHERE ID_MEDICAMENTO = v_med;

        UPDATE DETALLE_RECETA
           SET CANTIDAD_PENDIENTE = p_pendientes,
               ID_FARMACEUTICO    = NVL(p_id_farmaceutico, ID_FARMACEUTICO),
               ID_ESTADO          = CASE WHEN p_pendientes = 0 THEN v_entregado ELSE ID_ESTADO END
         WHERE ID_DETALLE = p_id_detalle;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'ENTREGAR_MEDICAMENTO', 'DETALLE_RECETA', p_id_detalle,
                'pendiente=' || v_pend || '; stock=' || v_disp,
                'pendiente=' || p_pendientes || '; stock=' || (v_disp - p_entregadas));

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END ENTREGAR_MEDICAMENTO;

END PKG_GESTION_MEDICAMENTOS;
/
SHOW ERRORS

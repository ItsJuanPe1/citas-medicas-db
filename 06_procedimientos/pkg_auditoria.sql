-- =====================================================================
-- PKG_AUDITORIA: unico lugar que escribe en TBL_LOG_AUDITORIAS.
-- Los triggers (y los demas paquetes) arman los datos y llaman PRO_REGISTRAR; asi el INSERT,
-- el recorte a 4000 caracteres y la regla del usuario (contexto CTX_CITAS, 0 = sistema)
-- viven en un solo sitio. PRO_REGISTRAR no hace COMMIT: se puede llamar desde un trigger y
-- la fila queda en la misma transaccion que el cambio auditado.
-- Compilar ANTES de los triggers.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_AUDITORIA AS

    -- Usuario de la aplicacion que hizo el cambio (lo pone el back en el contexto CTX_CITAS).
    -- Sin contexto (scripts, SQL directo) devuelve 0 = sistema.
    FUNCTION FN_USUARIO_ACTUAL RETURN NUMBER;

    -- Inserta una fila en la bitacora. Si pn_id_usuario es NULL se usa FN_USUARIO_ACTUAL.
    PROCEDURE PRO_REGISTRAR(
        ps_accion      IN VARCHAR2,
        ps_tabla       IN VARCHAR2,
        pn_id_registro IN NUMBER,
        ps_antes       IN VARCHAR2,
        ps_despues     IN VARCHAR2,
        pn_id_usuario  IN NUMBER DEFAULT NULL
    );

END PKG_AUDITORIA;
/

CREATE OR REPLACE PACKAGE BODY PKG_AUDITORIA AS

    FUNCTION FN_USUARIO_ACTUAL RETURN NUMBER IS
    BEGIN
        RETURN NVL(TO_NUMBER(SYS_CONTEXT('CTX_CITAS', 'ID_USUARIO')), 0);
    END FN_USUARIO_ACTUAL;

    PROCEDURE PRO_REGISTRAR(
        ps_accion      IN VARCHAR2,
        ps_tabla       IN VARCHAR2,
        pn_id_registro IN NUMBER,
        ps_antes       IN VARCHAR2,
        ps_despues     IN VARCHAR2,
        pn_id_usuario  IN NUMBER DEFAULT NULL
    ) IS
    BEGIN
        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, NVL(pn_id_usuario, FN_USUARIO_ACTUAL), ps_accion, ps_tabla,
                pn_id_registro, SUBSTR(ps_antes, 1, 4000), SUBSTR(ps_despues, 1, 4000));
    END PRO_REGISTRAR;

END PKG_AUDITORIA;
/
SHOW ERRORS

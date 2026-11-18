-- =====================================================================
-- HU08: auditoria de datos sensibles de TBL_HISTORIA_CLINICA.
-- AFTER INSERT OR UPDATE (diagnostico o notas) OR DELETE: guarda en TBL_LOG_AUDITORIAS la accion,
-- el usuario (de la aplicacion y el usuario Oracle), la fecha/hora y los valores
-- anteriores (:OLD) y nuevos (:NEW). El usuario de la aplicacion lo pone el back en el
-- contexto CTX_CITAS (PKG_SEGURIDAD); sin contexto (scripts/SQL directo) queda 0 = sistema.
-- No modifica la estructura de ninguna tabla.
-- =====================================================================
CREATE OR REPLACE TRIGGER TRG_HISTORIA_AUDITORIA
AFTER INSERT OR UPDATE OF DIAGNOSTICO, NOTAS_MEDICAS OR DELETE ON TBL_HISTORIA_CLINICA
FOR EACH ROW
DECLARE
    vn_usuario NUMBER := NVL(TO_NUMBER(SYS_CONTEXT('CTX_CITAS', 'ID_USUARIO')), 0);
    vs_oracle  VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
    vs_accion  VARCHAR2(50);
    vs_antes   VARCHAR2(4000);
    vs_despues VARCHAR2(4000);
BEGIN
    IF INSERTING THEN
        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, vn_usuario, 'CREAR_HISTORIA', 'TBL_HISTORIA_CLINICA', :NEW.ID_HISTORIA, NULL,
                SUBSTR('[Oracle: ' || vs_oracle || '] Diagnostico: ' || :NEW.DIAGNOSTICO || ' | Notas: ' || :NEW.NOTAS_MEDICAS, 1, 4000));
        RETURN;
    ELSIF UPDATING THEN
        -- si no cambio ni el diagnostico ni las notas, no hay nada que auditar
        IF NVL(:OLD.DIAGNOSTICO, '~') = NVL(:NEW.DIAGNOSTICO, '~')
           AND NVL(:OLD.NOTAS_MEDICAS, '~') = NVL(:NEW.NOTAS_MEDICAS, '~') THEN
            RETURN;
        END IF;
        vs_accion  := 'MODIFICAR_HISTORIA';
        vs_antes   := SUBSTR('Diagnostico: ' || :OLD.DIAGNOSTICO || ' | Notas: ' || :OLD.NOTAS_MEDICAS, 1, 4000);
        vs_despues := SUBSTR('[Oracle: ' || vs_oracle || '] Diagnostico: ' || :NEW.DIAGNOSTICO
                             || ' | Notas: ' || :NEW.NOTAS_MEDICAS, 1, 4000);
    ELSE
        vs_accion  := 'ELIMINAR_HISTORIA';
        vs_antes   := SUBSTR('Diagnostico: ' || :OLD.DIAGNOSTICO || ' | Notas: ' || :OLD.NOTAS_MEDICAS, 1, 4000);
        vs_despues := '[Oracle: ' || vs_oracle || '] Registro eliminado';
    END IF;

    INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
    VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, vn_usuario, vs_accion, 'TBL_HISTORIA_CLINICA', :OLD.ID_HISTORIA,
            vs_antes, vs_despues);
END TRG_HISTORIA_AUDITORIA;
/
SHOW ERRORS

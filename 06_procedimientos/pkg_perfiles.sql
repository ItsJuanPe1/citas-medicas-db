-- =====================================================================
-- PKG_PERFILES: cada usuario edita su telefono y correo (UPDATE en MEDICOS, PACIENTES o FARMACEUTICOS).
-- No modifica la estructura de ninguna tabla.
-- Nombre, documento, etc. NO se editan aqui. Errores: 20401-20499.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_PERFILES AS

    PROCEDURE ACTUALIZAR_CONTACTO(
        p_rol        IN VARCHAR2,   -- MEDICO | PACIENTE | FARMACEUTICO
        p_id_entidad IN NUMBER,
        p_telefono   IN VARCHAR2,
        p_email      IN VARCHAR2,
        p_id_usuario IN NUMBER
    );

END PKG_PERFILES;
/

CREATE OR REPLACE PACKAGE BODY PKG_PERFILES AS

    PROCEDURE ACTUALIZAR_CONTACTO(
        p_rol        IN VARCHAR2,
        p_id_entidad IN NUMBER,
        p_telefono   IN VARCHAR2,
        p_email      IN VARCHAR2,
        p_id_usuario IN NUMBER
    ) IS
        v_tel      VARCHAR2(20)  := TRIM(p_telefono);
        v_mail     VARCHAR2(150) := LOWER(TRIM(p_email));
        v_tabla    VARCHAR2(30);
        v_tel_ant  VARCHAR2(20);
        v_mail_ant VARCHAR2(150);
    BEGIN
        IF p_rol NOT IN ('MEDICO', 'PACIENTE', 'FARMACEUTICO') OR p_id_entidad IS NULL THEN
            RAISE_APPLICATION_ERROR(-20401, 'Este usuario no tiene un perfil editable');
        END IF;
        IF v_mail IS NOT NULL AND (LENGTH(v_mail) > 150 OR NOT REGEXP_LIKE(v_mail, '^[^@ ]+@[^@ ]+\.[^@ ]+$')) THEN
            RAISE_APPLICATION_ERROR(-20402, 'El correo no tiene un formato valido');
        END IF;
        IF v_tel IS NOT NULL AND NOT REGEXP_LIKE(v_tel, '^[0-9+ ()-]{7,20}$') THEN
            RAISE_APPLICATION_ERROR(-20403, 'El telefono debe tener entre 7 y 20 digitos');
        END IF;

        -- Valores anteriores (y bloqueo de la fila)
        BEGIN
            IF p_rol = 'MEDICO' THEN
                v_tabla := 'MEDICOS';
                SELECT TELEFONO, EMAIL INTO v_tel_ant, v_mail_ant FROM MEDICOS WHERE ID_MEDICO = p_id_entidad FOR UPDATE;
                UPDATE MEDICOS SET TELEFONO = v_tel, EMAIL = v_mail WHERE ID_MEDICO = p_id_entidad;
            ELSIF p_rol = 'PACIENTE' THEN
                v_tabla := 'PACIENTES';
                SELECT TELEFONO, EMAIL INTO v_tel_ant, v_mail_ant FROM PACIENTES WHERE ID_PACIENTE = p_id_entidad FOR UPDATE;
                UPDATE PACIENTES SET TELEFONO = v_tel, EMAIL = v_mail WHERE ID_PACIENTE = p_id_entidad;
            ELSE
                v_tabla := 'FARMACEUTICOS';
                SELECT TELEFONO, EMAIL INTO v_tel_ant, v_mail_ant FROM FARMACEUTICOS WHERE ID_FARMACEUTICO = p_id_entidad FOR UPDATE;
                UPDATE FARMACEUTICOS SET TELEFONO = v_tel, EMAIL = v_mail WHERE ID_FARMACEUTICO = p_id_entidad;
            END IF;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20404, 'No se encontro el perfil');
            WHEN DUP_VAL_ON_INDEX THEN
                RAISE_APPLICATION_ERROR(-20405, 'Ese correo ya esta en uso por otra persona');
        END;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'ACTUALIZAR_CONTACTO', v_tabla, p_id_entidad,
                'telefono=' || v_tel_ant || '; email=' || v_mail_ant,
                'telefono=' || v_tel || '; email=' || v_mail);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END ACTUALIZAR_CONTACTO;

END PKG_PERFILES;
/
SHOW ERRORS

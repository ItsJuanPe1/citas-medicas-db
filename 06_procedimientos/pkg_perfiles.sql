-- =====================================================================
-- PKG_PERFILES: cada usuario edita su telefono y correo (UPDATE en TBL_MEDICOS, TBL_PACIENTES o TBL_FARMACEUTICOS).
-- No modifica la estructura de ninguna tabla.
-- Nombre, documento, etc. NO se editan aqui. Errores: 20401-20499.
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_PERFILES AS

    PROCEDURE PRO_ACTUALIZAR_CONTACTO(
        ps_rol        IN VARCHAR2,   -- MEDICO | PACIENTE | FARMACEUTICO
        pn_id_entidad IN NUMBER,
        ps_telefono   IN VARCHAR2,
        ps_email      IN VARCHAR2,
        pn_id_usuario IN NUMBER
    );

END PKG_PERFILES;
/

CREATE OR REPLACE PACKAGE BODY PKG_PERFILES AS

    PROCEDURE PRO_ACTUALIZAR_CONTACTO(
        ps_rol        IN VARCHAR2,
        pn_id_entidad IN NUMBER,
        ps_telefono   IN VARCHAR2,
        ps_email      IN VARCHAR2,
        pn_id_usuario IN NUMBER
    ) IS
        vs_tel      VARCHAR2(20)  := TRIM(ps_telefono);
        vs_mail     VARCHAR2(150) := LOWER(TRIM(ps_email));
        vs_tabla    VARCHAR2(30);
        vs_tel_ant  VARCHAR2(20);
        vs_mail_ant VARCHAR2(150);
    BEGIN
        IF ps_rol NOT IN ('MEDICO', 'PACIENTE', 'FARMACEUTICO') OR pn_id_entidad IS NULL THEN
            RAISE_APPLICATION_ERROR(-20401, 'Este usuario no tiene un perfil editable');
        END IF;
        IF vs_mail IS NOT NULL AND (LENGTH(vs_mail) > 150 OR NOT REGEXP_LIKE(vs_mail, '^[^@ ]+@[^@ ]+\.[^@ ]+$')) THEN
            RAISE_APPLICATION_ERROR(-20402, 'El correo no tiene un formato valido');
        END IF;
        IF vs_tel IS NOT NULL AND NOT REGEXP_LIKE(vs_tel, '^[0-9+ ()-]{7,20}$') THEN
            RAISE_APPLICATION_ERROR(-20403, 'El telefono debe tener entre 7 y 20 digitos');
        END IF;

        -- Valores anteriores (y bloqueo de la fila)
        BEGIN
            IF ps_rol = 'MEDICO' THEN
                vs_tabla := 'TBL_MEDICOS';
                SELECT TELEFONO, EMAIL INTO vs_tel_ant, vs_mail_ant FROM TBL_MEDICOS WHERE ID_MEDICO = pn_id_entidad FOR UPDATE;
                UPDATE TBL_MEDICOS SET TELEFONO = vs_tel, EMAIL = vs_mail WHERE ID_MEDICO = pn_id_entidad;
            ELSIF ps_rol = 'PACIENTE' THEN
                vs_tabla := 'TBL_PACIENTES';
                SELECT TELEFONO, EMAIL INTO vs_tel_ant, vs_mail_ant FROM TBL_PACIENTES WHERE ID_PACIENTE = pn_id_entidad FOR UPDATE;
                UPDATE TBL_PACIENTES SET TELEFONO = vs_tel, EMAIL = vs_mail WHERE ID_PACIENTE = pn_id_entidad;
            ELSE
                vs_tabla := 'TBL_FARMACEUTICOS';
                SELECT TELEFONO, EMAIL INTO vs_tel_ant, vs_mail_ant FROM TBL_FARMACEUTICOS WHERE ID_FARMACEUTICO = pn_id_entidad FOR UPDATE;
                UPDATE TBL_FARMACEUTICOS SET TELEFONO = vs_tel, EMAIL = vs_mail WHERE ID_FARMACEUTICO = pn_id_entidad;
            END IF;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20404, 'No se encontro el perfil');
            WHEN DUP_VAL_ON_INDEX THEN
                RAISE_APPLICATION_ERROR(-20405, 'Ese correo ya esta en uso por otra persona');
        END;

        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'ACTUALIZAR_CONTACTO', vs_tabla, pn_id_entidad,
                'telefono=' || vs_tel_ant || '; email=' || vs_mail_ant,
                'telefono=' || vs_tel || '; email=' || vs_mail);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_ACTUALIZAR_CONTACTO;

END PKG_PERFILES;
/
SHOW ERRORS

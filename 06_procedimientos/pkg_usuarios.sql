-- =====================================================================
-- PKG_USUARIOS: registro de pacientes y gestion de cuentas (alta de personal, estado, clave).
-- Inserta en TBL_USUARIOS y en TBL_PACIENTES / TBL_MEDICOS / TBL_FARMACEUTICOS. No modifica la estructura de ninguna tabla.
-- La clave se guarda como SHA-256 en hex mayuscula (igual que los usuarios existentes).
-- Errores: 20501-20599. (20511: clave actual incorrecta; 20512: la nueva clave es igual a la actual)
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_USUARIOS AS

    -- Registro publico: crea el paciente y su usuario (rol PACIENTE) en una sola transaccion.
    PROCEDURE PRO_REGISTRAR_PACIENTE(
        ps_documento  IN  VARCHAR2,
        ps_nombre     IN  VARCHAR2,
        ps_apellido   IN  VARCHAR2,
        pd_fecha_nac  IN  DATE,
        ps_telefono   IN  VARCHAR2,
        ps_email      IN  VARCHAR2,
        ps_username   IN  VARCHAR2,
        ps_password   IN  VARCHAR2,
        pn_id_usuario OUT NUMBER
    );

    -- Alta de personal por el administrador. ps_rol: MEDICO | FARMACEUTICO | RECEPCIONISTA | GERENTE.
    -- MEDICO y FARMACEUTICO crean tambien su ficha (documento, nombre y apellido obligatorios;
    -- el medico ademas necesita pn_id_especialidad). RECEPCIONISTA y GERENTE solo tienen usuario.
    PROCEDURE PRO_CREAR_PERSONAL(
        ps_rol             IN  VARCHAR2,
        ps_documento       IN  VARCHAR2,
        ps_nombre          IN  VARCHAR2,
        ps_apellido        IN  VARCHAR2,
        pn_id_especialidad IN  NUMBER,
        ps_telefono        IN  VARCHAR2,
        ps_email           IN  VARCHAR2,
        ps_username        IN  VARCHAR2,
        ps_password        IN  VARCHAR2,
        pn_id_admin        IN  NUMBER,
        pn_id_usuario      OUT NUMBER
    );

    -- ACTIVO / INACTIVO. Un administrador no puede desactivar su propia cuenta.
    PROCEDURE PRO_CAMBIAR_ESTADO(
        pn_id_usuario IN NUMBER,
        ps_estado     IN VARCHAR2,
        pn_id_admin   IN NUMBER
    );

    -- Restablece la clave a una TEMPORAL: la persona debera cambiarla en su proximo ingreso.
    PROCEDURE PRO_RESTABLECER_CLAVE(
        pn_id_usuario IN NUMBER,
        ps_nueva      IN VARCHAR2,
        pn_id_admin   IN NUMBER
    );

    -- La propia persona cambia su clave (exige la actual) y deja de ser temporal.
    PROCEDURE PRO_CAMBIAR_CLAVE(
        pn_id_usuario IN NUMBER,
        ps_actual     IN VARCHAR2,
        ps_nueva      IN VARCHAR2
    );

    -- La recepcionista registra un paciente que llega sin cuenta (solo la ficha, sin usuario).
    -- Despues puede reservarle citas; si luego quiere cuenta propia, se registra aparte.
    PROCEDURE PRO_REGISTRAR_PACIENTE_RECEPCION(
        ps_documento   IN  VARCHAR2,
        ps_nombre      IN  VARCHAR2,
        ps_apellido    IN  VARCHAR2,
        pd_fecha_nac   IN  DATE,
        ps_telefono    IN  VARCHAR2,
        ps_email       IN  VARCHAR2,
        pn_id_usuario  IN  NUMBER,
        pn_id_paciente OUT NUMBER
    );

END PKG_USUARIOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_USUARIOS AS

    -- STANDARD_HASH solo se puede usar dentro de una sentencia SQL, no como expresion PL/SQL
    FUNCTION FN_HASH_CLAVE(ps_clave VARCHAR2) RETURN VARCHAR2 IS
        vs_h VARCHAR2(64);
    BEGIN
        SELECT RAWTOHEX(STANDARD_HASH(ps_clave, 'SHA256')) INTO vs_h FROM DUAL;
        RETURN vs_h;
    END FN_HASH_CLAVE;

    PROCEDURE PRO_VALIDAR_CLAVE(ps_clave VARCHAR2) IS
    BEGIN
        IF ps_clave IS NULL OR LENGTH(ps_clave) < 8 OR LENGTH(ps_clave) > 64
           OR NOT REGEXP_LIKE(ps_clave, '[A-Za-z]') OR NOT REGEXP_LIKE(ps_clave, '[0-9]') THEN
            RAISE_APPLICATION_ERROR(-20505, 'La contrasena debe tener entre 8 y 64 caracteres, con letras y numeros');
        END IF;
    END PRO_VALIDAR_CLAVE;

    PROCEDURE PRO_VALIDAR_USUARIO(ps_username VARCHAR2) IS
    BEGIN
        IF ps_username IS NULL OR NOT REGEXP_LIKE(ps_username, '^[a-z0-9._-]{4,30}$') THEN
            RAISE_APPLICATION_ERROR(-20504, 'El usuario debe tener 4 a 30 caracteres: letras minusculas, numeros, punto, guion o guion bajo');
        END IF;
    END PRO_VALIDAR_USUARIO;

    PROCEDURE PRO_VALIDAR_PERSONA(ps_documento VARCHAR2, ps_nombre VARCHAR2, ps_apellido VARCHAR2,
                              ps_telefono VARCHAR2, ps_email VARCHAR2) IS
    BEGIN
        IF ps_documento IS NULL OR NOT REGEXP_LIKE(ps_documento, '^[0-9]{5,20}$') THEN
            RAISE_APPLICATION_ERROR(-20504, 'El documento debe tener entre 5 y 20 digitos');
        END IF;
        IF ps_nombre IS NULL OR ps_apellido IS NULL OR LENGTH(ps_nombre) > 100 OR LENGTH(ps_apellido) > 100 THEN
            RAISE_APPLICATION_ERROR(-20504, 'Nombre y apellido son obligatorios (maximo 100 caracteres)');
        END IF;
        IF ps_telefono IS NOT NULL AND NOT REGEXP_LIKE(ps_telefono, '^[0-9+ ()-]{7,20}$') THEN
            RAISE_APPLICATION_ERROR(-20504, 'El telefono no tiene un formato valido');
        END IF;
        IF ps_email IS NOT NULL AND (LENGTH(ps_email) > 150 OR NOT REGEXP_LIKE(ps_email, '^[^@ ]+@[^@ ]+\.[^@ ]+$')) THEN
            RAISE_APPLICATION_ERROR(-20504, 'El correo no tiene un formato valido');
        END IF;
    END PRO_VALIDAR_PERSONA;

    -- Traduce los choques con las restricciones UNIQUE a mensajes claros
    PROCEDURE PRO_TRADUCIR_DUPLICADO(ps_msg VARCHAR2) IS
    BEGIN
        IF INSTR(ps_msg, 'UQ_TBL_USUARIOS_USERNAME') > 0 THEN
            RAISE_APPLICATION_ERROR(-20501, 'Ese nombre de usuario ya esta en uso');
        ELSIF INSTR(ps_msg, '_DOCUMENTO') > 0 THEN
            RAISE_APPLICATION_ERROR(-20502, 'Ese documento ya esta registrado');
        ELSIF INSTR(ps_msg, '_EMAIL') > 0 THEN
            RAISE_APPLICATION_ERROR(-20503, 'Ese correo ya esta registrado');
        END IF;
    END PRO_TRADUCIR_DUPLICADO;

    FUNCTION FN_ID_ROL(ps_nombre VARCHAR2) RETURN NUMBER IS
        v NUMBER;
    BEGIN
        SELECT ID_ROL INTO v FROM TBL_ROLES WHERE NOMBRE = ps_nombre;
        RETURN v;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20506, 'Rol no valido');
    END FN_ID_ROL;

    PROCEDURE PRO_AUDITAR(pn_quien NUMBER, ps_accion VARCHAR2, pn_id NUMBER, ps_antes VARCHAR2, ps_despues VARCHAR2) IS
    BEGIN
        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_quien, ps_accion, 'TBL_USUARIOS', pn_id, ps_antes, ps_despues);
    END PRO_AUDITAR;

    ------------------------------------------------------------ REGISTRAR_PACIENTE
    PROCEDURE PRO_REGISTRAR_PACIENTE(
        ps_documento  IN  VARCHAR2,
        ps_nombre     IN  VARCHAR2,
        ps_apellido   IN  VARCHAR2,
        pd_fecha_nac  IN  DATE,
        ps_telefono   IN  VARCHAR2,
        ps_email      IN  VARCHAR2,
        ps_username   IN  VARCHAR2,
        ps_password   IN  VARCHAR2,
        pn_id_usuario OUT NUMBER
    ) IS
        vs_doc   VARCHAR2(20)  := TRIM(ps_documento);
        vs_nom   VARCHAR2(100) := TRIM(ps_nombre);
        vs_ape   VARCHAR2(100) := TRIM(ps_apellido);
        vs_tel   VARCHAR2(20)  := TRIM(ps_telefono);
        vs_mail  VARCHAR2(150) := LOWER(TRIM(ps_email));
        vs_user  VARCHAR2(50)  := LOWER(TRIM(ps_username));
        vn_pac   NUMBER;
        vn_rol   NUMBER;
        vs_hash  VARCHAR2(64);
    BEGIN
        PRO_VALIDAR_PERSONA(vs_doc, vs_nom, vs_ape, vs_tel, vs_mail);
        PRO_VALIDAR_USUARIO(vs_user);
        PRO_VALIDAR_CLAVE(ps_password);
        IF pd_fecha_nac IS NULL OR pd_fecha_nac > TRUNC(SYSDATE) OR pd_fecha_nac < DATE '1900-01-01' THEN
            RAISE_APPLICATION_ERROR(-20504, 'La fecha de nacimiento no es valida');
        END IF;
        vn_rol  := FN_ID_ROL('PACIENTE');
        vs_hash := FN_HASH_CLAVE(ps_password);  -- las funciones del paquete no pueden ir dentro del INSERT

        INSERT INTO TBL_PACIENTES (ID_PACIENTE, DOCUMENTO, NOMBRE, APELLIDO, FECHA_NACIMIENTO, TELEFONO, EMAIL)
        VALUES (SEQ_TBL_PACIENTES.NEXTVAL, vs_doc, vs_nom, vs_ape, pd_fecha_nac, vs_tel, vs_mail)
        RETURNING ID_PACIENTE INTO vn_pac;

        INSERT INTO TBL_USUARIOS (ID_USUARIO, ID_ROL, USERNAME, PASSWORD, ID_ENTIDAD, ESTADO)
        VALUES (SEQ_TBL_USUARIOS.NEXTVAL, vn_rol, vs_user, vs_hash, vn_pac, 'ACTIVO')
        RETURNING ID_USUARIO INTO pn_id_usuario;

        PRO_AUDITAR(pn_id_usuario, 'REGISTRAR_PACIENTE', pn_id_usuario, NULL, 'usuario=' || vs_user || '; paciente=' || vn_pac);
        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            ROLLBACK;
            PRO_TRADUCIR_DUPLICADO(SQLERRM);
            RAISE;
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_REGISTRAR_PACIENTE;

    ------------------------------------------------------------ CREAR_PERSONAL
    PROCEDURE PRO_CREAR_PERSONAL(
        ps_rol             IN  VARCHAR2,
        ps_documento       IN  VARCHAR2,
        ps_nombre          IN  VARCHAR2,
        ps_apellido        IN  VARCHAR2,
        pn_id_especialidad IN  NUMBER,
        ps_telefono        IN  VARCHAR2,
        ps_email           IN  VARCHAR2,
        ps_username        IN  VARCHAR2,
        ps_password        IN  VARCHAR2,
        pn_id_admin        IN  NUMBER,
        pn_id_usuario      OUT NUMBER
    ) IS
        vs_doc   VARCHAR2(20)  := TRIM(ps_documento);
        vs_nom   VARCHAR2(100) := TRIM(ps_nombre);
        vs_ape   VARCHAR2(100) := TRIM(ps_apellido);
        vs_tel   VARCHAR2(20)  := TRIM(ps_telefono);
        vs_mail  VARCHAR2(150) := LOWER(TRIM(ps_email));
        vs_user  VARCHAR2(50)  := LOWER(TRIM(ps_username));
        vn_ent   NUMBER;
        vn_n     NUMBER;
        vn_rolid NUMBER;
        vs_hash  VARCHAR2(64);
    BEGIN
        IF ps_rol IS NULL OR ps_rol NOT IN ('MEDICO', 'FARMACEUTICO', 'RECEPCIONISTA', 'GERENTE') THEN
            RAISE_APPLICATION_ERROR(-20506, 'Rol no valido para crear personal');
        END IF;
        PRO_VALIDAR_USUARIO(vs_user);
        PRO_VALIDAR_CLAVE(ps_password);

        IF ps_rol IN ('MEDICO', 'FARMACEUTICO') THEN
            PRO_VALIDAR_PERSONA(vs_doc, vs_nom, vs_ape, vs_tel, vs_mail);
        END IF;

        IF ps_rol = 'MEDICO' THEN
            SELECT COUNT(*) INTO vn_n FROM TBL_PARAMETRICA_TIPOS
             WHERE ID_PARAMETRO = pn_id_especialidad AND NOMBRE = 'ESPECIALIDAD';
            IF vn_n = 0 THEN
                RAISE_APPLICATION_ERROR(-20507, 'La especialidad no es valida');
            END IF;
            INSERT INTO TBL_MEDICOS (ID_MEDICO, DOCUMENTO, NOMBRE, APELLIDO, ID_ESPECIALIDAD, TELEFONO, EMAIL)
            VALUES (SEQ_TBL_MEDICOS.NEXTVAL, vs_doc, vs_nom, vs_ape, pn_id_especialidad, vs_tel, vs_mail)
            RETURNING ID_MEDICO INTO vn_ent;
        ELSIF ps_rol = 'FARMACEUTICO' THEN
            INSERT INTO TBL_FARMACEUTICOS (ID_FARMACEUTICO, DOCUMENTO, NOMBRE, APELLIDO, TELEFONO, EMAIL)
            VALUES (SEQ_TBL_FARMACEUTICOS.NEXTVAL, vs_doc, vs_nom, vs_ape, vs_tel, vs_mail)
            RETURNING ID_FARMACEUTICO INTO vn_ent;
        END IF;

        vn_rolid := FN_ID_ROL(ps_rol);
        vs_hash  := FN_HASH_CLAVE(ps_password);
        INSERT INTO TBL_USUARIOS (ID_USUARIO, ID_ROL, USERNAME, PASSWORD, ID_ENTIDAD, ESTADO, DEBE_CAMBIAR_CLAVE)
        VALUES (SEQ_TBL_USUARIOS.NEXTVAL, vn_rolid, vs_user, vs_hash, vn_ent, 'ACTIVO', 'S')
        RETURNING ID_USUARIO INTO pn_id_usuario;

        PRO_AUDITAR(pn_id_admin, 'CREAR_PERSONAL', pn_id_usuario, NULL,
                'usuario=' || vs_user || '; rol=' || ps_rol || '; entidad=' || NVL(TO_CHAR(vn_ent), '-'));
        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            ROLLBACK;
            PRO_TRADUCIR_DUPLICADO(SQLERRM);
            RAISE;
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_CREAR_PERSONAL;

    ------------------------------------------------------------ CAMBIAR_ESTADO
    PROCEDURE PRO_CAMBIAR_ESTADO(
        pn_id_usuario IN NUMBER,
        ps_estado     IN VARCHAR2,
        pn_id_admin   IN NUMBER
    ) IS
        vs_antes VARCHAR2(10);
        ex_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        IF ps_estado IS NULL OR ps_estado NOT IN ('ACTIVO', 'INACTIVO') THEN
            RAISE_APPLICATION_ERROR(-20509, 'El estado debe ser ACTIVO o INACTIVO');
        END IF;
        IF ps_estado = 'INACTIVO' AND pn_id_usuario = pn_id_admin THEN
            RAISE_APPLICATION_ERROR(-20509, 'No puedes desactivar tu propia cuenta');
        END IF;
        BEGIN
            SELECT ESTADO INTO vs_antes FROM TBL_USUARIOS WHERE ID_USUARIO = pn_id_usuario FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20508, 'El usuario no existe');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20510, 'Este usuario se esta modificando, intenta de nuevo');
        END;
        UPDATE TBL_USUARIOS SET ESTADO = ps_estado WHERE ID_USUARIO = pn_id_usuario;
        PRO_AUDITAR(pn_id_admin, 'CAMBIAR_ESTADO_USUARIO', pn_id_usuario, 'estado=' || vs_antes, 'estado=' || ps_estado);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_CAMBIAR_ESTADO;

    ------------------------------------------------------------ RESTABLECER_CLAVE
    PROCEDURE PRO_RESTABLECER_CLAVE(
        pn_id_usuario IN NUMBER,
        ps_nueva      IN VARCHAR2,
        pn_id_admin   IN NUMBER
    ) IS
        vs_hash VARCHAR2(64);
    BEGIN
        PRO_VALIDAR_CLAVE(ps_nueva);
        vs_hash := FN_HASH_CLAVE(ps_nueva);
        UPDATE TBL_USUARIOS SET PASSWORD = vs_hash, DEBE_CAMBIAR_CLAVE = 'S' WHERE ID_USUARIO = pn_id_usuario;
        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20508, 'El usuario no existe');
        END IF;
        PRO_AUDITAR(pn_id_admin, 'RESTABLECER_CLAVE', pn_id_usuario, NULL, 'clave temporal asignada');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_RESTABLECER_CLAVE;

    ------------------------------------------------------------ CAMBIAR_CLAVE
    PROCEDURE PRO_CAMBIAR_CLAVE(
        pn_id_usuario IN NUMBER,
        ps_actual     IN VARCHAR2,
        ps_nueva      IN VARCHAR2
    ) IS
        vs_hash  VARCHAR2(255);
        vs_nuevo VARCHAR2(64);
        ex_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(ex_bloqueado, -30006);
    BEGIN
        PRO_VALIDAR_CLAVE(ps_nueva);
        BEGIN
            SELECT PASSWORD INTO vs_hash FROM TBL_USUARIOS WHERE ID_USUARIO = pn_id_usuario FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20508, 'El usuario no existe');
            WHEN ex_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20510, 'Tu cuenta se esta modificando, intenta de nuevo');
        END;
        IF ps_actual IS NULL OR vs_hash <> FN_HASH_CLAVE(ps_actual) THEN
            RAISE_APPLICATION_ERROR(-20511, 'La contrasena actual no es correcta');
        END IF;
        vs_nuevo := FN_HASH_CLAVE(ps_nueva);
        IF vs_nuevo = vs_hash THEN
            RAISE_APPLICATION_ERROR(-20512, 'La nueva contrasena debe ser distinta de la actual');
        END IF;
        UPDATE TBL_USUARIOS SET PASSWORD = vs_nuevo, DEBE_CAMBIAR_CLAVE = 'N' WHERE ID_USUARIO = pn_id_usuario;
        PRO_AUDITAR(pn_id_usuario, 'CAMBIAR_CLAVE', pn_id_usuario, NULL, 'clave cambiada por el usuario');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_CAMBIAR_CLAVE;

    ------------------------------------------------------------ REGISTRAR_PACIENTE_RECEPCION
    PROCEDURE PRO_REGISTRAR_PACIENTE_RECEPCION(
        ps_documento   IN  VARCHAR2,
        ps_nombre      IN  VARCHAR2,
        ps_apellido    IN  VARCHAR2,
        pd_fecha_nac   IN  DATE,
        ps_telefono    IN  VARCHAR2,
        ps_email       IN  VARCHAR2,
        pn_id_usuario  IN  NUMBER,
        pn_id_paciente OUT NUMBER
    ) IS
        vs_doc   VARCHAR2(20)  := TRIM(ps_documento);
        vs_nom   VARCHAR2(100) := TRIM(ps_nombre);
        vs_ape   VARCHAR2(100) := TRIM(ps_apellido);
        vs_tel   VARCHAR2(20)  := TRIM(ps_telefono);
        vs_mail  VARCHAR2(150) := LOWER(TRIM(ps_email));
    BEGIN
        PRO_VALIDAR_PERSONA(vs_doc, vs_nom, vs_ape, vs_tel, vs_mail);
        IF pd_fecha_nac IS NOT NULL AND (pd_fecha_nac > TRUNC(SYSDATE) OR pd_fecha_nac < DATE '1900-01-01') THEN
            RAISE_APPLICATION_ERROR(-20504, 'La fecha de nacimiento no es valida');
        END IF;

        INSERT INTO TBL_PACIENTES (ID_PACIENTE, DOCUMENTO, NOMBRE, APELLIDO, FECHA_NACIMIENTO, TELEFONO, EMAIL)
        VALUES (SEQ_TBL_PACIENTES.NEXTVAL, vs_doc, vs_nom, vs_ape, pd_fecha_nac, vs_tel, vs_mail)
        RETURNING ID_PACIENTE INTO pn_id_paciente;

        INSERT INTO TBL_LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_TBL_LOG_AUDITORIAS.NEXTVAL, pn_id_usuario, 'REGISTRAR_PACIENTE_RECEPCION', 'TBL_PACIENTES', pn_id_paciente,
                NULL, 'documento=' || vs_doc);
        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            ROLLBACK;
            PRO_TRADUCIR_DUPLICADO(SQLERRM);
            RAISE;
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END PRO_REGISTRAR_PACIENTE_RECEPCION;

END PKG_USUARIOS;
/
SHOW ERRORS

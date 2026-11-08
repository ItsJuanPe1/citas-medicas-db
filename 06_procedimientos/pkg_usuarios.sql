-- =====================================================================
-- PKG_USUARIOS: registro de pacientes y gestion de cuentas (alta de personal, estado, clave).
-- Inserta en USUARIOS y en PACIENTES / MEDICOS / FARMACEUTICOS. No modifica la estructura de ninguna tabla.
-- La clave se guarda como SHA-256 en hex mayuscula (igual que los usuarios existentes).
-- Errores: 20501-20599. (20511: clave actual incorrecta; 20512: la nueva clave es igual a la actual)
-- =====================================================================
CREATE OR REPLACE PACKAGE PKG_USUARIOS AS

    -- Registro publico: crea el paciente y su usuario (rol PACIENTE) en una sola transaccion.
    PROCEDURE REGISTRAR_PACIENTE(
        p_documento  IN  VARCHAR2,
        p_nombre     IN  VARCHAR2,
        p_apellido   IN  VARCHAR2,
        p_fecha_nac  IN  DATE,
        p_telefono   IN  VARCHAR2,
        p_email      IN  VARCHAR2,
        p_username   IN  VARCHAR2,
        p_password   IN  VARCHAR2,
        p_id_usuario OUT NUMBER
    );

    -- Alta de personal por el administrador. p_rol: MEDICO | FARMACEUTICO | RECEPCIONISTA | GERENTE.
    -- MEDICO y FARMACEUTICO crean tambien su ficha (documento, nombre y apellido obligatorios;
    -- el medico ademas necesita p_id_especialidad). RECEPCIONISTA y GERENTE solo tienen usuario.
    PROCEDURE CREAR_PERSONAL(
        p_rol             IN  VARCHAR2,
        p_documento       IN  VARCHAR2,
        p_nombre          IN  VARCHAR2,
        p_apellido        IN  VARCHAR2,
        p_id_especialidad IN  NUMBER,
        p_telefono        IN  VARCHAR2,
        p_email           IN  VARCHAR2,
        p_username        IN  VARCHAR2,
        p_password        IN  VARCHAR2,
        p_id_admin        IN  NUMBER,
        p_id_usuario      OUT NUMBER
    );

    -- ACTIVO / INACTIVO. Un administrador no puede desactivar su propia cuenta.
    PROCEDURE CAMBIAR_ESTADO(
        p_id_usuario IN NUMBER,
        p_estado     IN VARCHAR2,
        p_id_admin   IN NUMBER
    );

    -- Restablece la clave a una TEMPORAL: la persona debera cambiarla en su proximo ingreso.
    PROCEDURE RESTABLECER_CLAVE(
        p_id_usuario IN NUMBER,
        p_nueva      IN VARCHAR2,
        p_id_admin   IN NUMBER
    );

    -- La propia persona cambia su clave (exige la actual) y deja de ser temporal.
    PROCEDURE CAMBIAR_CLAVE(
        p_id_usuario IN NUMBER,
        p_actual     IN VARCHAR2,
        p_nueva      IN VARCHAR2
    );

    -- La recepcionista registra un paciente que llega sin cuenta (solo la ficha, sin usuario).
    -- Despues puede reservarle citas; si luego quiere cuenta propia, se registra aparte.
    PROCEDURE REGISTRAR_PACIENTE_RECEPCION(
        p_documento   IN  VARCHAR2,
        p_nombre      IN  VARCHAR2,
        p_apellido    IN  VARCHAR2,
        p_fecha_nac   IN  DATE,
        p_telefono    IN  VARCHAR2,
        p_email       IN  VARCHAR2,
        p_id_usuario  IN  NUMBER,
        p_id_paciente OUT NUMBER
    );

END PKG_USUARIOS;
/

CREATE OR REPLACE PACKAGE BODY PKG_USUARIOS AS

    -- STANDARD_HASH solo se puede usar dentro de una sentencia SQL, no como expresion PL/SQL
    FUNCTION hash_clave(p_clave VARCHAR2) RETURN VARCHAR2 IS
        v_h VARCHAR2(64);
    BEGIN
        SELECT RAWTOHEX(STANDARD_HASH(p_clave, 'SHA256')) INTO v_h FROM DUAL;
        RETURN v_h;
    END hash_clave;

    PROCEDURE validar_clave(p_clave VARCHAR2) IS
    BEGIN
        IF p_clave IS NULL OR LENGTH(p_clave) < 8 OR LENGTH(p_clave) > 64
           OR NOT REGEXP_LIKE(p_clave, '[A-Za-z]') OR NOT REGEXP_LIKE(p_clave, '[0-9]') THEN
            RAISE_APPLICATION_ERROR(-20505, 'La contrasena debe tener entre 8 y 64 caracteres, con letras y numeros');
        END IF;
    END validar_clave;

    PROCEDURE validar_usuario(p_username VARCHAR2) IS
    BEGIN
        IF p_username IS NULL OR NOT REGEXP_LIKE(p_username, '^[a-z0-9._-]{4,30}$') THEN
            RAISE_APPLICATION_ERROR(-20504, 'El usuario debe tener 4 a 30 caracteres: letras minusculas, numeros, punto, guion o guion bajo');
        END IF;
    END validar_usuario;

    PROCEDURE validar_persona(p_documento VARCHAR2, p_nombre VARCHAR2, p_apellido VARCHAR2,
                              p_telefono VARCHAR2, p_email VARCHAR2) IS
    BEGIN
        IF p_documento IS NULL OR NOT REGEXP_LIKE(p_documento, '^[0-9]{5,20}$') THEN
            RAISE_APPLICATION_ERROR(-20504, 'El documento debe tener entre 5 y 20 digitos');
        END IF;
        IF p_nombre IS NULL OR p_apellido IS NULL OR LENGTH(p_nombre) > 100 OR LENGTH(p_apellido) > 100 THEN
            RAISE_APPLICATION_ERROR(-20504, 'Nombre y apellido son obligatorios (maximo 100 caracteres)');
        END IF;
        IF p_telefono IS NOT NULL AND NOT REGEXP_LIKE(p_telefono, '^[0-9+ ()-]{7,20}$') THEN
            RAISE_APPLICATION_ERROR(-20504, 'El telefono no tiene un formato valido');
        END IF;
        IF p_email IS NOT NULL AND (LENGTH(p_email) > 150 OR NOT REGEXP_LIKE(p_email, '^[^@ ]+@[^@ ]+\.[^@ ]+$')) THEN
            RAISE_APPLICATION_ERROR(-20504, 'El correo no tiene un formato valido');
        END IF;
    END validar_persona;

    -- Traduce los choques con las restricciones UNIQUE a mensajes claros
    PROCEDURE traducir_duplicado(p_msg VARCHAR2) IS
    BEGIN
        IF INSTR(p_msg, 'UQ_USUARIOS_USERNAME') > 0 THEN
            RAISE_APPLICATION_ERROR(-20501, 'Ese nombre de usuario ya esta en uso');
        ELSIF INSTR(p_msg, '_DOCUMENTO') > 0 THEN
            RAISE_APPLICATION_ERROR(-20502, 'Ese documento ya esta registrado');
        ELSIF INSTR(p_msg, '_EMAIL') > 0 THEN
            RAISE_APPLICATION_ERROR(-20503, 'Ese correo ya esta registrado');
        END IF;
    END traducir_duplicado;

    FUNCTION id_rol(p_nombre VARCHAR2) RETURN NUMBER IS
        v NUMBER;
    BEGIN
        SELECT ID_ROL INTO v FROM ROLES WHERE NOMBRE = p_nombre;
        RETURN v;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20506, 'Rol no valido');
    END id_rol;

    PROCEDURE auditar(p_quien NUMBER, p_accion VARCHAR2, p_id NUMBER, p_antes VARCHAR2, p_despues VARCHAR2) IS
    BEGIN
        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_quien, p_accion, 'USUARIOS', p_id, p_antes, p_despues);
    END auditar;

    ------------------------------------------------------------ REGISTRAR_PACIENTE
    PROCEDURE REGISTRAR_PACIENTE(
        p_documento  IN  VARCHAR2,
        p_nombre     IN  VARCHAR2,
        p_apellido   IN  VARCHAR2,
        p_fecha_nac  IN  DATE,
        p_telefono   IN  VARCHAR2,
        p_email      IN  VARCHAR2,
        p_username   IN  VARCHAR2,
        p_password   IN  VARCHAR2,
        p_id_usuario OUT NUMBER
    ) IS
        v_doc   VARCHAR2(20)  := TRIM(p_documento);
        v_nom   VARCHAR2(100) := TRIM(p_nombre);
        v_ape   VARCHAR2(100) := TRIM(p_apellido);
        v_tel   VARCHAR2(20)  := TRIM(p_telefono);
        v_mail  VARCHAR2(150) := LOWER(TRIM(p_email));
        v_user  VARCHAR2(50)  := LOWER(TRIM(p_username));
        v_pac   NUMBER;
        v_rol   NUMBER;
        v_hash  VARCHAR2(64);
    BEGIN
        validar_persona(v_doc, v_nom, v_ape, v_tel, v_mail);
        validar_usuario(v_user);
        validar_clave(p_password);
        IF p_fecha_nac IS NULL OR p_fecha_nac > TRUNC(SYSDATE) OR p_fecha_nac < DATE '1900-01-01' THEN
            RAISE_APPLICATION_ERROR(-20504, 'La fecha de nacimiento no es valida');
        END IF;
        v_rol  := id_rol('PACIENTE');
        v_hash := hash_clave(p_password);  -- las funciones del paquete no pueden ir dentro del INSERT

        INSERT INTO PACIENTES (ID_PACIENTE, DOCUMENTO, NOMBRE, APELLIDO, FECHA_NACIMIENTO, TELEFONO, EMAIL)
        VALUES (SEQ_PACIENTES.NEXTVAL, v_doc, v_nom, v_ape, p_fecha_nac, v_tel, v_mail)
        RETURNING ID_PACIENTE INTO v_pac;

        INSERT INTO USUARIOS (ID_USUARIO, ID_ROL, USERNAME, PASSWORD, ID_ENTIDAD, ESTADO)
        VALUES (SEQ_USUARIOS.NEXTVAL, v_rol, v_user, v_hash, v_pac, 'ACTIVO')
        RETURNING ID_USUARIO INTO p_id_usuario;

        auditar(p_id_usuario, 'REGISTRAR_PACIENTE', p_id_usuario, NULL, 'usuario=' || v_user || '; paciente=' || v_pac);
        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            ROLLBACK;
            traducir_duplicado(SQLERRM);
            RAISE;
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END REGISTRAR_PACIENTE;

    ------------------------------------------------------------ CREAR_PERSONAL
    PROCEDURE CREAR_PERSONAL(
        p_rol             IN  VARCHAR2,
        p_documento       IN  VARCHAR2,
        p_nombre          IN  VARCHAR2,
        p_apellido        IN  VARCHAR2,
        p_id_especialidad IN  NUMBER,
        p_telefono        IN  VARCHAR2,
        p_email           IN  VARCHAR2,
        p_username        IN  VARCHAR2,
        p_password        IN  VARCHAR2,
        p_id_admin        IN  NUMBER,
        p_id_usuario      OUT NUMBER
    ) IS
        v_doc   VARCHAR2(20)  := TRIM(p_documento);
        v_nom   VARCHAR2(100) := TRIM(p_nombre);
        v_ape   VARCHAR2(100) := TRIM(p_apellido);
        v_tel   VARCHAR2(20)  := TRIM(p_telefono);
        v_mail  VARCHAR2(150) := LOWER(TRIM(p_email));
        v_user  VARCHAR2(50)  := LOWER(TRIM(p_username));
        v_ent   NUMBER;
        v_n     NUMBER;
        v_rolid NUMBER;
        v_hash  VARCHAR2(64);
    BEGIN
        IF p_rol IS NULL OR p_rol NOT IN ('MEDICO', 'FARMACEUTICO', 'RECEPCIONISTA', 'GERENTE') THEN
            RAISE_APPLICATION_ERROR(-20506, 'Rol no valido para crear personal');
        END IF;
        validar_usuario(v_user);
        validar_clave(p_password);

        IF p_rol IN ('MEDICO', 'FARMACEUTICO') THEN
            validar_persona(v_doc, v_nom, v_ape, v_tel, v_mail);
        END IF;

        IF p_rol = 'MEDICO' THEN
            SELECT COUNT(*) INTO v_n FROM PARAMETRICA_TIPOS
             WHERE ID_PARAMETRO = p_id_especialidad AND NOMBRE = 'ESPECIALIDAD';
            IF v_n = 0 THEN
                RAISE_APPLICATION_ERROR(-20507, 'La especialidad no es valida');
            END IF;
            INSERT INTO MEDICOS (ID_MEDICO, DOCUMENTO, NOMBRE, APELLIDO, ID_ESPECIALIDAD, TELEFONO, EMAIL)
            VALUES (SEQ_MEDICOS.NEXTVAL, v_doc, v_nom, v_ape, p_id_especialidad, v_tel, v_mail)
            RETURNING ID_MEDICO INTO v_ent;
        ELSIF p_rol = 'FARMACEUTICO' THEN
            INSERT INTO FARMACEUTICOS (ID_FARMACEUTICO, DOCUMENTO, NOMBRE, APELLIDO, TELEFONO, EMAIL)
            VALUES (SEQ_FARMACEUTICOS.NEXTVAL, v_doc, v_nom, v_ape, v_tel, v_mail)
            RETURNING ID_FARMACEUTICO INTO v_ent;
        END IF;

        v_rolid := id_rol(p_rol);
        v_hash  := hash_clave(p_password);
        INSERT INTO USUARIOS (ID_USUARIO, ID_ROL, USERNAME, PASSWORD, ID_ENTIDAD, ESTADO, DEBE_CAMBIAR_CLAVE)
        VALUES (SEQ_USUARIOS.NEXTVAL, v_rolid, v_user, v_hash, v_ent, 'ACTIVO', 'S')
        RETURNING ID_USUARIO INTO p_id_usuario;

        auditar(p_id_admin, 'CREAR_PERSONAL', p_id_usuario, NULL,
                'usuario=' || v_user || '; rol=' || p_rol || '; entidad=' || NVL(TO_CHAR(v_ent), '-'));
        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            ROLLBACK;
            traducir_duplicado(SQLERRM);
            RAISE;
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END CREAR_PERSONAL;

    ------------------------------------------------------------ CAMBIAR_ESTADO
    PROCEDURE CAMBIAR_ESTADO(
        p_id_usuario IN NUMBER,
        p_estado     IN VARCHAR2,
        p_id_admin   IN NUMBER
    ) IS
        v_antes VARCHAR2(10);
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        IF p_estado IS NULL OR p_estado NOT IN ('ACTIVO', 'INACTIVO') THEN
            RAISE_APPLICATION_ERROR(-20509, 'El estado debe ser ACTIVO o INACTIVO');
        END IF;
        IF p_estado = 'INACTIVO' AND p_id_usuario = p_id_admin THEN
            RAISE_APPLICATION_ERROR(-20509, 'No puedes desactivar tu propia cuenta');
        END IF;
        BEGIN
            SELECT ESTADO INTO v_antes FROM USUARIOS WHERE ID_USUARIO = p_id_usuario FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20508, 'El usuario no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20510, 'Este usuario se esta modificando, intenta de nuevo');
        END;
        UPDATE USUARIOS SET ESTADO = p_estado WHERE ID_USUARIO = p_id_usuario;
        auditar(p_id_admin, 'CAMBIAR_ESTADO_USUARIO', p_id_usuario, 'estado=' || v_antes, 'estado=' || p_estado);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END CAMBIAR_ESTADO;

    ------------------------------------------------------------ RESTABLECER_CLAVE
    PROCEDURE RESTABLECER_CLAVE(
        p_id_usuario IN NUMBER,
        p_nueva      IN VARCHAR2,
        p_id_admin   IN NUMBER
    ) IS
        v_hash VARCHAR2(64);
    BEGIN
        validar_clave(p_nueva);
        v_hash := hash_clave(p_nueva);
        UPDATE USUARIOS SET PASSWORD = v_hash, DEBE_CAMBIAR_CLAVE = 'S' WHERE ID_USUARIO = p_id_usuario;
        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20508, 'El usuario no existe');
        END IF;
        auditar(p_id_admin, 'RESTABLECER_CLAVE', p_id_usuario, NULL, 'clave temporal asignada');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END RESTABLECER_CLAVE;

    ------------------------------------------------------------ CAMBIAR_CLAVE
    PROCEDURE CAMBIAR_CLAVE(
        p_id_usuario IN NUMBER,
        p_actual     IN VARCHAR2,
        p_nueva      IN VARCHAR2
    ) IS
        v_hash  VARCHAR2(255);
        v_nuevo VARCHAR2(64);
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -30006);
    BEGIN
        validar_clave(p_nueva);
        BEGIN
            SELECT PASSWORD INTO v_hash FROM USUARIOS WHERE ID_USUARIO = p_id_usuario FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20508, 'El usuario no existe');
            WHEN e_bloqueado THEN
                RAISE_APPLICATION_ERROR(-20510, 'Tu cuenta se esta modificando, intenta de nuevo');
        END;
        IF p_actual IS NULL OR v_hash <> hash_clave(p_actual) THEN
            RAISE_APPLICATION_ERROR(-20511, 'La contrasena actual no es correcta');
        END IF;
        v_nuevo := hash_clave(p_nueva);
        IF v_nuevo = v_hash THEN
            RAISE_APPLICATION_ERROR(-20512, 'La nueva contrasena debe ser distinta de la actual');
        END IF;
        UPDATE USUARIOS SET PASSWORD = v_nuevo, DEBE_CAMBIAR_CLAVE = 'N' WHERE ID_USUARIO = p_id_usuario;
        auditar(p_id_usuario, 'CAMBIAR_CLAVE', p_id_usuario, NULL, 'clave cambiada por el usuario');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END CAMBIAR_CLAVE;

    ------------------------------------------------------------ REGISTRAR_PACIENTE_RECEPCION
    PROCEDURE REGISTRAR_PACIENTE_RECEPCION(
        p_documento   IN  VARCHAR2,
        p_nombre      IN  VARCHAR2,
        p_apellido    IN  VARCHAR2,
        p_fecha_nac   IN  DATE,
        p_telefono    IN  VARCHAR2,
        p_email       IN  VARCHAR2,
        p_id_usuario  IN  NUMBER,
        p_id_paciente OUT NUMBER
    ) IS
        v_doc   VARCHAR2(20)  := TRIM(p_documento);
        v_nom   VARCHAR2(100) := TRIM(p_nombre);
        v_ape   VARCHAR2(100) := TRIM(p_apellido);
        v_tel   VARCHAR2(20)  := TRIM(p_telefono);
        v_mail  VARCHAR2(150) := LOWER(TRIM(p_email));
    BEGIN
        validar_persona(v_doc, v_nom, v_ape, v_tel, v_mail);
        IF p_fecha_nac IS NOT NULL AND (p_fecha_nac > TRUNC(SYSDATE) OR p_fecha_nac < DATE '1900-01-01') THEN
            RAISE_APPLICATION_ERROR(-20504, 'La fecha de nacimiento no es valida');
        END IF;

        INSERT INTO PACIENTES (ID_PACIENTE, DOCUMENTO, NOMBRE, APELLIDO, FECHA_NACIMIENTO, TELEFONO, EMAIL)
        VALUES (SEQ_PACIENTES.NEXTVAL, v_doc, v_nom, v_ape, p_fecha_nac, v_tel, v_mail)
        RETURNING ID_PACIENTE INTO p_id_paciente;

        INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO, VALOR_ANTES, VALOR_DESPUES)
        VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_id_usuario, 'REGISTRAR_PACIENTE_RECEPCION', 'PACIENTES', p_id_paciente,
                NULL, 'documento=' || v_doc);
        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            ROLLBACK;
            traducir_duplicado(SQLERRM);
            RAISE;
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END REGISTRAR_PACIENTE_RECEPCION;

END PKG_USUARIOS;
/
SHOW ERRORS
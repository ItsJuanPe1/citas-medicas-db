-- Unica fila nueva de datos: estado NO_ASISTIO para citas que pasaron su hora sin atenderse.
-- No cambia tablas ni toca filas existentes. Ejecutar UNA vez por base (cada companero en la suya).
DECLARE
    v_existe NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_existe FROM PARAMETRICA_TIPOS
     WHERE NOMBRE = 'ESTADO_CITA' AND VALOR = 'NO_ASISTIO';
    IF v_existe = 0 THEN
        INSERT INTO PARAMETRICA_TIPOS (ID_PARAMETRO, ID_TIPO, NOMBRE, VALOR, DESCRIPCION)
        VALUES (SEQ_PARAMETRICA_TIPOS.NEXTVAL, 204, 'ESTADO_CITA', 'NO_ASISTIO',
                'Cita cuyo horario termino sin ser atendida');
        COMMIT;
    END IF;
END;
/
SELECT NOMBRE, VALOR FROM PARAMETRICA_TIPOS WHERE NOMBRE = 'ESTADO_CITA';

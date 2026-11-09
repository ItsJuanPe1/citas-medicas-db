-- =====================================================================
-- DESPUES de importar el archivo de datos exportado
-- Deja cada secuencia SEQ_<TABLA> en MAX(id) + 1 para que los proximos NEXTVAL
-- no choquen con los datos cargados.
-- =====================================================================
COMMIT;

SET SERVEROUTPUT ON
DECLARE
  TYPE t_vc IS TABLE OF VARCHAR2(40);
  c_tablas t_vc := t_vc(
    'TBL_ROLES',
    'TBL_USUARIOS',
    'TBL_PARAMETRICA_TIPOS',
    'TBL_LOG_AUDITORIAS',
    'TBL_MEDICOS',
    'TBL_FARMACEUTICOS',
    'TBL_AGENDAS_MEDICOS',
    'TBL_PACIENTES',
    'TBL_CITAS_MEDICAS',
    'TBL_HISTORIA_CLINICA',
    'TBL_RECETAS_MEDICAS',
    'TBL_MEDICAMENTOS',
    'TBL_DETALLE_RECETA',
    'TBL_STOCK_FARMACIA');
  c_pks t_vc := t_vc(
    'ID_ROL',
    'ID_USUARIO',
    'ID_PARAMETRO',
    'ID_LOG',
    'ID_MEDICO',
    'ID_FARMACEUTICO',
    'ID_AGENDA',
    'ID_PACIENTE',
    'ID_CITA',
    'ID_HISTORIA',
    'ID_RECETA',
    'ID_MEDICAMENTO',
    'ID_DETALLE',
    'ID_STOCK');
  v_max NUMBER;
BEGIN
  FOR i IN 1..c_tablas.COUNT LOOP
    EXECUTE IMMEDIATE 'SELECT NVL(MAX(' || c_pks(i) || '), 0) FROM ' || c_tablas(i) INTO v_max;
    EXECUTE IMMEDIATE 'DROP SEQUENCE SEQ_' || c_tablas(i);
    EXECUTE IMMEDIATE 'CREATE SEQUENCE SEQ_' || c_tablas(i) || ' START WITH ' || (v_max + 1) ||
                      ' INCREMENT BY 1 NOCACHE';
    DBMS_OUTPUT.PUT_LINE(RPAD('SEQ_' || c_tablas(i), 28) || ' -> siguiente valor: ' || (v_max + 1));
  END LOOP;
END;
/

-- =====================================================================
-- DESPUES de importar el archivo de datos exportado
-- Deja cada secuencia SEQ_<TABLA> en MAX(id) + 1 para que los proximos NEXTVAL
-- no choquen con los datos cargados.
-- =====================================================================
COMMIT;

SET SERVEROUTPUT ON
DECLARE
  TYPE t_vc IS TABLE OF VARCHAR2(40);
  vc_tablas t_vc := t_vc(
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
  vc_pks t_vc := t_vc(
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
  vn_max NUMBER;
BEGIN
  FOR vn_i IN 1..vc_tablas.COUNT LOOP
    EXECUTE IMMEDIATE 'SELECT NVL(MAX(' || vc_pks(vn_i) || '), 0) FROM ' || vc_tablas(vn_i) INTO vn_max;
    EXECUTE IMMEDIATE 'DROP SEQUENCE SEQ_' || vc_tablas(vn_i);
    EXECUTE IMMEDIATE 'CREATE SEQUENCE SEQ_' || vc_tablas(vn_i) || ' START WITH ' || (vn_max + 1) ||
                      ' INCREMENT BY 1 NOCACHE';
    DBMS_OUTPUT.PUT_LINE(RPAD('SEQ_' || vc_tablas(vn_i), 28) || ' -> siguiente valor: ' || (vn_max + 1));
  END LOOP;
END;
/

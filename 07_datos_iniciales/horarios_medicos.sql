-- =====================================================================
-- Horarios semanales iniciales para TODOS los medicos (se repiten cada semana, ~1 anio por delante).
-- Correr DESPUES de compilar 06_procedimientos/pkg_agendas.sql. Se puede repetir: rehace las agendas
-- futuras sin citas de cada medico (las que ya tienen citas no se tocan).
-- Despues cada medico puede cambiar el suyo desde la pantalla "Horarios".
-- =====================================================================
SET SERVEROUTPUT ON
DECLARE
    TYPE t_pat IS TABLE OF VARCHAR2(200) INDEX BY PLS_INTEGER;
    vc_pat t_pat;
    vn_n   NUMBER;
    vn_i   PLS_INTEGER := 0;
BEGIN
    vc_pat(0) := 'LUNES~08:00~12:00|MIERCOLES~08:00~12:00|VIERNES~08:00~12:00';
    vc_pat(1) := 'MARTES~14:00~18:00|JUEVES~14:00~18:00';
    vc_pat(2) := 'LUNES~14:00~18:00|MARTES~08:00~12:00|JUEVES~08:00~12:00';
    vc_pat(3) := 'MIERCOLES~08:00~17:00|SABADO~08:00~12:00';
    vc_pat(4) := 'MARTES~16:00~19:00|JUEVES~16:00~19:00|VIERNES~14:00~18:00';

    FOR vr_m IN (SELECT ID_MEDICO FROM TBL_MEDICOS ORDER BY ID_MEDICO) LOOP
        PKG_AGENDAS.PRO_GUARDAR_HORARIO_SEMANAL(vr_m.ID_MEDICO, vc_pat(MOD(vn_i, 5)), 0, 52, vn_n);
        DBMS_OUTPUT.PUT_LINE('Medico ' || vr_m.ID_MEDICO || ': ' || vn_n || ' agendas');
        vn_i := vn_i + 1;
    END LOOP;
END;
/
SELECT ID_MEDICO, COUNT(*) AS AGENDAS_FUTURAS FROM TBL_AGENDAS_MEDICOS WHERE FECHA_HORA_FIN > SYSTIMESTAMP GROUP BY ID_MEDICO ORDER BY ID_MEDICO;

-- =====================================================================
-- SISTEMA DE CITAS MEDICAS - Script Oracle (carga de datos de prueba)
-- Ejecutar DESPUES de CREACION_TABLAS_v2.sql y ANTES de crear los triggers
-- (el de HU04 bloquearia las historias, porque las citas entran ya como ATENDIDA, y los
-- triggers de entrega de recetas recalcularian estados que aqui ya se cargan calculados).
-- OJO: al inicio borra el contenido de las 14 tablas y lo vuelve a cargar.
--
-- Reglas que cumple:
--   * 100 pacientes (5 de ellos NUNCA tienen citas: los de indice 20, 40, 60, 80, 100)
--   * 10 medicos, cada uno de una especialidad distinta
--   * Entre 3 y 7 citas por paciente (los 95 con citas)
--   * Exactamente 20% de las citas canceladas
--   * Registros distribuidos en los ultimos ~6 meses (hasta ayer)
--   * Ademas, algunas citas PROGRAMADAS en los proximos 7 dias (para probar HU04 y HU09)
--   * Cada medico atiende entre 3 y 5 dias fijos de la semana (lunes a viernes)
--   * Roles: SUPERADMIN, GERENTE, RECEPCIONISTA, MEDICO, PACIENTE, FARMACEUTICO.
--     USUARIOS solo trae credenciales: USERNAME (nombre + numero, ej. pablo23), PASSWORD (hash SHA256;
--     la clave de prueba de TODOS es Clave123) e
--     ID_ENTIDAD (id del medico/paciente/farmaceutico; NULL para superadmin1, gerente1,
--     recepcionista1 y recepcionista2) y ESTADO
--   * Cada cita tiene su propio slot en AGENDAS_MEDICOS (UQ por ID_AGENDA)
--   * Citas atendidas -> historia clinica; ~60% de las historias -> receta
--   * Las recetas dependen del diagnostico (solo los que lo requieren llevan receta)
--   * Cita cancelada: su slot queda OCUPADA y se crea un slot NUEVO DISPONIBLE a la misma hora
--   * Entrega de recetas: cada medicamento (DETALLE_RECETA) queda ENTREGADO, entregado
--     parcialmente (CANTIDAD_PENDIENTE > 0, estado NO ENTREGADO) o sin entregar; al entregar se guarda
--     el ID_FARMACEUTICO. El estado de la receta se calcula con esos detalles (ENTREGADA /
--     PARCIALMENTE / NO ENTREGADA)
--   * LOG_AUDITORIAS: ID_USUARIO (sin FK), ID_REGISTRO, VALOR_ANTES y VALOR_DESPUES
--   * Se usa DBMS_RANDOM.SEED fijo; las fechas son relativas al dia de ejecucion
-- Nota: los textos van sin tildes para evitar problemas de codificacion.
-- =====================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  TYPE t_vc   IS TABLE OF VARCHAR2(200);
  TYPE t_numl IS TABLE OF NUMBER;
  TYPE t_tab_numl IS TABLE OF t_numl;
  TYPE t_nt   IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  TYPE t_dt   IS TABLE OF DATE   INDEX BY PLS_INTEGER;
  TYPE t_map  IS TABLE OF NUMBER INDEX BY VARCHAR2(60);

  c_pacientes  CONSTANT PLS_INTEGER := 100;
  c_medicos    CONSTANT PLS_INTEGER := 10;
  c_dias_atras CONSTANT PLS_INTEGER := 165;   -- las citas caen entre hoy-165 y ayer

  v_hoy  DATE := TRUNC(SYSDATE);
  v_base DATE := TRUNC(SYSDATE) - 180 + 8/24; -- fecha de creacion de catalogos

  -- ---------- catalogos de texto ----------
  c_nombres t_vc := t_vc('Juan','Maria','Carlos','Luisa','Andres','Camila','Santiago','Valentina',
    'Daniel','Laura','Sebastian','Paula','Felipe','Daniela','Jorge','Natalia','Alejandro','Sofia',
    'David','Carolina','Miguel','Juliana','Oscar','Mariana','Diego','Isabela','Cristian','Katherine',
    'Nicolas','Andrea','Jhon','Stephany','Mateo','Manuela','Esteban','Lina','Julian','Gabriela',
    'Sergio','Angela');
  c_apellidos t_vc := t_vc('Garcia','Rodriguez','Martinez','Lopez','Gonzalez','Hernandez','Perez',
    'Sanchez','Ramirez','Torres','Florez','Diaz','Vargas','Castro','Rojas','Moreno','Ortiz',
    'Gutierrez','Munoz','Jimenez','Mendoza','Cardona','Valencia','Arias','Ospina','Zapata',
    'Restrepo','Marin','Bedoya','Quintero','Cortes','Acosta','Herrera','Montoya','Salazar',
    'Velasquez','Cruz','Giraldo','Ramos','Parra');

  c_roles    t_vc := t_vc('SUPERADMIN','GERENTE','RECEPCIONISTA','MEDICO','PACIENTE','FARMACEUTICO');
  c_roles_d  t_vc := t_vc('Administra el sistema y los roles','Consulta reportes consolidados','Agenda y gestiona citas',
                          'Medico del sistema','Paciente del sistema','Entrega medicamentos');

  -- usuarios sin entidad (ID_ENTIDAD = NULL)
  s_user t_vc   := t_vc('superadmin1','gerente1','recepcionista1','recepcionista2');
  s_rol  t_numl := t_numl(1,2,3,3);
  -- farmaceuticos (entidad + usuario)
  f_nom t_vc := t_vc('Monica','Hector','Paola');
  f_ape t_vc := t_vc('Duque','Becerra','Naranjo');

  c_esp t_vc := t_vc('Cardiologia','Pediatria','Dermatologia','Ginecologia','Neurologia',
                     'Ortopedia y Traumatologia','Oftalmologia','Otorrinolaringologia','Psiquiatria','Endocrinologia');
  m_nom t_vc := t_vc('Ricardo','Martha','Hernan','Claudia','Alvaro','Beatriz','Gustavo','Adriana','Fernando','Liliana');
  m_ape t_vc := t_vc('Torres','Cardona','Ospina','Restrepo','Quintero','Valencia','Mendoza','Zapata','Bedoya','Giraldo');
  -- dias fijos de atencion por medico (0 = lunes ... 4 = viernes; entre 3 y 5 dias), en el mismo orden que m_nom
  c_dias_med t_vc := t_vc('024','1234','013','01234','034','0123','134','014','024','1234');

  c_est_rec   t_vc := t_vc('NO ENTREGADA','PARCIALMENTE','ENTREGADA');
  c_est_rec_d t_vc := t_vc('Receta sin ningun medicamento entregado','Receta con medicamentos pendientes por entregar','Receta con todos los medicamentos entregados');
  c_est_det   t_vc := t_vc('NO ENTREGADO','ENTREGADO');
  c_est_det_d t_vc := t_vc('Medicamento pendiente por entregar','Medicamento entregado completo por el farmaceutico');
  c_est_ag    t_vc := t_vc('DISPONIBLE','OCUPADA');
  c_est_ag_d  t_vc := t_vc('Horario libre para reservar','Horario con cita asignada');

  c_estados   t_vc := t_vc('PROGRAMADA','ATENDIDA','CANCELADA');
  c_estados_d t_vc := t_vc('Cita agendada pendiente de atencion','Cita atendida por el medico','Cita cancelada antes de su atencion');

  c_tipos_med t_vc := t_vc('Analgesico','Antibiotico','Antiinflamatorio','Antihistaminico',
                           'Antihipertensivo','Antidiabetico','Gastroprotector','Corticoide');
  c_tipos_med_d t_vc := t_vc('Analgesico y antipiretico','Antibiotico','Antiinflamatorio no esteroideo',
                             'Antihistaminico','Antihipertensivo','Antidiabetico oral','Gastroprotector','Corticoide');

  c_med_nom t_vc := t_vc('Acetaminofen 500 mg','Ibuprofeno 400 mg','Amoxicilina 500 mg','Azitromicina 500 mg',
    'Cefalexina 500 mg','Diclofenaco 50 mg','Naproxeno 250 mg','Loratadina 10 mg','Cetirizina 10 mg',
    'Losartan 50 mg','Enalapril 20 mg','Amlodipino 5 mg','Metformina 850 mg','Glibenclamida 5 mg',
    'Omeprazol 20 mg','Pantoprazol 40 mg','Prednisolona 5 mg','Betametasona crema 0.05%',
    'Acetaminofen jarabe 120 mg/5 ml','Hidrocortisona crema 1%');
  c_med_tipo t_numl := t_numl(1,3,2,2,2,3,3,4,4,5,5,5,6,6,7,7,8,8,1,8);
  c_med_pres t_vc := t_vc('Caja x 100 tabletas','Caja x 50 tabletas','Caja x 21 capsulas','Caja x 3 tabletas',
    'Caja x 20 capsulas','Caja x 30 tabletas','Caja x 30 tabletas','Caja x 10 tabletas','Caja x 10 tabletas',
    'Caja x 30 tabletas','Caja x 30 tabletas','Caja x 30 tabletas','Caja x 60 tabletas','Caja x 30 tabletas',
    'Caja x 14 capsulas','Caja x 14 tabletas','Caja x 20 tabletas','Tubo x 30 g','Frasco x 60 ml','Tubo x 15 g');

  -- tratamiento tipico de cada medicamento (mismo orden que c_med_nom): dosis y cantidad total a entregar
  c_med_dosis t_vc := t_vc(
    '1 tableta cada 8 horas por 5 dias','1 tableta cada 8 horas por 5 dias','1 capsula cada 8 horas por 7 dias',
    '1 tableta cada 24 horas por 3 dias','1 capsula cada 6 horas por 7 dias','1 tableta cada 12 horas por 5 dias',
    '1 tableta cada 12 horas por 5 dias','1 tableta cada 24 horas por 7 dias','1 tableta en la noche por 7 dias',
    '1 tableta cada 24 horas por 30 dias','1 tableta cada 24 horas por 30 dias','1 tableta cada 24 horas por 30 dias',
    '1 tableta cada 12 horas por 30 dias','1 tableta cada 24 horas por 30 dias','1 capsula en ayunas por 14 dias',
    '1 tableta en ayunas por 14 dias','2 tabletas cada 24 horas por 5 dias',
    'Aplicar en la zona afectada 2 veces al dia por 10 dias','5 ml cada 8 horas por 3 dias',
    'Aplicar capa fina en la zona afectada 1 vez al dia por 7 dias');
  c_med_cant t_numl := t_numl(15,15,21,3,28,10,10,7,7,30,30,30,60,30,14,14,10,1,1,1);

  -- medicamentos (indices de c_med_nom) que se recetan para cada diagnostico (mismo orden que c_diag)
  -- lista vacia = el diagnostico no genera receta (controles, examenes, terapia, etc.)
  c_diag_meds t_tab_numl := t_tab_numl(
    t_numl(10,11,12), t_numl(), t_numl(15,1), t_numl(),             -- Cardiologia
    t_numl(3,4,1), t_numl(), t_numl(19), t_numl(19,8),              -- Pediatria
    t_numl(20,18,9), t_numl(), t_numl(8,9,17), t_numl(),            -- Dermatologia
    t_numl(), t_numl(4), t_numl(), t_numl(2,7,1),                   -- Ginecologia
    t_numl(1,2,7), t_numl(1,7,2), t_numl(), t_numl(1,7),            -- Neurologia
    t_numl(2,6,7), t_numl(6,7,2,1), t_numl(6,7,2), t_numl(1,6,15),  -- Ortopedia
    t_numl(), t_numl(8,9), t_numl(), t_numl(),                      -- Oftalmologia
    t_numl(3,1,2), t_numl(8,9), t_numl(3,4,1), t_numl(3,8,17),      -- Otorrinolaringologia
    t_numl(), t_numl(), t_numl(), t_numl(),                         -- Psiquiatria (no receta)
    t_numl(13,14), t_numl(), t_numl(13), t_numl());                 -- Endocrinologia

  -- 4 diagnosticos por especialidad (indice = (especialidad-1)*4 + n)
  c_diag t_vc := t_vc(
    'Hipertension arterial controlada','Arritmia cardiaca leve','Dolor toracico de origen no cardiaco','Dislipidemia mixta',
    'Infeccion respiratoria aguda','Control de crecimiento y desarrollo normal','Gastroenteritis aguda','Rinofaringitis viral',
    'Dermatitis atopica','Acne vulgar grado II','Urticaria aguda','Micosis cutanea',
    'Control prenatal sin complicaciones','Vaginosis bacteriana','Control anual de citologia normal','Dismenorrea primaria',
    'Cefalea tensional','Migrana sin aura','Vertigo posicional benigno','Neuropatia periferica leve',
    'Esguince de tobillo grado I','Lumbalgia mecanica','Tendinitis del manguito rotador','Gonartrosis leve',
    'Miopia con astigmatismo','Conjuntivitis alergica','Ojo seco','Control de presion intraocular normal',
    'Otitis media aguda','Rinitis alergica','Amigdalitis aguda','Sinusitis cronica',
    'Trastorno de ansiedad generalizada','Episodio depresivo leve','Insomnio cronico','Trastorno de adaptacion',
    'Diabetes mellitus tipo 2','Hipotiroidismo','Prediabetes','Obesidad grado I');
  c_notas t_vc := t_vc('Paciente estable, se indica control en 3 meses.','Se solicitan examenes de laboratorio de control.',
    'Se recomienda reposo relativo e hidratacion.','Paciente responde bien al tratamiento actual.',
    'Se explican signos de alarma y se programa control.','Se remite a examenes complementarios.',
    'Se ajusta tratamiento segun evolucion.','Sin hallazgos relevantes en el examen fisico.');
  c_motivos t_vc := t_vc('solicitud del paciente','cruce de horario','calamidad domestica','mejoria de los sintomas');

  -- ---------- ids generados ----------
  v_id        NUMBER;
  v_rol       t_nt;
  v_esp       t_nt;
  v_tipo_med  t_nt;
  v_med_ids   t_nt;   -- medicos
  v_med_cat   t_nt;   -- medicamentos
  v_pac_ids   t_nt;
  v_pac_nac   t_dt;
  v_est_prog  NUMBER;
  v_est_aten  NUMBER;
  v_est_canc  NUMBER;
  v_est_rec_no  NUMBER;
  v_est_rec_par NUMBER;
  v_est_rec_ent NUMBER;
  v_est_det_no  NUMBER;
  v_est_det_si  NUMBER;
  v_est_ag_disp NUMBER;
  v_est_ag_ocup NUMBER;
  v_far_ids   t_nt;   -- farmaceuticos
  v_usr_pac   t_nt;   -- id_usuario de cada paciente
  v_usr_med   t_nt;   -- id_usuario de cada medico
  v_usr_far   t_nt;   -- id_usuario de cada farmaceutico

  -- ---------- planificacion de citas ----------
  v_cnt   t_nt;
  v_flag  t_nt;
  v_total PLS_INTEGER := 0;
  v_resto PLS_INTEGER;
  v_ncanc PLS_INTEGER;
  v_tmp   NUMBER;
  v_j     PLS_INTEGER;
  c       PLS_INTEGER := 0;

  v_ocup_m t_map;   -- medico + fecha/hora
  v_ocup_p t_map;   -- paciente + fecha/hora
  v_pick   t_map;

  v_es_menor BOOLEAN;
  v_fut    BOOLEAN;
  v_dg     PLS_INTEGER;
  v_est    NUMBER;
  v_m      PLS_INTEGER;
  v_dia    DATE;
  v_idx    NUMBER;
  v_ini    DATE;
  v_fin    DATE;
  v_reg    DATE;
  v_can    DATE;
  v_aten   DATE;
  v_key_m  VARCHAR2(60);
  v_key_p  VARCHAR2(60);
  v_ag     NUMBER;
  v_cita   NUMBER;
  v_hist   NUMBER;
  v_rec    NUMBER;
  v_nmed   PLS_INTEGER;
  v_k      PLS_INTEGER;
  v_mm     PLS_INTEGER;
  v_cant   NUMBER;
  v_ape1   VARCHAR2(100);
  v_ape2   VARCHAR2(100);
  v_nom    VARCHAR2(100);
  v_cre    DATE;
  v_dsem   VARCHAR2(10);
  v_nota   VARCHAR2(200);
  v_n_aten PLS_INTEGER := 0;
  v_n_canc PLS_INTEGER := 0;
  v_n_hist PLS_INTEGER := 0;
  v_n_rec  PLS_INTEGER := 0;
  v_n_prog PLS_INTEGER := 0;
  v_esc    PLS_INTEGER;       -- escenario de entrega: 1 todo, 2 mixto, 3 nada
  v_pend   NUMBER;
  v_est_d  NUMBER;
  v_fx     PLS_INTEGER;       -- indice del farmaceutico que entrega
  v_fid    NUMBER;            -- id del farmaceutico (NULL si no se ha entregado nada)
  v_det    NUMBER;
  v_dt_ent DATE;
  v_nd_ent PLS_INTEGER;       -- detalles entregados completos
  v_nd_any PLS_INTEGER;       -- detalles con alguna entrega
  v_rnd    NUMBER;
  v_n_rec_ent PLS_INTEGER := 0;
  v_n_rec_par PLS_INTEGER := 0;
  v_n_rec_no  PLS_INTEGER := 0;

  FUNCTION f_dia(p_d DATE) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE TRUNC(p_d - TRUNC(p_d,'IW'))
             WHEN 0 THEN 'LUNES'   WHEN 1 THEN 'MARTES' WHEN 2 THEN 'MIERCOLES'
             WHEN 3 THEN 'JUEVES'  WHEN 4 THEN 'VIERNES' WHEN 5 THEN 'SABADO'
             ELSE 'DOMINGO' END;
  END;

  -- crea un usuario (la clave de prueba es Clave123; en la tabla se guarda su hash SHA256, no el texto)
  FUNCTION f_user(p_rol NUMBER, p_username VARCHAR2, p_ent NUMBER, p_fecha DATE) RETURN NUMBER IS
    v_u NUMBER;
  BEGIN
    INSERT INTO USUARIOS (ID_USUARIO, ID_ROL, USERNAME, PASSWORD, ID_ENTIDAD, ESTADO, CREATED_AT)
    VALUES (SEQ_USUARIOS.NEXTVAL, p_rol, p_username,
            RAWTOHEX(STANDARD_HASH('Clave123', 'SHA256')), p_ent, 'ACTIVO', p_fecha)
    RETURNING ID_USUARIO INTO v_u;
    RETURN v_u;
  END;

  -- bitacora: p_usr = id del usuario que hizo el cambio, p_reg = PK del registro afectado
  PROCEDURE p_log(p_usr NUMBER, p_accion VARCHAR2, p_tabla VARCHAR2, p_reg NUMBER,
                  p_antes VARCHAR2, p_desp VARCHAR2, p_fecha DATE) IS
  BEGIN
    INSERT INTO LOG_AUDITORIAS (ID_LOG, ID_USUARIO, ACCION, TABLA_AFECTADA, ID_REGISTRO,
                                VALOR_ANTES, VALOR_DESPUES, FECHA_HORA)
    VALUES (SEQ_LOG_AUDITORIAS.NEXTVAL, p_usr, p_accion, p_tabla, p_reg, p_antes, p_desp, p_fecha);
  END;

BEGIN
  DBMS_RANDOM.SEED(2026);

  -- Limpieza previa (por si se ejecuta mas de una vez)
  DELETE FROM DETALLE_RECETA;
  DELETE FROM RECETAS_MEDICAS;
  DELETE FROM HISTORIA_CLINICA;
  DELETE FROM CITAS_MEDICAS;
  DELETE FROM STOCK_FARMACIA;
  DELETE FROM MEDICAMENTOS;
  DELETE FROM AGENDAS_MEDICOS;
  DELETE FROM PACIENTES;
  DELETE FROM MEDICOS;
  DELETE FROM FARMACEUTICOS;
  DELETE FROM PARAMETRICA_TIPOS;
  DELETE FROM USUARIOS;
  DELETE FROM ROLES;
  DELETE FROM LOG_AUDITORIAS;

  -- 1. ROLES
  FOR i IN 1..c_roles.COUNT LOOP
    INSERT INTO ROLES (ID_ROL, NOMBRE, DESCRIPCION, CREATED_AT)
    VALUES (SEQ_ROLES.NEXTVAL, c_roles(i), c_roles_d(i), v_base)
    RETURNING ID_ROL INTO v_id;
    v_rol(i) := v_id;
  END LOOP;

  -- 2. PARAMETRICA_TIPOS (especialidades 101-110, estados de cita 201-203, tipos de medicamento 301-308,
  --    estados de receta 401-403, estados de detalle 501-502, estados de agenda 601-602)
  FOR i IN 1..c_esp.COUNT LOOP
    INSERT INTO PARAMETRICA_TIPOS (ID_PARAMETRO, ID_TIPO, NOMBRE, VALOR, DESCRIPCION, CREATED_AT)
    VALUES (SEQ_PARAMETRICA_TIPOS.NEXTVAL, 100 + i, 'ESPECIALIDAD', c_esp(i),
            'Especialidad medica: ' || c_esp(i), v_base)
    RETURNING ID_PARAMETRO INTO v_id;
    v_esp(i) := v_id;
  END LOOP;
  FOR i IN 1..c_estados.COUNT LOOP
    INSERT INTO PARAMETRICA_TIPOS (ID_PARAMETRO, ID_TIPO, NOMBRE, VALOR, DESCRIPCION, CREATED_AT)
    VALUES (SEQ_PARAMETRICA_TIPOS.NEXTVAL, 200 + i, 'ESTADO_CITA', c_estados(i), c_estados_d(i), v_base)
    RETURNING ID_PARAMETRO INTO v_id;
    IF i = 1 THEN v_est_prog := v_id; ELSIF i = 2 THEN v_est_aten := v_id; ELSE v_est_canc := v_id; END IF;
  END LOOP;
  FOR i IN 1..c_tipos_med.COUNT LOOP
    INSERT INTO PARAMETRICA_TIPOS (ID_PARAMETRO, ID_TIPO, NOMBRE, VALOR, DESCRIPCION, CREATED_AT)
    VALUES (SEQ_PARAMETRICA_TIPOS.NEXTVAL, 300 + i, 'TIPO_MEDICAMENTO', c_tipos_med(i), c_tipos_med_d(i), v_base)
    RETURNING ID_PARAMETRO INTO v_id;
    v_tipo_med(i) := v_id;
  END LOOP;
  FOR i IN 1..c_est_rec.COUNT LOOP
    INSERT INTO PARAMETRICA_TIPOS (ID_PARAMETRO, ID_TIPO, NOMBRE, VALOR, DESCRIPCION, CREATED_AT)
    VALUES (SEQ_PARAMETRICA_TIPOS.NEXTVAL, 400 + i, 'ESTADO_RECETA', c_est_rec(i), c_est_rec_d(i), v_base)
    RETURNING ID_PARAMETRO INTO v_id;
    IF i = 1 THEN v_est_rec_no := v_id; ELSIF i = 2 THEN v_est_rec_par := v_id; ELSE v_est_rec_ent := v_id; END IF;
  END LOOP;
  FOR i IN 1..c_est_det.COUNT LOOP
    INSERT INTO PARAMETRICA_TIPOS (ID_PARAMETRO, ID_TIPO, NOMBRE, VALOR, DESCRIPCION, CREATED_AT)
    VALUES (SEQ_PARAMETRICA_TIPOS.NEXTVAL, 500 + i, 'ESTADO_DETALLE_RECETA', c_est_det(i), c_est_det_d(i), v_base)
    RETURNING ID_PARAMETRO INTO v_id;
    IF i = 1 THEN v_est_det_no := v_id; ELSE v_est_det_si := v_id; END IF;
  END LOOP;
  FOR i IN 1..c_est_ag.COUNT LOOP
    INSERT INTO PARAMETRICA_TIPOS (ID_PARAMETRO, ID_TIPO, NOMBRE, VALOR, DESCRIPCION, CREATED_AT)
    VALUES (SEQ_PARAMETRICA_TIPOS.NEXTVAL, 600 + i, 'ESTADO_AGENDA', c_est_ag(i), c_est_ag_d(i), v_base)
    RETURNING ID_PARAMETRO INTO v_id;
    IF i = 1 THEN v_est_ag_disp := v_id; ELSE v_est_ag_ocup := v_id; END IF;
  END LOOP;

  -- 3. USUARIOS sin entidad (superadmin, gerente, recepcionistas) + FARMACEUTICOS con su usuario
  --    (los usuarios de medicos y pacientes se crean junto con cada uno, en las secciones 4 y 5)
  FOR i IN 1..s_user.COUNT LOOP
    v_id := f_user(v_rol(s_rol(i)), s_user(i), NULL, v_base);
  END LOOP;

  FOR i IN 1..f_nom.COUNT LOOP
    INSERT INTO FARMACEUTICOS (ID_FARMACEUTICO, DOCUMENTO, NOMBRE, APELLIDO, TELEFONO, EMAIL, CREATED_AT)
    VALUES (SEQ_FARMACEUTICOS.NEXTVAL, TO_CHAR(1110000000 + i), f_nom(i), f_ape(i),
            '3' || LPAD(TRUNC(DBMS_RANDOM.VALUE(0,1000000000)),9,'0'),
            LOWER(f_nom(i)) || '.' || LOWER(f_ape(i)) || '@clinica.com', v_base)
    RETURNING ID_FARMACEUTICO INTO v_id;
    v_far_ids(i) := v_id;
    v_usr_far(i) := f_user(v_rol(6), LOWER(f_nom(i)) || '.' || LOWER(f_ape(i)), v_id, v_base);
  END LOOP;

  -- 4. MEDICOS (10, una especialidad distinta cada uno)
  FOR i IN 1..c_medicos LOOP
    INSERT INTO MEDICOS (ID_MEDICO, DOCUMENTO, NOMBRE, APELLIDO, ID_ESPECIALIDAD, TELEFONO, EMAIL, CREATED_AT)
    VALUES (SEQ_MEDICOS.NEXTVAL, TO_CHAR(70000000 + i * 1234567), m_nom(i), m_ape(i), v_esp(i),
            '3' || LPAD(TRUNC(DBMS_RANDOM.VALUE(0,1000000000)),9,'0'),
            'dr.' || LOWER(m_ape(i)) || '@clinica.com', v_base)
    RETURNING ID_MEDICO INTO v_id;
    v_med_ids(i) := v_id;

    v_usr_med(i) := f_user(v_rol(4), 'dr.' || LOWER(m_ape(i)), v_id, v_base);
  END LOOP;

  -- 5. PACIENTES (100; los primeros 12 son menores de edad)
  FOR i IN 1..c_pacientes LOOP
    v_nom  := c_nombres(MOD(i * 7 + TRUNC((i - 1) / 40), 40) + 1);
    v_ape1 := c_apellidos(MOD(i * 11 + TRUNC((i - 1) / 40) * 13, 40) + 1);
    v_ape2 := c_apellidos(MOD(i * 3 + 5, 40) + 1);
    IF i <= 12 THEN
      v_pac_nac(i) := v_hoy - TRUNC(DBMS_RANDOM.VALUE(365 * 2, 365 * 14));
    ELSE
      v_pac_nac(i) := v_hoy - TRUNC(DBMS_RANDOM.VALUE(365 * 18, 365 * 80));
    END IF;
    v_cre := v_hoy - TRUNC(DBMS_RANDOM.VALUE(176, 181)) + DBMS_RANDOM.VALUE(8/24, 17/24);

    INSERT INTO PACIENTES (ID_PACIENTE, DOCUMENTO, NOMBRE, APELLIDO, FECHA_NACIMIENTO, TELEFONO, EMAIL, CREATED_AT)
    VALUES (SEQ_PACIENTES.NEXTVAL, TO_CHAR(1000000000 + i * 12347), v_nom, v_ape1 || ' ' || v_ape2,
            v_pac_nac(i), '3' || LPAD(TRUNC(DBMS_RANDOM.VALUE(0,1000000000)),9,'0'),
            LOWER(v_nom) || '.' || LOWER(v_ape1) || i || '@correo.com', v_cre)
    RETURNING ID_PACIENTE INTO v_id;
    v_pac_ids(i) := v_id;

    -- cada paciente tambien es usuario del sistema (rol PACIENTE); ID_ENTIDAD = su ID_PACIENTE
    v_usr_pac(i) := f_user(v_rol(5), LOWER(v_nom) || i, v_id, v_cre);
  END LOOP;

  -- 6. MEDICAMENTOS + STOCK_FARMACIA
  FOR j IN 1..c_med_nom.COUNT LOOP
    INSERT INTO MEDICAMENTOS (ID_MEDICAMENTO, ID_TIPO_MEDICAMENTO, NOMBRE, DESCRIPCION, PRESENTACION, CREATED_AT)
    VALUES (SEQ_MEDICAMENTOS.NEXTVAL, v_tipo_med(c_med_tipo(j)), c_med_nom(j),
            c_tipos_med_d(c_med_tipo(j)), c_med_pres(j), v_base)
    RETURNING ID_MEDICAMENTO INTO v_id;
    v_med_cat(j) := v_id;

    v_cant := TRUNC(DBMS_RANDOM.VALUE(20, 61));            -- cantidad minima
    v_tmp  := TRUNC(DBMS_RANDOM.VALUE(60, 401));           -- cantidad disponible
    IF j IN (3, 9, 15) THEN v_tmp := TRUNC(v_cant / 2); END IF;  -- 3 medicamentos bajo el minimo
    INSERT INTO STOCK_FARMACIA (ID_STOCK, ID_MEDICAMENTO, CANTIDAD_DISPONIBLE, CANTIDAD_MINIMA, CREATED_AT)
    VALUES (SEQ_STOCK_FARMACIA.NEXTVAL, v_id, v_tmp, v_cant, v_base);
  END LOOP;

  -- 7. Planificacion: citas por paciente (3..7; 0 para los pacientes MOD(i,20)=0)
  FOR i IN 1..c_pacientes LOOP
    IF MOD(i, 20) = 0 THEN
      v_cnt(i) := 0;
    ELSE
      v_cnt(i) := TRUNC(DBMS_RANDOM.VALUE(3, 8));
    END IF;
    v_total := v_total + v_cnt(i);
  END LOOP;

  -- Ajuste para que el total sea multiplo de 5 (20% exacto), sin salir del rango 3..7
  v_resto := MOD(v_total, 5);
  v_total := v_total - v_resto;
  FOR i IN 1..c_pacientes LOOP
    EXIT WHEN v_resto = 0;
    IF v_cnt(i) > 3 THEN
      v_cnt(i) := v_cnt(i) - 1;
      v_resto  := v_resto - 1;
    END IF;
  END LOOP;
  v_ncanc := v_total / 5;

  -- Marca de cancelacion por cita (exactamente v_ncanc) y mezcla Fisher-Yates
  FOR k IN 1..v_total LOOP
    v_flag(k) := CASE WHEN k <= v_ncanc THEN 1 ELSE 0 END;
  END LOOP;
  FOR k IN REVERSE 2..v_total LOOP
    v_j := TRUNC(DBMS_RANDOM.VALUE(1, k + 1));
    v_tmp := v_flag(k); v_flag(k) := v_flag(v_j); v_flag(v_j) := v_tmp;
  END LOOP;

  -- 8. AGENDAS_MEDICOS + CITAS_MEDICAS + HISTORIA_CLINICA + RECETAS + DETALLE
  FOR i IN 1..c_pacientes LOOP
    v_es_menor := v_pac_nac(i) > ADD_MONTHS(v_hoy, -180);   -- menor de 15 anios

    FOR n IN 1..v_cnt(i) LOOP
      c := c + 1;
      -- ~12% de las citas no canceladas quedan PROGRAMADAS (en los proximos 7 dias)
      v_fut := (v_flag(c) = 0 AND DBMS_RANDOM.VALUE < 0.12);

      -- elegir medico y slot libre (bloques de 30 min, 08:00-16:30, solo en los dias fijos del medico)
      LOOP
        v_m := TRUNC(DBMS_RANDOM.VALUE(1, c_medicos + 1));
        IF v_es_menor THEN
          IF DBMS_RANDOM.VALUE < 0.6 THEN
            v_m := 2;                                         -- los menores van mas a pediatria
          ELSIF v_m IN (1, 4, 9, 10) THEN
            CONTINUE;          -- y no a cardiologia, ginecologia, psiquiatria ni endocrinologia
          END IF;
        ELSIF v_m = 2 THEN
          CONTINUE;                                           -- adultos no van a pediatria
        END IF;
        IF v_fut THEN
          v_dia := v_hoy + TRUNC(DBMS_RANDOM.VALUE(1, 8));              -- programada: proximos 7 dias
        ELSE
          v_dia := v_hoy - TRUNC(DBMS_RANDOM.VALUE(1, c_dias_atras + 1));
        END IF;
        v_idx := v_dia - TRUNC(v_dia, 'IW');
        CONTINUE WHEN INSTR(c_dias_med(v_m), TO_CHAR(v_idx)) = 0;      -- solo los dias en que atiende ese medico
        v_ini   := v_dia + (8 + TRUNC(DBMS_RANDOM.VALUE(0, 18)) * 0.5) / 24;
        v_key_m := v_m || '-' || TO_CHAR(v_ini, 'YYYYMMDDHH24MI');
        v_key_p := 'P' || i || '-' || TO_CHAR(v_ini, 'YYYYMMDDHH24MI');
        EXIT WHEN NOT v_ocup_m.EXISTS(v_key_m) AND NOT v_ocup_p.EXISTS(v_key_p);
      END LOOP;
      v_ocup_m(v_key_m) := 1;
      v_ocup_p(v_key_p) := 1;

      v_fin  := v_ini + 30 / 1440;
      v_dsem := f_dia(v_ini);
      IF v_fut THEN
        v_reg := v_hoy - DBMS_RANDOM.VALUE(0, 7);     -- se agendo durante la ultima semana
      ELSE
        v_reg := v_ini - DBMS_RANDOM.VALUE(1, 10);    -- se agenda entre 1 y 10 dias antes
      END IF;

      -- estado de la cita (se calcula aqui porque un BOOLEAN no se puede usar dentro del INSERT)
      IF v_flag(c) = 1 THEN
        v_est := v_est_canc;
      ELSIF v_fut THEN
        v_est := v_est_prog;
      ELSE
        v_est := v_est_aten;
      END IF;

      -- slot de agenda de esta cita (relacion 1 a 1: cada cita tiene su propio slot)
      INSERT INTO AGENDAS_MEDICOS (ID_AGENDA, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN,
                                   DIA_SEMANA, ID_ESTADO, CREATED_AT)
      VALUES (SEQ_AGENDAS_MEDICOS.NEXTVAL, v_med_ids(v_m), v_ini, v_fin, v_dsem,
              v_est_ag_ocup, v_ini - 12)
      RETURNING ID_AGENDA INTO v_ag;

      INSERT INTO CITAS_MEDICAS (ID_CITA, ID_PACIENTE, ID_AGENDA, ID_ESTADO, FECHA_REGISTRO, CREATED_AT)
      VALUES (SEQ_CITAS_MEDICAS.NEXTVAL, v_pac_ids(i), v_ag,
              v_est, v_reg, v_reg)
      RETURNING ID_CITA INTO v_cita;

      p_log(v_usr_pac(i), 'INSERT', 'CITAS_MEDICAS', v_cita, NULL,
            'ID_PACIENTE=' || v_pac_ids(i) || ';ID_AGENDA=' || v_ag || ';ESTADO=PROGRAMADA;MEDICO=' ||
            m_nom(v_m) || ' ' || m_ape(v_m) || ';FECHA=' || TO_CHAR(v_ini, 'YYYY-MM-DD HH24:MI'), v_reg);

      IF v_flag(c) = 1 THEN
        -- ===== cita cancelada =====
        v_n_canc := v_n_canc + 1;
        v_can := v_reg + (v_ini - v_reg) * DBMS_RANDOM.VALUE(0.3, 0.9);
        p_log(v_usr_pac(i), 'UPDATE', 'CITAS_MEDICAS', v_cita, 'ESTADO=PROGRAMADA',
              'ESTADO=CANCELADA;MOTIVO=' || c_motivos(TRUNC(DBMS_RANDOM.VALUE(1, c_motivos.COUNT + 1))), v_can);
        -- el horario vuelve a quedar disponible mediante un slot nuevo (otro ID_AGENDA)
        INSERT INTO AGENDAS_MEDICOS (ID_AGENDA, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN,
                                     DIA_SEMANA, ID_ESTADO, CREATED_AT)
        VALUES (SEQ_AGENDAS_MEDICOS.NEXTVAL, v_med_ids(v_m), v_ini, v_fin, v_dsem, v_est_ag_disp, v_can);
      ELSIF v_fut THEN
        -- ===== cita programada (futura): todavia no tiene historia ni receta =====
        v_n_prog := v_n_prog + 1;
      ELSE
        -- ===== cita atendida -> historia clinica =====
        v_n_aten := v_n_aten + 1;
        v_aten := v_ini + TRUNC(DBMS_RANDOM.VALUE(0, 11)) / 1440;
        v_nota := c_notas(TRUNC(DBMS_RANDOM.VALUE(1, c_notas.COUNT + 1)));
        v_dg := (v_m - 1) * 4 + TRUNC(DBMS_RANDOM.VALUE(1, 5));
        INSERT INTO HISTORIA_CLINICA (ID_HISTORIA, ID_CITA, DIAGNOSTICO, NOTAS_MEDICAS, FECHA_ATENCION, CREATED_AT)
        VALUES (SEQ_HISTORIA_CLINICA.NEXTVAL, v_cita,
                c_diag(v_dg),
                v_nota, v_aten, v_aten)
        RETURNING ID_HISTORIA INTO v_hist;
        v_n_hist := v_n_hist + 1;

        p_log(v_usr_med(v_m), 'UPDATE', 'CITAS_MEDICAS', v_cita, 'ESTADO=PROGRAMADA', 'ESTADO=ATENDIDA', v_aten);
        p_log(v_usr_med(v_m), 'INSERT', 'HISTORIA_CLINICA', v_hist, NULL,
              'ID_CITA=' || v_cita || ';DIAGNOSTICO=' || c_diag(v_dg), v_aten);

        -- ~70% de las historias cuyo diagnostico lo requiere generan receta (1 a 3 medicamentos del diagnostico)
        IF c_diag_meds(v_dg).COUNT > 0 AND DBMS_RANDOM.VALUE < 0.7 THEN
          INSERT INTO RECETAS_MEDICAS (ID_RECETA, ID_HISTORIA, ID_ESTADO, FECHA_EMISION, CREATED_AT)
          VALUES (SEQ_RECETAS_MEDICAS.NEXTVAL, v_hist, v_est_rec_no, v_aten + 15 / 1440, v_aten + 15 / 1440)
          RETURNING ID_RECETA INTO v_rec;
          v_n_rec := v_n_rec + 1;

          -- escenario de entrega: 60% todo entregado, 25% mixto, 15% nada (las de los ultimos 2 dias, nada)
          v_rnd := DBMS_RANDOM.VALUE;
          IF v_aten > v_hoy - 2 THEN v_esc := 3;
          ELSIF v_rnd < 0.60 THEN v_esc := 1;
          ELSIF v_rnd < 0.85 THEN v_esc := 2;
          ELSE v_esc := 3;
          END IF;
          v_nd_ent := 0;
          v_nd_any := 0;

          v_nmed := TRUNC(DBMS_RANDOM.VALUE(1, 4));
          IF v_nmed > c_diag_meds(v_dg).COUNT THEN v_nmed := c_diag_meds(v_dg).COUNT; END IF;
          v_pick.DELETE;
          v_k := 0;
          WHILE v_k < v_nmed LOOP
            v_mm := c_diag_meds(v_dg)(TRUNC(DBMS_RANDOM.VALUE(1, c_diag_meds(v_dg).COUNT + 1)));
            CONTINUE WHEN v_pick.EXISTS(v_mm);
            v_pick(v_mm) := 1;
            v_k := v_k + 1;

            -- unidades que faltan por entregar (si se entrego algo, lo hizo un farmaceutico)
            v_pend := c_med_cant(v_mm);
            IF v_esc = 1 THEN
              v_pend := 0;
            ELSIF v_esc = 2 THEN
              v_rnd := DBMS_RANDOM.VALUE;
              IF v_rnd < 0.4 THEN
                v_pend := 0;
              ELSIF v_rnd < 0.7 AND c_med_cant(v_mm) > 1 THEN
                v_pend := c_med_cant(v_mm) - TRUNC(c_med_cant(v_mm) / 2);   -- entrega parcial (ej. 3 de 6)
              END IF;
            END IF;

            IF v_pend = 0 THEN v_est_d := v_est_det_si; ELSE v_est_d := v_est_det_no; END IF;
            IF v_pend < c_med_cant(v_mm) THEN
              v_fx  := TRUNC(DBMS_RANDOM.VALUE(1, v_far_ids.COUNT + 1));
              v_fid := v_far_ids(v_fx);
              v_nd_any := v_nd_any + 1;
            ELSE
              v_fx  := NULL;
              v_fid := NULL;
            END IF;
            IF v_pend = 0 THEN v_nd_ent := v_nd_ent + 1; END IF;

            INSERT INTO DETALLE_RECETA (ID_DETALLE, ID_RECETA, ID_MEDICAMENTO, ID_FARMACEUTICO, ID_ESTADO,
                                        CANTIDAD, CANTIDAD_PENDIENTE, DOSIS, CREATED_AT)
            VALUES (SEQ_DETALLE_RECETA.NEXTVAL, v_rec, v_med_cat(v_mm),
                    v_fid, v_est_d,
                    c_med_cant(v_mm), v_pend, c_med_dosis(v_mm), v_aten + 15 / 1440)
            RETURNING ID_DETALLE INTO v_det;

            IF v_fx IS NOT NULL THEN
              v_dt_ent := LEAST(v_aten + 1 / 24 + DBMS_RANDOM.VALUE(0, 2), SYSDATE);
              p_log(v_usr_far(v_fx), 'UPDATE', 'DETALLE_RECETA', v_det,
                    'ESTADO=NO ENTREGADO;CANTIDAD_PENDIENTE=' || c_med_cant(v_mm),
                    'ESTADO=' || CASE WHEN v_pend = 0 THEN 'ENTREGADO' ELSE 'NO ENTREGADO' END ||
                    ';CANTIDAD_PENDIENTE=' || v_pend, v_dt_ent);
            END IF;
          END LOOP;

          p_log(v_usr_med(v_m), 'INSERT', 'RECETAS_MEDICAS', v_rec, NULL,
                'ID_HISTORIA=' || v_hist || ';MEDICAMENTOS=' || v_nmed || ';ESTADO=NO ENTREGADA',
                v_aten + 15 / 1440);

          -- estado de la receta segun sus detalles (lo que luego hara el trigger)
          IF v_nd_ent = v_nmed THEN
            UPDATE RECETAS_MEDICAS SET ID_ESTADO = v_est_rec_ent WHERE ID_RECETA = v_rec;
            v_n_rec_ent := v_n_rec_ent + 1;
          ELSIF v_nd_any = 0 THEN
            v_n_rec_no := v_n_rec_no + 1;
          ELSE
            UPDATE RECETAS_MEDICAS SET ID_ESTADO = v_est_rec_par WHERE ID_RECETA = v_rec;
            v_n_rec_par := v_n_rec_par + 1;
          END IF;
        END IF;
      END IF;
    END LOOP;
  END LOOP;

  -- 9. Agenda futura disponible (10 slots libres por medico en los proximos 14 dias)
  FOR m IN 1..c_medicos LOOP
    v_k := 0;
    WHILE v_k < 10 LOOP
      v_dia := v_hoy + TRUNC(DBMS_RANDOM.VALUE(1, 15));
      v_idx := v_dia - TRUNC(v_dia, 'IW');
      CONTINUE WHEN INSTR(c_dias_med(m), TO_CHAR(v_idx)) = 0;
      v_ini   := v_dia + (8 + TRUNC(DBMS_RANDOM.VALUE(0, 18)) * 0.5) / 24;
      v_key_m := m || '-' || TO_CHAR(v_ini, 'YYYYMMDDHH24MI');
      CONTINUE WHEN v_ocup_m.EXISTS(v_key_m);
      v_dsem := f_dia(v_ini);
      v_ocup_m(v_key_m) := 1;
      INSERT INTO AGENDAS_MEDICOS (ID_AGENDA, ID_MEDICO, FECHA_HORA_INICIO, FECHA_HORA_FIN,
                                   DIA_SEMANA, ID_ESTADO, CREATED_AT)
      VALUES (SEQ_AGENDAS_MEDICOS.NEXTVAL, v_med_ids(m), v_ini, v_ini + 30 / 1440, v_dsem, v_est_ag_disp,
              v_hoy - TRUNC(DBMS_RANDOM.VALUE(1, 6)) + 8 / 24);
      v_k := v_k + 1;
    END LOOP;
  END LOOP;

  COMMIT;

  DBMS_OUTPUT.PUT_LINE('Pacientes ............ ' || c_pacientes);
  DBMS_OUTPUT.PUT_LINE('Medicos .............. ' || c_medicos);
  DBMS_OUTPUT.PUT_LINE('Farmaceuticos ........ ' || f_nom.COUNT);
  DBMS_OUTPUT.PUT_LINE('Citas totales ........ ' || v_total);
  DBMS_OUTPUT.PUT_LINE('  Atendidas .......... ' || v_n_aten);
  DBMS_OUTPUT.PUT_LINE('  Canceladas ......... ' || v_n_canc || ' (' || ROUND(100 * v_n_canc / v_total, 1) || '%)');
  DBMS_OUTPUT.PUT_LINE('  Programadas ........ ' || v_n_prog);
  DBMS_OUTPUT.PUT_LINE('Historias clinicas ... ' || v_n_hist);
  DBMS_OUTPUT.PUT_LINE('Recetas .............. ' || v_n_rec);
  DBMS_OUTPUT.PUT_LINE('  Entregadas ......... ' || v_n_rec_ent);
  DBMS_OUTPUT.PUT_LINE('  Parcialmente ....... ' || v_n_rec_par);
  DBMS_OUTPUT.PUT_LINE('  No entregadas ...... ' || v_n_rec_no);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
    RAISE;
END;
/

-- =====================================================================
-- CONSULTAS DE VERIFICACION
-- =====================================================================

-- Formato de salida (para que las columnas no se partan en varias lineas)
SET LINESIZE 220
SET PAGESIZE 100
COLUMN ESTADO FORMAT A15
COLUMN MEDICO FORMAT A25
COLUMN ESPECIALIDAD FORMAT A28
COLUMN ROL FORMAT A16
COLUMN USERNAME FORMAT A18
COLUMN FARMACEUTICO FORMAT A20
COLUMN TABLA_AFECTADA FORMAT A18
COLUMN ACCION FORMAT A8
COLUMN VALOR_ANTES FORMAT A28
COLUMN VALOR_DESPUES FORMAT A60

-- Totales por tabla
SELECT 'USUARIOS' tabla, COUNT(*) filas FROM USUARIOS UNION ALL
SELECT 'PACIENTES', COUNT(*) FROM PACIENTES UNION ALL
SELECT 'MEDICOS', COUNT(*) FROM MEDICOS UNION ALL
SELECT 'FARMACEUTICOS', COUNT(*) FROM FARMACEUTICOS UNION ALL
SELECT 'AGENDAS_MEDICOS', COUNT(*) FROM AGENDAS_MEDICOS UNION ALL
SELECT 'CITAS_MEDICAS', COUNT(*) FROM CITAS_MEDICAS UNION ALL
SELECT 'HISTORIA_CLINICA', COUNT(*) FROM HISTORIA_CLINICA UNION ALL
SELECT 'RECETAS_MEDICAS', COUNT(*) FROM RECETAS_MEDICAS UNION ALL
SELECT 'DETALLE_RECETA', COUNT(*) FROM DETALLE_RECETA UNION ALL
SELECT 'MEDICAMENTOS', COUNT(*) FROM MEDICAMENTOS UNION ALL
SELECT 'STOCK_FARMACIA', COUNT(*) FROM STOCK_FARMACIA UNION ALL
SELECT 'LOG_AUDITORIAS', COUNT(*) FROM LOG_AUDITORIAS;

-- Pacientes que nunca han tenido cita (esperado: 5)
SELECT COUNT(*) AS pacientes_sin_citas
FROM PACIENTES p
WHERE NOT EXISTS (SELECT 1 FROM CITAS_MEDICAS c WHERE c.ID_PACIENTE = p.ID_PACIENTE);

-- Minimo y maximo de citas por paciente (esperado: 3 y 7)
SELECT MIN(n) AS minimo, MAX(n) AS maximo
FROM (SELECT COUNT(*) n FROM CITAS_MEDICAS GROUP BY ID_PACIENTE);

-- Porcentaje por estado (esperado: CANCELADA = 20%)
SELECT pt.VALOR AS estado, COUNT(*) AS citas,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS porcentaje
FROM CITAS_MEDICAS c
JOIN PARAMETRICA_TIPOS pt ON pt.ID_PARAMETRO = c.ID_ESTADO
GROUP BY pt.VALOR;

-- Rango de fechas de las citas
SELECT MIN(a.FECHA_HORA_INICIO) AS primera_cita, MAX(a.FECHA_HORA_INICIO) AS ultima_cita
FROM CITAS_MEDICAS c JOIN AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA;

-- Citas por medico y especialidad
SELECT m.NOMBRE || ' ' || m.APELLIDO AS medico, pt.VALOR AS especialidad, COUNT(c.ID_CITA) AS citas
FROM MEDICOS m
JOIN PARAMETRICA_TIPOS pt ON pt.ID_PARAMETRO = m.ID_ESPECIALIDAD
LEFT JOIN AGENDAS_MEDICOS a ON a.ID_MEDICO = m.ID_MEDICO
LEFT JOIN CITAS_MEDICAS c ON c.ID_AGENDA = a.ID_AGENDA
GROUP BY m.NOMBRE, m.APELLIDO, pt.VALOR
ORDER BY citas DESC;

-- Usuarios por rol (esperado: PACIENTE = 100, MEDICO = 10, FARMACEUTICO = 3, RECEPCIONISTA = 2, SUPERADMIN = 1, GERENTE = 1)
SELECT r.NOMBRE AS rol, COUNT(*) AS usuarios
FROM USUARIOS u JOIN ROLES r ON r.ID_ROL = u.ID_ROL
GROUP BY r.NOMBRE ORDER BY usuarios DESC;

-- Dias distintos de atencion por medico (esperado: entre 3 y 5)
SELECT m.NOMBRE || ' ' || m.APELLIDO AS medico, COUNT(DISTINCT a.DIA_SEMANA) AS dias_distintos
FROM MEDICOS m JOIN AGENDAS_MEDICOS a ON a.ID_MEDICO = m.ID_MEDICO
GROUP BY m.NOMBRE, m.APELLIDO ORDER BY medico;

-- Citas programadas por medico y fecha (para probar la cancelacion masiva de HU09)
SELECT m.NOMBRE || ' ' || m.APELLIDO AS medico, TRUNC(a.FECHA_HORA_INICIO) AS fecha, COUNT(*) AS programadas
FROM CITAS_MEDICAS c
JOIN PARAMETRICA_TIPOS pt ON pt.ID_PARAMETRO = c.ID_ESTADO AND pt.VALOR = 'PROGRAMADA'
JOIN AGENDAS_MEDICOS a ON a.ID_AGENDA = c.ID_AGENDA
JOIN MEDICOS m ON m.ID_MEDICO = a.ID_MEDICO
GROUP BY m.NOMBRE, m.APELLIDO, TRUNC(a.FECHA_HORA_INICIO)
ORDER BY fecha, medico;

-- Usuarios sin entidad (esperado: 4 -> superadmin1, gerente1, recepcionista1, recepcionista2)
SELECT u.USERNAME, r.NOMBRE AS rol FROM USUARIOS u JOIN ROLES r ON r.ID_ROL = u.ID_ROL
WHERE u.ID_ENTIDAD IS NULL ORDER BY u.USERNAME;

-- Estado de las recetas
SELECT pt.VALOR AS estado, COUNT(*) AS recetas
FROM RECETAS_MEDICAS r JOIN PARAMETRICA_TIPOS pt ON pt.ID_PARAMETRO = r.ID_ESTADO
GROUP BY pt.VALOR;

-- Recetas cuyo estado NO coincide con sus detalles (esperado: 0 filas)
SELECT r.ID_RECETA, pt.VALOR AS estado
FROM RECETAS_MEDICAS r
JOIN PARAMETRICA_TIPOS pt ON pt.ID_PARAMETRO = r.ID_ESTADO
JOIN DETALLE_RECETA d ON d.ID_RECETA = r.ID_RECETA
GROUP BY r.ID_RECETA, pt.VALOR
HAVING NOT (
     (pt.VALOR = 'ENTREGADA'    AND COUNT(*) = SUM(CASE WHEN d.CANTIDAD_PENDIENTE = 0 THEN 1 ELSE 0 END))
  OR (pt.VALOR = 'NO ENTREGADA' AND SUM(CASE WHEN d.CANTIDAD_PENDIENTE < d.CANTIDAD THEN 1 ELSE 0 END) = 0)
  OR (pt.VALOR = 'PARCIALMENTE' AND SUM(CASE WHEN d.CANTIDAD_PENDIENTE < d.CANTIDAD THEN 1 ELSE 0 END) > 0
                                AND COUNT(*) > SUM(CASE WHEN d.CANTIDAD_PENDIENTE = 0 THEN 1 ELSE 0 END)));

-- Detalles con farmaceutico inconsistente: con entrega y sin farmaceutico, o sin entrega y con farmaceutico (esperado: 0)
SELECT COUNT(*) AS inconsistentes
FROM DETALLE_RECETA d
WHERE (d.CANTIDAD_PENDIENTE < d.CANTIDAD AND d.ID_FARMACEUTICO IS NULL)
   OR (d.CANTIDAD_PENDIENTE = d.CANTIDAD AND d.ID_FARMACEUTICO IS NOT NULL);

-- Medicamentos entregados por farmaceutico
SELECT f.NOMBRE || ' ' || f.APELLIDO AS farmaceutico, COUNT(*) AS detalles_atendidos
FROM DETALLE_RECETA d JOIN FARMACEUTICOS f ON f.ID_FARMACEUTICO = d.ID_FARMACEUTICO
GROUP BY f.NOMBRE, f.APELLIDO;

-- Ultimos movimientos de la bitacora
SELECT l.ID_LOG, u.USERNAME, l.ACCION, l.TABLA_AFECTADA, l.ID_REGISTRO,
       SUBSTR(l.VALOR_ANTES, 1, 28) AS VALOR_ANTES, SUBSTR(l.VALOR_DESPUES, 1, 60) AS VALOR_DESPUES,
       TO_CHAR(l.FECHA_HORA, 'YYYY-MM-DD HH24:MI') AS FECHA_HORA
FROM LOG_AUDITORIAS l JOIN USUARIOS u ON u.ID_USUARIO = l.ID_USUARIO
ORDER BY l.FECHA_HORA DESC FETCH FIRST 15 ROWS ONLY;

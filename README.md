# Citas médicas - Base de datos

Scripts Oracle del sistema de citas médicas (esquema `PROYECTOPLSQL`). Todos los objetos usan prefijos: tablas `TBL_`, triggers `TRG_`, secuencias `SEQ_TBL_`, índices `IDX_`, paquetes `PKG_`, procedimientos `PRO_`, funciones `FN_`. En el código PL/SQL, las variables llevan el tipo: `vn_` número, `vs_` texto, `vd_` fecha, `vt_` timestamp, `vr_` registro, `vb_` booleano, `vc_` colección; parámetros `pn_ ps_ pd_ pt_`; excepciones `ex_`.

## Orden de ejecución
Corre los scripts en este orden. Los números de las carpetas lo indican.

| Paso | Archivo | Quién / con qué usuario | Qué hace |
|------|---------|--------------------------|----------|
| 1 | `01_esquema/crear_esquema.sql` | Administrador (SYSTEM) | Crea los tablespaces, el usuario `PROYECTOPLSQL` y sus permisos. Una sola vez por computador. |
| 1b | `01_esquema/seguridad_dba.sql` | Administrador (SYSTEM) | HU07: crea `ROLE_MEDICO`, `ROLE_RECEPCION` y el contexto `CTX_CITAS`. Una sola vez. El `GRANT EXECUTE ON SYS.DBMS_RLS` necesita `SYS`; si no puedes, usa `GRANT EXECUTE_CATALOG_ROLE TO PROYECTOPLSQL` desde `SYSTEM` y reconecta. |
| 2 | `02_tablas/creacion_tablas.sql` | `PROYECTOPLSQL` | Borra y crea las 14 tablas, índices y secuencias. Se puede repetir para empezar de cero. |
| 3 | `03_datos/datos_companieros.sql` | `PROYECTOPLSQL` | Carga los datos de prueba compartidos (todo el grupo queda con los mismos). Luego `03_datos/estado_no_asistio.sql` si el estado NO_ASISTIO no está. |
| 4 | `04_secuencias/despues_de_importar.sql` | `PROYECTOPLSQL` | Deja las secuencias en MAX(id)+1 para que el próximo `NEXTVAL` no choque con los datos. |
| 5 | `05_triggers/` | `PROYECTOPLSQL` | Triggers: `TRG_HISTORIA_CITA_PROGRAMADA` (HU04), `TRG_DETALLE_ESTADO_RECETA`, `TRG_STOCK_MINIMO` (HU06) y `TRG_HISTORIA_AUDITORIA` (HU08). **Siempre después de cargar los datos.** |
| 6 | `06_procedimientos/` | `PROYECTOPLSQL` | Paquetes: `PKG_AGENDAS`, `PKG_GESTION_CITAS`, `PKG_HISTORIAS_CLINICAS`, `PKG_GESTION_MEDICAMENTOS`, `PKG_PERFILES`, `PKG_USUARIOS`, `PKG_SEGURIDAD` y `PKG_REPORTES`. |
| 7 | `07_datos_iniciales/horarios_medicos.sql` | `PROYECTOPLSQL` | Deja a los 10 médicos con horario semanal (sin esto nadie tiene agendas futuras). Después de compilar los paquetes. |
| 8 | `08_seguridad/rls_historias.sql` | `PROYECTOPLSQL` | HU07: permisos por rol y política `POL_HISTORIA_CLINICA` (`DBMS_RLS`). Después de compilar `PKG_SEGURIDAD`. |

Comprobar que la política quedó creada: `SELECT OBJECT_NAME, POLICY_NAME, ENABLE FROM USER_POLICIES;`

Al terminar los pasos 2 a 4 deberías tener: 100 pacientes, 10 médicos, 3 farmacéuticos, 450 citas
(20% canceladas), 148 recetas y 117 usuarios.

## Si ya tenías la BD cargada
No hace falta empezar de cero. Corre solo lo nuevo, en este orden: 1b (SYSTEM), los triggers nuevos del paso 5, los paquetes del paso 6 (recompilar todos) y el paso 8. Si cambió `creacion_tablas.sql`, vuelve a correr los pasos 2 a 4.

## Modelo cita-agenda (1 a N)
Una agenda (`TBL_AGENDAS_MEDICOS`) es un rango de horas del médico (ej. martes de 7:00 a 12:00) y puede tener varias
citas; cada cita guarda su propia `FECHA_HORA_INICIO` y `FECHA_HORA_FIN`. **Cada cita dura exactamente 1 hora**, y las
agendas y bloques del horario semanal son de horas completas. HU09 debe leer la hora de la cita en `TBL_CITAS_MEDICAS`.

## Horario semanal del médico (sin tabla nueva)
- Se usa `TBL_AGENDAS_MEDICOS`: cada agenda tiene su `DIA_SEMANA` y su rango de horas. Un horario "que se repite" son agendas del mismo día y las mismas horas en varias fechas.
- `PKG_AGENDAS.PRO_GUARDAR_HORARIO_SEMANAL(medico, 'MARTES~16:00~19:00|JUEVES~16:00~19:00', ...)` borra las agendas futuras sin citas y crea una por cada fecha de las próximas 52 semanas. Las que tienen citas no se tocan.
- `PKG_AGENDAS.PRO_GENERAR_AGENDAS_SEMANALES` (job del back, cada hora) extiende los patrones para que siempre queden 52 semanas por delante.

## Seguridad y auditoría
- **HU06:** `TRG_STOCK_MINIMO` inserta `ALERTA_STOCK_MINIMO` en `TBL_LOG_AUDITORIAS` (usuario 0 = Sistema) cuando una actualización baja el stock por debajo de `CANTIDAD_MINIMA`. Reponer no genera alerta.
- **HU07:** el back llama a `PKG_SEGURIDAD.PRO_ESTABLECER_CONTEXTO(rol, id_entidad, id_usuario)` en cada conexión. La política filtra `TBL_HISTORIA_CLINICA` en los SELECT: MEDICO solo las citas de sus agendas, PACIENTE las suyas, RECEPCIONISTA ninguna; el resto (SUPERADMIN, GERENTE, FARMACEUTICO) todas. Sin contexto (scripts, jobs) no filtra.
- **HU08:** `TRG_HISTORIA_AUDITORIA` registra `MODIFICAR_HISTORIA` (cambios en diagnóstico o notas) y `ELIMINAR_HISTORIA`, con valor anterior, valor nuevo, el usuario de la aplicación (`ID_USUARIO`) y el usuario Oracle.
- Los permisos de los roles `ROLE_MEDICO` y `ROLE_RECEPCION` quedan creados, pero la aplicación se conecta con un solo usuario; lo que protege de verdad es la política RLS.

## HU09: cancelación masiva por inasistencia médica
`PKG_GESTION_CITAS.PRO_CANCELAR_CITAS_MEDICO(medico, fecha, motivo, usuario, canceladas OUT)` cancela con `BULK COLLECT` + `FORALL` todas las citas PROGRAMADAS de un médico en una fecha (hoy o futura). Deja una fila `CANCELAR_CITA` por cita (el paciente ve el motivo en su pantalla) y una fila resumen `CANCELACION_MASIVA`. Las agendas de ese día quedan OCUPADA para que nadie reserve; para reabrirlas hay que volver a guardar el horario del médico. Solo SUPERADMIN.

## HU10: reporte de atención y prescripción
`PKG_REPORTES.PRO_REPORTE_PERIODO(desde, hasta, ...)` consolida un periodo (máximo 366 días) con cursores explícitos: citas programadas, atendidas, canceladas y no asistió (por fecha de inicio), recetas emitidas (por fecha de emisión) y su estado (entregadas, parciales, sin entregar). Además devuelve un `SYS_REFCURSOR` con el detalle por médico. Solo lee, no modifica datos. Lo ven GERENTE y SUPERADMIN. Prueba: `tests/hu10_prueba.sql`.

## Datos de prueba
- Todos los usuarios tienen la clave `Clave123` (guardada como hash SHA-256).
- Usuarios sin entidad: `superadmin1`, `gerente1`, `recepcionista1`, `recepcionista2`.
- Médicos: `dr.apellido` (por ejemplo `dr.torres`). Farmacéuticos: `monica.duque`, `hector.becerra`, `paola.naranjo`.
- Pacientes: nombre + número (por ejemplo `pablo23`).

## Contraseña temporal y pacientes por recepción
- `TBL_USUARIOS.DEBE_CAMBIAR_CLAVE`: `PRO_CREAR_PERSONAL` y `PRO_RESTABLECER_CLAVE` dejan la clave como temporal; `PRO_CAMBIAR_CLAVE` la quita.
- `PRO_REGISTRAR_PACIENTE_RECEPCION` crea solo la ficha del paciente (sin usuario).

## Pruebas
Los scripts de `tests/` (`hu03b_prueba.sql` a `hu08_prueba.sql`, `usuarios_prueba.sql`, `modelo_1_a_n_prueba.sql`) se corren como `PROYECTOPLSQL`; los de HU06, HU07 y HU08 terminan en `ROLLBACK` o `COMMIT` explícito y no dejan datos sucios.

## Utilidades
- `utilidades/generador_datos.sql`: el script que **generó** los datos. Borra todo y vuelve a generar con la fecha del día, así que NO produce los mismos datos que `datos_companieros.sql`. Úsenlo solo si necesitan datos nuevos, y si lo hacen, exporten de nuevo `datos_companieros.sql`.
- `utilidades/limpiar_esquema_anterior.sql`: borra las tablas viejas sin prefijo `TBL_`.

## Reglas del equipo
- Si cambias una tabla, edita `02_tablas/creacion_tablas.sql` (es la única fuente de verdad), avisa al grupo y vuelve a exportar los datos si hace falta.
- Cada trigger o procedimiento va en su propio archivo con nombre claro, por ejemplo `05_triggers/trg_stock_minimo.sql`.
- Respetar los prefijos de nombres de la primera sección en todo código nuevo.
- `main` solo se modifica con Pull Request revisado por otra persona.
- No subir contraseñas reales de ningún entorno.

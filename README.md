# Citas médicas - Base de datos

Scripts Oracle del sistema de citas médicas (esquema `PROYECTOPLSQL`).

## Orden de ejecución
Corre los scripts en este orden. Los números de las carpetas lo indican.

| Paso | Archivo | Quién / con qué usuario | Qué hace |
|------|---------|--------------------------|----------|
| 1 | `01_esquema/crear_esquema.sql` | Administrador (SYSTEM) | Crea los tablespaces, el usuario `PROYECTOPLSQL` y sus permisos. Una sola vez por computador. |
| 2 | `02_tablas/creacion_tablas.sql` | `PROYECTOPLSQL` | Borra y crea las 14 tablas (`TBL_*`), índices y secuencias (`SEQ_TBL_*`). Se puede repetir para empezar de cero. |
| 3 | `03_datos/datos_companieros.sql` | `PROYECTOPLSQL` | Carga los datos de prueba compartidos (todo el grupo queda con los mismos). |
| 4 | `04_secuencias/despues_de_importar.sql` | `PROYECTOPLSQL` | Deja las secuencias `SEQ_TBL_*` en MAX(id)+1 para que el próximo `NEXTVAL` no choque con los datos. |
| 5 | `05_triggers/` | `PROYECTOPLSQL` | Triggers (`TRG_*`). **Siempre después de cargar los datos.** |
| 6 | `06_procedimientos/` | `PROYECTOPLSQL` | Procedimientos y paquetes (`PKG_*`). |

Al terminar los pasos 2 a 4 deberías tener: 100 pacientes, 10 médicos, 3 farmacéuticos, 450 citas
(20% canceladas), 148 recetas y 117 usuarios. Las consultas de verificación están al final de
`utilidades/generador_datos.sql`.

## Modelo cita-agenda (1 a N)
Una agenda (`TBL_AGENDAS_MEDICOS`) es un rango de horas del médico (ej. martes de 7:00 a 12:00) y puede tener varias
citas; cada cita guarda su propia `FECHA_HORA_INICIO` y `FECHA_HORA_FIN` en `TBL_CITAS_MEDICAS`. Si ya tenías la BD cargada con el modelo
anterior (1 a 1), corre `02_tablas/migracion_cita_agenda_1_a_n.sql` una vez, sin borrar datos. Después ejecuta
`03_datos/estado_no_asistio.sql` (agrega el estado NO_ASISTIO en `TBL_PARAMETRICA_TIPOS`) y vuelve a compilar los paquetes de `06_procedimientos`.

## Datos de prueba
- Todos los usuarios tienen la clave `Clave123` (guardada como hash SHA-256).
- Usuarios sin entidad: `superadmin1`, `gerente1`, `recepcionista1`, `recepcionista2`.
- Médicos: `dr.apellido` (por ejemplo `dr.torres`). Farmacéuticos: `monica.duque`, `hector.becerra`, `paola.naranjo`.
- Pacientes: nombre + número (por ejemplo `pablo23`).

## Utilidades
- `utilidades/generador_datos.sql`: el script que **generó** los datos. Borra todo y vuelve a generar con la
  fecha del día en que se corre, así que NO produce los mismos datos que `datos_companieros.sql`.
  Úsenlo solo si necesitan datos nuevos, y si lo hacen, exporten de nuevo `datos_companieros.sql`.

## Reglas del equipo
- Si cambias una tabla, edita `02_tablas/creacion_tablas.sql` (es la única fuente de verdad), avisa al grupo y
  vuelve a exportar los datos si hace falta.
- Cada trigger o procedimiento va en su propio archivo con nombre claro, por ejemplo
  `05_triggers/trg_historia_clinica_hu04.sql`.
- `main` solo se modifica con Pull Request revisado por otra persona.
- No subir contraseñas reales de ningún entorno.

## Horario semanal del médico (sin tabla nueva)
- Se usa `TBL_AGENDAS_MEDICOS`: cada agenda tiene su `DIA_SEMANA` y su rango de horas. Un horario "que se repite" son agendas del mismo día y las mismas horas en varias fechas.
- `PKG_AGENDAS.GUARDAR_HORARIO_SEMANAL(medico, 'MARTES~16:00~19:00|JUEVES~16:00~19:00', ...)` borra las agendas futuras sin citas y crea una por cada fecha de las próximas 52 semanas (el horario se repite cada semana, sin fecha de fin). Las que tienen citas no se tocan.
- `PKG_AGENDAS.GENERAR_AGENDAS_SEMANALES` (job del back, cada hora) extiende hacia adelante los patrones (mismo día y horas en 2 o más fechas futuras) para que siempre queden 52 semanas por delante. El paciente ve una semana a la vez (por defecto la actual) y puede avanzar o ir a una fecha.
- No hay migración: no cambia ninguna tabla. Solo recompilar `pkg_agendas.sql`.

## Contraseña temporal y pacientes por recepción
- `02_tablas/migracion_clave_temporal.sql` agrega `TBL_USUARIOS.DEBE_CAMBIAR_CLAVE`. `CREAR_PERSONAL` y `RESTABLECER_CLAVE` dejan la clave como temporal; `CAMBIAR_CLAVE` la quita.
- `REGISTRAR_PACIENTE_RECEPCION` crea solo la ficha del paciente en `TBL_PACIENTES` (sin registro en `TBL_USUARIOS`).

## Horarios iniciales
Después de compilar los paquetes: `07_datos_iniciales/horarios_medicos.sql` deja a los 10 médicos con horario semanal (sin esto ningún médico tiene agendas futuras).

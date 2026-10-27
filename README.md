# Citas médicas - Base de datos

Scripts Oracle del sistema de citas médicas (esquema `PROYECTOPLSQL`).

## Orden de ejecución
Corre los scripts en este orden. Los números de las carpetas lo indican.

| Paso | Archivo | Quién / con qué usuario | Qué hace |
|------|---------|--------------------------|----------|
| 1 | `01_esquema/crear_esquema.sql` | Administrador (SYSTEM) | Crea los tablespaces, el usuario `PROYECTOPLSQL` y sus permisos. Una sola vez por computador. |
| 2 | `02_tablas/creacion_tablas.sql` | `PROYECTOPLSQL` | Borra y crea las 14 tablas, índices y secuencias. Se puede repetir para empezar de cero. |
| 3 | `03_datos/datos_companieros.sql` | `PROYECTOPLSQL` | Carga los datos de prueba compartidos (todo el grupo queda con los mismos). |
| 4 | `04_secuencias/despues_de_importar.sql` | `PROYECTOPLSQL` | Deja las secuencias en MAX(id)+1 para que el próximo `NEXTVAL` no choque con los datos. |
| 5 | `05_triggers/` | `PROYECTOPLSQL` | Triggers (HU04, entrega de recetas, etc.). **Siempre después de cargar los datos.** |
| 6 | `06_procedimientos/` | `PROYECTOPLSQL` | Procedimientos y paquetes (reservas, cancelación masiva, etc.). |

Al terminar los pasos 2 a 4 deberías tener: 100 pacientes, 10 médicos, 3 farmacéuticos, 450 citas
(20% canceladas), 148 recetas y 117 usuarios. Las consultas de verificación están al final de
`utilidades/generador_datos.sql`.

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

# 5. Base de datos Oracle ATP compartida (schema por servicio)

Date: 2026-05-29

## Status

Accepted

## Context

Un sistema de microservicios "puro" suele recomendar una base de datos por servicio para máximo desacoplamiento. Sin embargo, el proyecto cuenta con una única **Oracle Autonomous Database (ATP)** ya provisionada (`gestiondetareasbd_tp`), a la que los servicios se conectan vía wallet montado en `/app/Wallet`. Provisionar y operar una base por servicio tendría un costo y una complejidad que el alcance académico del proyecto no justifica.

## Decision

Los microservicios comparten la **misma instancia Oracle ATP**, pero cada uno es dueño de sus propias tablas/esquema lógico (usuarios y roles para `auth-service`; tareas, proyectos y sprints para `task-service`; snapshots de KPI para `kpi-service`; historial de chat para `ai-service`). `telegram-service` no persiste estado propio. La regla de oro es que **ningún servicio lee ni escribe tablas que no le pertenecen**: si necesita datos de otro, los pide por su API REST (p. ej. `ai-service -> task-service` para el contexto).

## Consequences

**Positivas:**
- Aprovecha la infraestructura existente: una sola base que administrar, respaldar y conectar.
- Conserva el principio clave de propiedad de datos por servicio aunque la instancia física sea compartida.
- Menor costo y complejidad operativa que una base por servicio.

**Negativas / trade-offs:**
- La instancia compartida es un punto único de fallo y un posible cuello de botella de escalado.
- El aislamiento depende de disciplina del equipo, no de una frontera física; un acceso indebido entre esquemas no está impedido por la infraestructura.
- Migrar en el futuro a base-por-servicio exige separar esquemas y conexiones; conviene mantener los límites limpios desde ahora para facilitarlo.

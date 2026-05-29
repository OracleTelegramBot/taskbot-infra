# 1. Estilos de arquitectura seleccionados

Date: 2026-05-29

## Status

Accepted

## Context

TaskBot debe soportar varios flujos concurrentes (un developer actualiza tareas mientras el sistema calcula KPIs y envía notificaciones), evolucionar por partes sin re-desplegar todo, escalar de forma desigual (el chatbot y las tareas reciben más carga que la autenticación) y reaccionar a eventos del dominio (tarea bloqueada, sprint por vencer, tarea completada). En Sprint 1 identificamos 8 componentes agrupados en 5 bounded contexts mediante Event Storming.

De los nueve estilos de arquitectura estudiados —Layered, Pipeline, Microkernel, Service-based, Event-driven, Space-based, Orchestration-driven SOA, Microservices y la dicotomía monolítico/distribuido que los enmarca— ningún estilo único cubre bien todos los drivers. Es necesario elegir un estilo primario y combinarlo con estilos de apoyo aplicados en lugares concretos.

## Decision

Adoptamos una combinación de tres estilos, cada uno aplicado donde aporta más valor:

1. **Microservices (estilo primario, nivel sistema).** El sistema se descompone en 5 servicios desplegables de forma independiente (`auth-service`, `task-service`, `kpi-service`, `ai-service`, `telegram-service`), cada uno dueño de su bounded context y con su propio ciclo de build/deploy en GitHub Actions y escalado independiente (2 réplicas por servicio en OKE). El borde se resuelve con un API Gateway (NGINX Ingress) que enruta por path.

2. **Event-driven (estilo secundario, comunicación reactiva).** Los flujos críticos del dominio se modelan como reacciones a eventos: `tarea completada -> task-service dispara cálculo de KPI en kpi-service`, `estado = Blocked -> task-service notifica a telegram-service`, `sprint próximo a vencer -> alerta a telegram-service`, y en operación `fallo post-deploy -> OCI Function crea ticket en Jira`. Esto desacopla a los productores de los consumidores de cada evento.

3. **Layered (estilo de apoyo, nivel intra-servicio).** Dentro de cada microservicio se aplica una arquitectura por capas: Controller (API REST) -> Service (lógica de negocio) -> Repository (acceso a datos) -> base de datos. A nivel macro, el sistema también se organiza en capas técnicas: Presentación (SPA) -> Gateway (Ingress) -> Negocio (servicios) -> Datos (Oracle ATP).

Los demás estilos se descartaron: Pipeline y Microkernel no encajan con un dominio de flujos paralelos; Service-based sería una versión más gruesa de lo que ya logramos con microservicios; Space-based resuelve una escala/elasticidad extrema que no necesitamos; y Orchestration-driven SOA introduce un orquestador central que añade acoplamiento innecesario para 5 servicios.

## Consequences

**Positivas:**
- Despliegue, escalado y evolución independientes por servicio.
- Las capas hacen cada servicio fácil de entender y testear.
- La comunicación por eventos mantiene a los servicios desacoplados y permite añadir consumidores nuevos sin tocar a los productores.
- Cada estilo es localizable en el modelo C4: microservicios en la vista de Containers, capas en la de Components, eventos en las vistas Dynamic.

**Negativas / trade-offs:**
- Mayor complejidad operativa: red, observabilidad distribuida y consistencia eventual entre servicios.
- La comunicación entre servicios (REST/Feign hoy) introduce latencia y modos de fallo que no existen en un monolito.
- Requiere disciplina para que las capas no se salten (p. ej. un Controller llamando directamente a un Repository).


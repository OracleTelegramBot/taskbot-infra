# 2. NGINX Ingress Controller como API Gateway

Date: 2026-05-29

## Status

Accepted

## Context

El sistema necesita un único punto de entrada que enrute las peticiones HTTP a los 5 microservicios y al frontend, termine TLS para `sammy-ulfh.dev` y exponga rutas estables (`/api/v1/auth`, `/api/tasks`, `/api/sprints`, `/api/ai`, `/api/webhook/telegram`, el catch-all `/api`, y las rutas de Swagger). En la exploración inicial de Sprint 1 se asumió Spring Cloud Gateway como puerta de enlace. Al desplegar sobre OKE, todo el tráfico entrante ya pasa por un Ingress de Kubernetes asociado al Production Load Balancer.

## Decision

Usamos **NGINX Ingress Controller** (namespace `ingress-nginx`) como API Gateway, en lugar de Spring Cloud Gateway. El ruteo por path, la terminación TLS (con cert-manager + Let's Encrypt) y el balanceo se definen como reglas de Ingress de Kubernetes. No se despliega un servicio gateway propio de Spring.

## Consequences

**Positivas:**
- Un componente menos que construir, desplegar y operar (no hay un microservicio gateway adicional).
- El ruteo y el TLS son nativos de la plataforma (Kubernetes/OKE), declarativos en YAML y versionados junto a los manifests.
- cert-manager automatiza la emisión y renovación de certificados.

**Negativas / trade-offs:**
- Las capacidades avanzadas que ofrece Spring Cloud Gateway (filtros programáticos, circuit breakers, rate limiting fino por código) ya no están en el borde; si se necesitan, se resuelven con anotaciones de NGINX o se mueven a cada servicio.
- El equipo debe dominar la sintaxis de Ingress y el ciclo de NGINX en vez de configuración Java.
- El mapeo de rutas vive en infraestructura, no en el código de aplicación, lo que separa responsabilidades entre los equipos de app y de plataforma.

# 4. Autenticación stateless con JWT

Date: 2026-05-29

## Status

Accepted

## Context

Con varios microservicios desplegados en réplicas detrás de un balanceador, las peticiones de un mismo usuario pueden caer en instancias distintas. Mantener sesiones en memoria del servidor obligaría a afinidad de sesión o a un almacén de sesiones compartido, lo que añade acoplamiento y un punto de fallo. El sistema maneja tres roles (Admin, PM, Developer) que deben respetarse en cada servicio.

## Decision

Usamos **autenticación stateless basada en JWT**. `auth-service` valida credenciales (con hash BCrypt contra la Autonomous DB) y emite un JWT firmado que incluye el rol. El token viaja en cada petición y cada microservicio lo valida localmente con la clave compartida (`jwt-secret`, inyectada como Kubernetes Secret). No se guarda estado de sesión en el servidor.

## Consequences

**Positivas:**
- Cualquier réplica de cualquier servicio puede atender cualquier petición sin sesión compartida ni afinidad: encaja con el escalado horizontal en OKE.
- La autorización por rol viaja en el token y se verifica en el borde y en cada servicio.
- Menos infraestructura: no hace falta un store de sesiones.

**Negativas / trade-offs:**
- La revocación inmediata de un token es difícil; se mitiga con expiraciones cortas y, si hiciera falta, una lista de revocación.
- La clave de firma (`jwt-secret`) es un secreto crítico: su fuga compromete todo el sistema; debe custodiarse en el Vault/Secret y rotarse.
- El token no debe llevar datos sensibles, ya que su payload es legible por el cliente.

# TaskBot — Documentación de Arquitectura DevOps

**Sprint 3 · Oracle Cloud Infrastructure (OKE) + GitHub Actions**
**Región:** `mx-queretaro-1`

---

## Índice

1. [Arquitectura del sistema](#1-arquitectura-del-sistema)
2. [Infraestructura base en OCI](#2-infraestructura-base-en-oci)
3. [Cluster OKE y configuración Kubernetes](#3-cluster-oke-y-configuración-kubernetes)
4. [Contenerización de la aplicación](#4-contenerización-de-la-aplicación)
5. [Pipeline CI/CD con GitHub Actions](#5-pipeline-cicd-con-github-actions)
6. [Estrategia de despliegue Blue/Green](#6-estrategia-de-despliegue-bluegreen)
7. [Testing automatizado e integración con Jira](#7-testing-automatizado-e-integración-con-jira)
8. [Observabilidad](#8-observabilidad)
9. [Migración de DNS a producción](#9-migración-de-dns-a-producción)
10. [Organización del equipo](#10-organización-del-equipo)
11. [Cronograma](#11-cronograma)
12. [Checklist de implementación](#12-checklist-de-implementación)

---

## 1. Arquitectura del sistema

### Descripción general

TaskBot es una aplicación compuesta por cinco microservicios Java desplegados sobre **Oracle Container Engine for Kubernetes (OKE)**. El proceso de integración y entrega continua está orquestado por **GitHub Actions**, y las imágenes Docker se almacenan en **GitHub Container Registry (GHCR)**. La observabilidad se implementa con servicios nativos de Oracle Cloud Infrastructure (OCI).

### Flujo de despliegue

```
git push → GitHub Repository
  → GitHub Actions (Build)
      → Compilación con Maven
      → Construcción de imágenes Docker
      → Push a GHCR (ghcr.io/<org>/taskbot)
  → GitHub Actions (Deploy)
      → Aprobación manual (GitHub Environment)
      → kubectl apply → OKE (namespace inactivo)
      → Validación automatizada
      → Traffic shift via NGINX Ingress
  → Production Load Balancer → sammy-ulfh.dev
```

### Componentes de infraestructura

| Componente | Tecnología / Valor |
|---|---|
| Región OCI | `mx-queretaro-1` |
| Orquestador de contenedores | OKE (Oracle Container Engine for Kubernetes) |
| Pipeline CI/CD | GitHub Actions |
| Registro de imágenes | GitHub Container Registry (`ghcr.io/<org>/taskbot`) |
| Imagen base Java | `eclipse-temurin:17-jre-alpine` |
| Réplicas por microservicio | 2 |
| Ingress Controller | NGINX |
| Base de datos | Oracle Autonomous Database (ATP) — `gestiondetareasbd_tp` |
| Inteligencia Artificial | OpenAI API — `gpt-4o-mini` |
| Mensajería | Telegram Bot API |
| Observabilidad | OCI Logging, Monitoring, Notifications, Functions |

### Microservicios

| Servicio | Puerto | Empaquetado |
|---|---|---|
| `kpi-service` | 8080 | WAR |
| `telegram-service` | 8081 | JAR |
| `auth-service` | 8082 | JAR |
| `ai-service` | 8083 | JAR |
| `task-service` | 8084 | JAR |

### Repositorios

| Repositorio | Contenido |
|---|---|
| `taskbot-backend` | Monorepo Java con los 5 microservicios |
| `taskbot-frontend` | Aplicación web (Vite) |
| `taskbot-tests` | Suite de pruebas en Python + integración con Jira |
| `taskbot-infra` | Infraestructura como código (Terraform) |

---

## 2. Infraestructura base en OCI

Toda la infraestructura de Oracle Cloud se define y provisiona mediante Terraform, alojado en el repositorio `taskbot-infra`.

### Recursos de red

| Recurso | Nombre |
|---|---|
| Compartment | `taskbot-compartment` |
| VCN | `taskbot-vcn` |
| Subnet pública (Load Balancers) | `taskbot-public-subnet` |
| Subnet privada (nodos OKE) | `taskbot-private-subnet` |
| Production Load Balancer | `taskbot-prod-lb` |
| Test Load Balancer | `taskbot-test-lb` |

La subnet privada tiene salida a internet vía NAT Gateway. La subnet pública expone los Load Balancers mediante Internet Gateway.

### Gestión de secretos

Los secretos se almacenan en el **Vault** `taskbot-vault` y se sincronizan con Kubernetes en la Fase de configuración del cluster.

| Secret | Descripción |
|---|---|
| Credenciales Autonomous DB | Usuario y contraseña de `gestiondetareasbd_tp` |
| Oracle Wallet | Certificados de conexión TLS a la base de datos |
| `JWT_SECRET` | Clave de firma para tokens de autenticación |
| `OPENAI_API_KEY` | Clave de acceso a la API de OpenAI |
| `TELEGRAM_BOT_TOKEN` | Token de autenticación del bot de Telegram |
| Token de Jira | Credencial para creación automática de issues |

### Observabilidad base

Se crean los siguientes recursos para soportar el monitoreo del sistema:

- **Log Groups** en OCI Logging para centralizar los logs de los pods.
- **Notification Topics** (`taskbot-notifications`) para alertas del sistema.
- **OCI Functions Application** `taskbot-functions-app` para la integración con Jira.

### Conectividad con la base de datos

La Autonomous Database `gestiondetareasbd_tp` es un recurso preexistente. Terraform la referencia por su OCID y configura las reglas de seguridad necesarias para que los nodos OKE de la subnet privada puedan conectarse a ella.

---

## 3. Cluster OKE y configuración Kubernetes

### Recursos del cluster

| Recurso | Nombre / Valor |
|---|---|
| Cluster | `taskbot-oke-cluster` |
| Node Pool | `taskbot-oke-nodepool` |
| Nodos mínimos | 2 (alta disponibilidad) |
| Namespace activo | `vs-blue` |
| Namespace de standby | `vs-green` |

### Componentes instalados

| Componente | Namespace | Propósito |
|---|---|---|
| NGINX Ingress Controller | `ingress-nginx` | Enrutamiento HTTP/HTTPS al cluster |
| cert-manager | `cert-manager` | Emisión automática de certificados TLS (Let's Encrypt) |
| metrics-server | `kube-system` | Métricas de CPU/memoria para autoescalado |
| Agente de logging OCI | `kube-system` | Reenvío de logs de pods a OCI Logging |

### Secretos en Kubernetes

Los valores provienen del Vault y se aplican a ambos namespaces.

| Nombre | Tipo | Descripción |
|---|---|---|
| `autonomous-db-credentials` | Secret | Credenciales de la base de datos |
| `oracle-wallet` | Secret (volumen) | Wallet montado en `/app/Wallet` |
| `jwt-secret` | Secret | Clave JWT |
| `openai-credentials` | Secret | API Key de OpenAI |
| `telegram-credentials` | Secret | Token del bot de Telegram |
| `taskbot-config` | ConfigMap | Variables de entorno no sensibles |

### ConfigMap `taskbot-config`

```yaml
TNS_ADMIN: /app/Wallet
ORACLE_WALLET_PATH: /app/Wallet
KPI_SERVICE_URL: http://kpi-service:8080
AUTH_SERVICE_URL: http://auth-service:8082
FEIGN_CLIENT_CONFIG_KPI_SERVICE_URL: http://kpi-service:8080
CORS_ALLOWED_ORIGINS: https://sammy-ulfh.dev
```

### Mapeo de rutas — NGINX Ingress

| Ruta pública | Servicio destino |
|---|---|
| `/` | `frontend` (Nginx + dist) |
| `/api/v1/auth` | `auth-service:8082` |
| `/api/webhook/telegram` | `telegram-service:8081` |
| `/api/anuncios` | `telegram-service:8081` |
| `/api/ai` | `ai-service:8083` |
| `/api/tasks` | `task-service:8084` |
| `/api/sprints` | `task-service:8084` |
| `/api` (catch-all) | `kpi-service:8080` |
| `/swagger-auth` | `auth-service:8082` |
| `/swagger-ia` | `ai-service:8083` |
| `/swagger-tasks` | `task-service:8084` |
| `/swagger-ui` | `kpi-service:8080` |
| `/v3/api-docs/*` | Cada microservicio expone su propia especificación |

### Manifests Kubernetes

| Archivo | Descripción |
|---|---|
| `deployment.yaml` | Template parametrizable por servicio, imagen y puerto |
| `service.yaml` | Exposición interna del microservicio dentro del cluster |
| `ingress.yaml` | Reglas de enrutamiento HTTP/HTTPS |
| `configmap.yaml` | Variables de entorno no sensibles |
| `secrets.yaml` | Referencias a secretos (valores provenientes del Vault) |

### Autorización para el pipeline

Se configura un **Service Account** con permisos RBAC mínimos para que GitHub Actions pueda ejecutar `kubectl apply` sobre los namespaces `vs-blue` y `vs-green`. El `kubeconfig` correspondiente se almacena como GitHub Secret (`OKE_KUBECONFIG`).

---

## 4. Contenerización de la aplicación

### Backend — `taskbot-backend`

Todos los servicios usan `eclipse-temurin:17-jre-alpine` como imagen base.

| Servicio | Artefacto | Consideraciones |
|---|---|---|
| `auth-service` | JAR | `ENTRYPOINT ["java", "-jar", "app.jar"]` |
| `ai-service` | JAR | `ENTRYPOINT ["java", "-jar", "app.jar"]` |
| `task-service` | JAR | `ENTRYPOINT ["java", "-jar", "app.jar"]` |
| `telegram-service` | JAR | `ENTRYPOINT ["java", "-jar", "app.jar"]` |
| `kpi-service` | WAR | Requiere servlet container o Spring Boot configurado para WAR |

El wallet de Oracle se monta como volumen en `/app/Wallet` y no se embebe en la imagen. La configuración se inyecta mediante variables de entorno provenientes del ConfigMap y los Secrets de Kubernetes.

Las dependencias de **Apache Kafka** han sido eliminadas del código fuente y del `.env.example`, ya que están excluidas del alcance del proyecto.

### Frontend — `taskbot-frontend`

El frontend utiliza un Dockerfile multi-stage:

1. **Etapa de build:** `node` — ejecuta `npm run build`, generando los archivos estáticos en `dist/`.
2. **Etapa de producción:** `nginx` — sirve los archivos de `dist/` con configuración de fallback para SPA (`index.html`).

Las llamadas a la API apuntan al dominio público: `https://sammy-ulfh.dev/api/...`

---

## 5. Pipeline CI/CD con GitHub Actions

### Workflow de Build — `.github/workflows/build.yml`

Se ejecuta en cada `push` a la rama `main`. Utiliza **path filters** para compilar y publicar únicamente el microservicio modificado.

| Paso | Descripción |
|---|---|
| Checkout | Descarga el código fuente del repositorio |
| Setup JDK 17 | Configura el entorno Java con caché de Maven |
| `mvn clean package` | Compila el proyecto y genera el artefacto (JAR o WAR) |
| Tests unitarios | El workflow se detiene si alguna prueba falla |
| `docker build` | Construye la imagen con `eclipse-temurin:17-jre-alpine` |
| Login a GHCR | Autenticación contra el registro de imágenes |
| `docker push` | Publica la imagen con etiquetas `:<git-sha>` y `:latest` |

### Workflow de Deploy — `.github/workflows/deploy.yml`

Se dispara al completarse el workflow de Build. Requiere aprobación manual a través del **GitHub Environment** `production`.

| Paso | Descripción |
|---|---|
| Aprobación | El workflow se pausa hasta recibir la aprobación de un revisor autorizado |
| Configurar kubectl | Carga el kubeconfig desde el secret `OKE_KUBECONFIG` |
| Detectar namespace inactivo | Determina si el destino es `vs-blue` o `vs-green` |
| `kubectl apply` | Aplica los manifests al namespace inactivo |
| Verificación de readiness | Espera a que todos los pods estén en estado `Ready` |
| Validación automatizada | Ejecuta la suite de pruebas contra el Test Load Balancer |
| Traffic shift | Actualiza el Ingress para dirigir el tráfico al nuevo namespace |
| Rollback | Si la validación falla, revierte el Ingress y crea un ticket en Jira |

### GitHub Secrets requeridos

| Secret | Descripción |
|---|---|
| `OKE_KUBECONFIG` | kubeconfig del cluster, codificado en base64 |
| `GHCR_TOKEN` | Token de autenticación para GHCR (o `GITHUB_TOKEN` con permisos de packages) |

---

## 6. Estrategia de despliegue Blue/Green

El sistema mantiene dos namespaces espejo en el cluster:

| Namespace | Estado inicial | Descripción |
|---|---|---|
| `vs-blue` | Activo | Recibe el tráfico de producción |
| `vs-green` | Standby | Destino del siguiente despliegue |

### Proceso de despliegue

1. El workflow detecta el namespace activo (vía label o estado del Ingress).
2. El nuevo despliegue se aplica sobre el **namespace inactivo**.
3. Se valida la nueva versión contra el **Test Load Balancer** (`taskbot-test-lb`).
4. Si la validación es exitosa, el Ingress se actualiza para dirigir el Production Load Balancer al namespace recién desplegado.
5. El namespace anterior permanece disponible como contingencia hasta confirmar la estabilidad del nuevo despliegue.

### Rollback

El rollback consiste en revertir la actualización del Ingress para que el Production Load Balancer vuelva a apuntar al namespace anterior. Este procedimiento se ejecuta automáticamente si la validación falla, o manualmente mediante un workflow dedicado.

---

## 7. Testing automatizado e integración con Jira

### Estructura del repositorio `taskbot-tests`

```
taskbot-tests/
├── tests/
│   ├── test_auth_service.py
│   ├── test_kpi_service.py
│   ├── test_ai_service.py
│   ├── test_task_service.py
│   └── test_telegram_service.py
├── integrations/
│   └── jira.py
├── runner.py
├── requirements.txt
└── config.yaml
```

### Tipos de prueba

| Tipo | Descripción |
|---|---|
| Smoke tests | `GET /actuator/health` de cada servicio retorna HTTP 200 |
| Integración | Comunicación entre `task-service` y `kpi-service` vía Feign Client |
| Funcionales | Flujo completo: autenticación → creación de tarea → consulta de KPI |
| Conectividad a DB | Cada servicio establece conexión con la Autonomous Database |
| Frontend | La página principal carga correctamente y los assets están disponibles |

### Integración con Jira

Ante un fallo en la suite de pruebas, el módulo `integrations/jira.py` crea automáticamente un issue de tipo **Bug** en el proyecto `TASKBOT` mediante la API REST de Jira, incluyendo:

- Nombre del test fallido y mensaje de error
- Stack trace completo
- Microservicio afectado, namespace, SHA del commit y timestamp
- Etiquetas: `auto-generated`, `devops`, `rollback`, nombre del microservicio
- Reporte completo adjunto como archivo

---

## 8. Observabilidad

### OCI Logging

Los logs de todos los pods son enviados a OCI Logging mediante el agente instalado en los nodos del cluster. Esto centraliza el registro de eventos de todos los microservicios en una única plataforma.

### OCI Monitoring

Se definen dashboards y métricas para los siguientes indicadores:

- Latencia de respuesta por microservicio
- Uso de CPU y memoria por pod
- Tasa de errores HTTP (5xx)

### OCI Notifications

El topic `taskbot-notifications` envía alertas ante los siguientes eventos:

- Fallo en el pipeline de despliegue
- Pods en estado `CrashLoopBackOff`
- Superación de umbrales en las métricas de Monitoring

### OCI Functions

La función `fn-jira-ticket-creator`, desplegada en `taskbot-functions-app`, está suscrita al topic de notificaciones. Ante una alerta, crea automáticamente un issue en Jira con el contexto del fallo.

---

## 9. Migración de DNS a producción

La transición desde la infraestructura anterior (VPS) al cluster OKE se realiza mediante el siguiente procedimiento:

1. Validar el funcionamiento completo de la aplicación en OKE accediendo al Production Load Balancer por IP directa.
2. Verificar que el mapeo de rutas del Ingress sea correcto para todos los endpoints.
3. Confirmar que cert-manager ha emitido el certificado TLS para `sammy-ulfh.dev`.
4. Reducir el TTL del registro DNS a 300 segundos con 24 horas de anticipación.
5. Actualizar el registro DNS de `sammy-ulfh.dev` para apuntar al Production Load Balancer del cluster OKE.
6. Monitorear tráfico y logs durante el período de transición.
7. Mantener la VPS anterior activa como contingencia hasta confirmar la estabilidad del nuevo entorno.

---

## 10. Organización del equipo

El trabajo se distribuye por capas horizontales de la arquitectura. Cada integrante es responsable de una capa completa, lo que permite el trabajo en paralelo desde el inicio del sprint.

### Responsabilidades

| Integrante | Capa | Entregables |
|---|---|---|
| **Persona 1** | Infraestructura base | Compartment, VCN, subnets, gateways, Vault, Load Balancers, conexión a DB, Log Groups, Notification Topics, DNS |
| **Persona 2** | Kubernetes | Cluster OKE, node pool, namespaces, NGINX Ingress, cert-manager, metrics-server, Secrets, ConfigMap, imagePullSecret, RBAC, Service Account, manifests YAML |
| **Persona 3** | CI/CD | Workflows de Build y Deploy, GitHub Environment `production`, GitHub Secrets, GHCR, lógica Blue/Green, OCI Function, suscripción al Notification Topic |
| **Persona 4** | Aplicación y pruebas | Dockerfiles de los 5 microservicios, Dockerfile del frontend, eliminación de Kafka, repositorio `taskbot-tests`, integración con Jira |

### Dependencias entre capas

| Capa | Depende de | Bloquea a |
|---|---|---|
| Infraestructura base | — | Kubernetes, CI/CD, Aplicación |
| Kubernetes | Infraestructura base | CI/CD, Aplicación |
| CI/CD | Kubernetes | Aplicación |
| Aplicación | — (trabaja en local hasta que CI/CD esté disponible) | — |

---

## 11. Cronograma

### Semana 1

| Día | Actividades |
|---|---|
| 1 | Reunión de inicio: definición de contratos de nombres, creación de repositorios en GitHub y proyecto en Jira |
| 2–3 | Infraestructura de red y Vault · Manifests YAML de Kubernetes · Workflows de GitHub Actions (entorno dummy) · Dockerfiles y eliminación de Kafka |
| 4–5 | Cluster OKE + Ingress + cert-manager · Conexión de workflows a GHCR y GitHub Environment · Primer push de prueba al pipeline |

### Semana 2

| Día | Actividades |
|---|---|
| 6–7 | Primer despliegue end-to-end: 5 microservicios + frontend al namespace `vs-blue` |
| 8 | Suite de pruebas completa · Integración con Jira · Validación de la estrategia Blue/Green |
| 9 | Migración de DNS · Verificación del mapeo de rutas · Prueba de rollback · Verificación de tickets en Jira |
| 10 | Grabación y entrega del video del Sprint |

### Hitos de sincronización

| Hito | Día | Descripción |
|---|---|---|
| Contratos de nombres acordados | 1 | Permite el trabajo paralelo entre todas las capas |
| Primer despliegue end-to-end | 4–5 | Valida la integración de todas las capas |
| Migración de DNS | 9 | Transición del tráfico real a producción |

---

## 12. Checklist de implementación

### Infraestructura OCI (Terraform)

- [ ] Compartment, grupos IAM y políticas
- [ ] VCN, subnets, Internet Gateway, NAT Gateway
- [ ] Vault con todos los secretos cargados
- [ ] Conexión a la Autonomous DB `gestiondetareasbd_tp`
- [ ] Load Balancers (producción y pruebas)
- [ ] Log Groups y Notification Topics
- [ ] OCI Functions Application

### Kubernetes

- [ ] Cluster OKE + node pool en `mx-queretaro-1`
- [ ] Namespaces `vs-blue` y `vs-green`
- [ ] NGINX Ingress con mapeo de rutas completo
- [ ] cert-manager + certificado Let's Encrypt para `sammy-ulfh.dev`
- [ ] metrics-server
- [ ] imagePullSecret para GHCR
- [ ] Secrets y ConfigMap aplicados en ambos namespaces
- [ ] RBAC + Service Account para GitHub Actions

### Aplicación

- [ ] Dockerfile para los 5 microservicios (incluyendo WAR de `kpi-service`)
- [ ] Dockerfile multi-stage del frontend (build + Nginx)
- [ ] Variables de Kafka eliminadas del código y del `.env`
- [ ] Wallet leído desde `/app/Wallet` en todos los servicios
- [ ] `docker-compose.yml` funcional para desarrollo local

### CI/CD

- [ ] Workflow de Build con path filters por microservicio
- [ ] Push a GHCR con etiquetas `:<git-sha>` y `:latest`
- [ ] Workflow de Deploy con autenticación vía kubeconfig
- [ ] GitHub Environment `production` con aprobación requerida
- [ ] Lógica Blue/Green: detección de namespace activo y traffic shift
- [ ] Rollback automático ante fallo de validación
- [ ] Workflow independiente para el frontend

### Testing y Jira

- [ ] Suite de pruebas completa en `taskbot-tests` (pytest)
- [ ] Módulo de integración con la API de Jira
- [ ] Job de validación integrado en el workflow de Deploy
- [ ] Creación automática de issues en Jira ante fallos

### Observabilidad

- [ ] Logs de pods enviados a OCI Logging
- [ ] Dashboards y métricas en OCI Monitoring
- [ ] Alarmas y notificaciones configuradas
- [ ] `fn-jira-ticket-creator` desplegada y suscrita al topic

### Producción

- [ ] Validación completa de la aplicación en OKE
- [ ] DNS de `sammy-ulfh.dev` apuntando al cluster
- [ ] Período de contingencia con VPS anterior activa

---

*TaskBot · Sprint 3 · Infraestructura DevOps sobre Oracle Cloud Infrastructure*

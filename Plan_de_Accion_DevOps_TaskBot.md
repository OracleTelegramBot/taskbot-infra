# Plan de Acción — Infraestructura DevOps de TaskBot

**Sprint 3 · Oracle Cloud Infrastructure (OKE) + GitHub Actions**
Región: `mx-queretaro-1`

---

## Índice

1. [Resumen de la arquitectura objetivo](#1-resumen-de-la-arquitectura-objetivo)
2. [Diferencias clave respecto al enfoque anterior](#2-diferencias-clave-respecto-al-enfoque-anterior)
3. [Fase 0 — Preparación y acuerdos del equipo](#3-fase-0--preparación-y-acuerdos-del-equipo)
4. [Fase 1 — Infraestructura base en OCI (Terraform)](#4-fase-1--infraestructura-base-en-oci-terraform)
5. [Fase 2 — Cluster OKE y configuración Kubernetes](#5-fase-2--cluster-oke-y-configuración-kubernetes)
6. [Fase 3 — Contenerización de la aplicación](#6-fase-3--contenerización-de-la-aplicación)
7. [Fase 4 — CI/CD con GitHub Actions](#7-fase-4--cicd-con-github-actions)
8. [Fase 5 — Estrategia Blue/Green](#8-fase-5--estrategia-bluegreen)
9. [Fase 6 — Testing automatizado e integración con Jira](#9-fase-6--testing-automatizado-e-integración-con-jira)
10. [Fase 7 — Observabilidad en OCI](#10-fase-7--observabilidad-en-oci)
11. [Fase 8 — Migración de DNS y corte de producción](#11-fase-8--migración-de-dns-y-corte-de-producción)
12. [División del trabajo entre 4 personas](#12-división-del-trabajo-entre-4-personas)
13. [Cronograma sugerido](#13-cronograma-sugerido)
14. [Checklist maestro](#14-checklist-maestro)
15. [Preparación del video del Sprint](#15-preparación-del-video-del-sprint)

---

## 1. Resumen de la arquitectura objetivo

La arquitectura define un flujo DevOps donde **GitHub Actions** orquesta el CI/CD y **OKE (Oracle Container Engine for Kubernetes)** ejecuta la aplicación, con observabilidad en servicios nativos de OCI.

Diagrama:
<p align="center">
    <img width="700"
        src="./images/Infraestructure_Diagram.png"
        alt="Diagrama de Infraestructura"
        style="float: left; margin-right: 10px;">
</p>

**Flujo de extremo a extremo:**

```
Developer → git push → GitHub Repository
   → GitHub Actions (Build): construye 5 imágenes Docker
   → push a GHCR (GitHub Container Registry: ghcr.io/<org>/taskbot)
   → GitHub Actions (Deploy): pull desde GHCR
   → Deploy a OKE → Approval manual → Rollout/Update namespace
   → NGINX Ingress Controller → Production Load Balancer → usuarios
```

**Componentes confirmados por el diagrama:**

| Elemento | Valor |
|---|---|
| Región OCI | `mx-queretaro-1` |
| CI/CD | GitHub Actions (Build + Deploy) |
| Registro de imágenes | GitHub Container Registry (`ghcr.io/<org>/taskbot`) |
| Orquestador | OKE (Oracle Container Engine for Kubernetes) |
| Imagen base Java | `eclipse-temurin:17-jre-alpine` |
| Réplicas | 2 por servicio |
| Namespace activo | `vs-blue` |
| Ingress | NGINX Ingress Controller |
| Base de datos | Oracle Autonomous DB (ATP) — `botbd_tp` |
| IA | OpenAI API (`gpt-4o-mini`) |
| Bot | Telegram Bot API (`api.telegram.org`) |
| Observabilidad | OCI Logging, Monitoring, Notification, Functions |

**Microservicios y puertos:**

| Servicio | Puerto | Empaquetado |
|---|---|---|
| kpi-service | 8080 | **WAR** |
| telegram-service | 8081 | JAR |
| auth-service | 8082 | JAR |
| ai-service | 8083 | JAR |
| task-service | 8084 | JAR |

**Secrets y configuración en Kubernetes:**

- `autonomous-db-credentials` (Secret)
- `jwt-secret` (Secret)
- `openai-credentials` (Secret)
- `telegram-credentials` (Secret)
- `oracle-wallet` (Secret montado como volumen en `/app/Wallet`)
- `taskbot-config` (ConfigMap)

---

## 2. Diferencias clave respecto al enfoque anterior

> Esta sección aclara qué cambia respecto a la arquitectura basada en OCI DevOps Service que se exploró antes. Si es la primera vez que lees este plan, puedes saltarla.

| Aspecto | Enfoque anterior (OCI DevOps) | Arquitectura actual (PDF) |
|---|---|---|
| CI/CD | OCI Build/Deployment Pipelines | **GitHub Actions** |
| Repositorio | OCI Code Repository | **GitHub Repository** |
| Registro de imágenes | OCI Container Registry | **GHCR** |
| Disparador | Triggers de OCI con path filters | **GitHub Actions workflows** (`on: push`) |
| Aprobación | OCI Approval stage | **GitHub Environments** con required reviewers |
| Build de Java | Managed Build runner | **GitHub-hosted runners** |
| Observabilidad | OCI nativo | OCI nativo (sin cambios) |
| Orquestador | OKE | OKE (sin cambios) |

**Implicación principal:** todo el conocimiento de pipelines nativos de OCI se reemplaza por workflows YAML de GitHub Actions. La autenticación entre GitHub y OKE se hace con un kubeconfig almacenado como GitHub Secret.

---

## 3. Fase 0 — Preparación y acuerdos del equipo

**Objetivo:** establecer los contratos que permiten trabajar en paralelo sin bloqueos.

### Tareas

- [ ] Reunión de kick-off (1-2 horas) con todo el equipo.
- [ ] Definir y documentar el **contrato de nombres** (ver tabla más abajo).
- [ ] Crear la organización/repos en GitHub y dar acceso al equipo.
- [ ] Crear el proyecto en Jira (`TASKBOT`) con tipo de issue Bug y workflow básico.
- [ ] Acordar la convención de tags de imágenes: `ghcr.io/<org>/taskbot/<servicio>:<git-sha>` y `:latest`.
- [ ] Acordar la estrategia de ramas (recomendado: `main` protegida, feature branches con PR).

### Contrato de nombres

| Recurso | Nombre acordado |
|---|---|
| Compartment | `taskbot-compartment` |
| VCN | `taskbot-vcn` |
| Subnet pública | `taskbot-public-subnet` |
| Subnet privada (nodos OKE) | `taskbot-private-subnet` |
| Cluster OKE | `taskbot-oke-cluster` |
| Node Pool | `taskbot-oke-nodepool` |
| Namespace activo | `vs-blue` |
| Namespace inactivo | `vs-green` |
| Ingress Controller | `nginx-ingress` (namespace `ingress-nginx`) |
| Production Load Balancer | `taskbot-prod-lb` |
| Test Load Balancer | `taskbot-test-lb` |
| Vault | `taskbot-vault` |
| OCI Functions Application | `taskbot-functions-app` |
| OCI Function (Jira) | `fn-jira-ticket-creator` |
| Dominio público | `sammy-ulfh.dev` |
| Proyecto Jira | `TASKBOT` |
| GHCR namespace | `ghcr.io/<org>/taskbot` |

### Repositorios

| Repositorio | Contenido |
|---|---|
| `taskbot-backend` | Monorepo Java con los 5 microservicios + `docker-compose.yml` |
| `taskbot-frontend` | Aplicación web en Vite |
| `taskbot-tests` | Scripts de testing en Python + integración Jira |
| `taskbot-infra` | Código Terraform de toda la infraestructura OCI |

---

## 4. Fase 1 — Infraestructura base en OCI (Terraform)

**Objetivo:** provisionar toda la base de OCI con infraestructura como código. Se ejecuta una sola vez.

### Tareas

- [ ] Configurar el provider de OCI en Terraform (tenancy, user, region `mx-queretaro-1`).
- [ ] Crear el **Compartment** `taskbot-compartment`.
- [ ] Crear **Identity**: grupos, dynamic groups y políticas IAM necesarias para que OKE y Functions operen.
- [ ] Crear **Networking**:
  - [ ] VCN `taskbot-vcn`
  - [ ] Subnet pública `taskbot-public-subnet` (para Load Balancers)
  - [ ] Subnet privada `taskbot-private-subnet` (para nodos OKE)
  - [ ] Internet Gateway, NAT Gateway, route tables, security lists
- [ ] Crear el **Vault** `taskbot-vault` y cargar los secretos:
  - [ ] Credenciales de la Autonomous DB (`botbd_tp`)
  - [ ] Contenido del wallet de Oracle
  - [ ] `JWT_SECRET`
  - [ ] `OPENAI_API_KEY`
  - [ ] `TELEGRAM_BOT_TOKEN`
  - [ ] Token de Jira (para la OCI Function)
- [ ] Configurar la **conexión de red a la Autonomous DB existente** (`botbd_tp`) — no se crea la base, solo se referencia su OCID y se permite el acceso desde la subnet privada.
- [ ] Crear **Log Groups** y **Notification Topics** base.
- [ ] Crear la **OCI Functions Application** `taskbot-functions-app`.

### Notas importantes

- El repositorio de imágenes es **GHCR**, no OCI Container Registry, por lo que **no** se crea un Container Registry en OCI. El cluster OKE necesitará un `imagePullSecret` para autenticarse contra GHCR (ver Fase 2).
- Terraform vive en el repo `taskbot-infra` y se mantiene separado del código de aplicación.

---

## 5. Fase 2 — Cluster OKE y configuración Kubernetes

**Objetivo:** dejar el cluster listo para recibir despliegues.

### Tareas

- [ ] Crear el **cluster OKE** `taskbot-oke-cluster` con Terraform (en `mx-queretaro-1`).
- [ ] Crear el **node pool** `taskbot-oke-nodepool` dimensionado (mínimo 2 nodos para alta disponibilidad).
- [ ] Generar el **kubeconfig** y validar acceso con `kubectl get nodes`.
- [ ] Crear los **namespaces**: `vs-blue` y `vs-green`.
- [ ] Instalar el **NGINX Ingress Controller** vía Helm (en namespace `ingress-nginx`), asociándolo al Production Load Balancer.
- [ ] Instalar **cert-manager** y configurar un `ClusterIssuer` para Let's Encrypt sobre `sammy-ulfh.dev`.
- [ ] Instalar **metrics-server** (para autoescalado futuro).
- [ ] Crear el **imagePullSecret** para que OKE pueda descargar imágenes privadas de GHCR.
- [ ] Crear los **Kubernetes Secrets** (sincronizados desde el Vault):
  - [ ] `autonomous-db-credentials`
  - [ ] `oracle-wallet` (se montará como volumen en `/app/Wallet`)
  - [ ] `jwt-secret`
  - [ ] `openai-credentials`
  - [ ] `telegram-credentials`
- [ ] Crear el **ConfigMap** `taskbot-config` con la configuración no sensible:
  - [ ] `TNS_ADMIN=/app/Wallet`
  - [ ] `ORACLE_WALLET_PATH=/app/Wallet`
  - [ ] `KPI_SERVICE_URL=http://kpi-service:8080`
  - [ ] `AUTH_SERVICE_URL=http://auth-service:8082`
  - [ ] `FEIGN_CLIENT_CONFIG_KPI_SERVICE_URL=http://kpi-service:8080`
  - [ ] `CORS_ALLOWED_ORIGINS=https://sammy-ulfh.dev`
- [ ] Aplicar **RBAC** y crear el **Service Account** que usará GitHub Actions para desplegar.
- [ ] Configurar **readiness/liveness probes** apuntando a `/actuator/health` de cada servicio.
- [ ] Instalar el **agente de logging de OCI** para enviar logs de pods a OCI Logging.

### Manifests YAML a producir (templates reutilizables)

- [ ] `deployment.yaml` (template parametrizable por servicio, imagen y puerto)
- [ ] `service.yaml` (template)
- [ ] `ingress.yaml` (replica el mapeo de rutas del Apache actual — ver más abajo)
- [ ] `configmap.yaml`
- [ ] `secrets.yaml` (referencias, los valores vienen del Vault)

### Mapeo de rutas del Ingress (replica el Apache actual)

| Ruta pública | Service destino |
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
| `/v3/api-docs/*` | cada microservicio expone el suyo |

> **Nota:** el Swagger UI se mantiene expuesto a propósito (proyecto académico). El Ingress no debe bloquear estas rutas.

---

## 6. Fase 3 — Contenerización de la aplicación

**Objetivo:** preparar el código para correr en contenedores sobre Kubernetes.

### Tareas backend (monorepo `taskbot-backend`)

- [ ] Verificar/crear un **Dockerfile por microservicio** usando imagen base `eclipse-temurin:17-jre-alpine`.
  - [ ] 4 servicios JAR (auth, ai, task, telegram): `COPY` del `.jar` + `ENTRYPOINT ["java","-jar","app.jar"]`
  - [ ] **kpi-service es WAR**: requiere un Dockerfile diferente — desplegar el WAR en un servlet container o usar el embedded de Spring Boot configurado para WAR. Confirmar cómo se ejecuta hoy.
- [ ] Asegurar que cada servicio lee su configuración desde variables de entorno (ya lo hace según el `docker-compose.yml`).
- [ ] Quitar del código y del `.env.example` las variables de **Kafka** (`SPRING_KAFKA_BOOTSTRAP_SERVERS`, `KAFKA_BROKERCONNECT`) — excluidas del proyecto final.
- [ ] Verificar que el wallet se lea desde `/app/Wallet` (montado como volumen, no embebido en la imagen).
- [ ] Mantener `docker-compose.yml` funcional para desarrollo local.

### Tareas frontend (repo `taskbot-frontend`)

- [ ] Crear un **Dockerfile multi-stage**: etapa 1 build (`npm run build` → `dist`), etapa 2 Nginx sirviendo `dist`.
- [ ] Configurar Nginx interno del contenedor para el fallback de SPA (todas las rutas no-API → `index.html`).
- [ ] Apuntar las llamadas del frontend al dominio público (`https://sammy-ulfh.dev/api/...`).

### Validación

- [ ] Construir todas las imágenes localmente y probar el stack completo con `docker-compose up`.
- [ ] Verificar conexión real a la Autonomous DB usando el wallet.

---

## 7. Fase 4 — CI/CD con GitHub Actions

**Objetivo:** automatizar build, push y deploy con workflows de GitHub Actions.

### Configuración previa en GitHub

- [ ] Crear los **GitHub Secrets** en el repo (o a nivel organización):
  - [ ] `OKE_KUBECONFIG` (kubeconfig del cluster, base64)
  - [ ] `GHCR_TOKEN` (o usar el `GITHUB_TOKEN` automático con permisos de packages)
  - [ ] Cualquier credencial necesaria para el deploy
- [ ] Crear un **GitHub Environment** llamado `production` con **required reviewers** (esto implementa el Approval manual del diagrama).
- [ ] Habilitar permisos de escritura de packages para GHCR.

### Workflow de Build (`.github/workflows/build.yml`)

- [ ] Disparador: `on: push` a `main`.
- [ ] Usar **path filters** (`paths:`) para construir solo el microservicio que cambió (deployment selectivo en el monorepo).
- [ ] Pasos por microservicio:
  - [ ] Checkout del código
  - [ ] Setup JDK 17 + cache de Maven
  - [ ] `mvn clean package` (genera JAR o WAR según el servicio)
  - [ ] Ejecutar tests unitarios (si fallan, el workflow falla)
  - [ ] `docker build` con imagen base `eclipse-temurin:17-jre-alpine`
  - [ ] Login a GHCR
  - [ ] `docker push` con tags `:<git-sha>` y `:latest`

### Workflow de Deploy (`.github/workflows/deploy.yml`)

- [ ] Disparador: al completarse el Build (o `workflow_run`).
- [ ] Apuntar al GitHub Environment `production` (esto pausa esperando el Approval manual).
- [ ] Pasos:
  - [ ] Configurar `kubectl` con `OKE_KUBECONFIG`
  - [ ] Determinar el namespace inactivo (vs-blue o vs-green) — ver Fase 5
  - [ ] `kubectl apply` de los manifests al namespace inactivo (pull de imágenes desde GHCR)
  - [ ] Esperar a que los pods estén `Ready` (readiness probes)
  - [ ] Ejecutar el job de validación (testing — ver Fase 6)
  - [ ] Si pasa: hacer el traffic shift (actualizar el Ingress)
  - [ ] Si falla: rollback + disparar creación de ticket en Jira

### Workflow del frontend (repo separado)

- [ ] Workflow propio en `taskbot-frontend` con su build de Vite y deploy independiente.

---

## 8. Fase 5 — Estrategia Blue/Green

**Objetivo:** despliegues sin downtime con rollback instantáneo.

> **Decisión asumida:** Blue/Green real con 2 namespaces (`vs-blue` y `vs-green`). El PDF muestra solo `vs-blue` porque es el namespace activo en ese momento. Si el equipo prefiere rolling update sobre un solo namespace, esta fase se simplifica a `kubectl rollout`.

### Tareas

- [ ] Mantener dos namespaces espejo: `vs-blue` (activo) y `vs-green` (inactivo).
- [ ] El workflow de Deploy detecta cuál está activo leyendo una label o el estado del Ingress.
- [ ] Desplegar siempre al **namespace inactivo**.
- [ ] Validar contra el **Test Load Balancer** (`taskbot-test-lb`) que apunta al inactivo.
- [ ] Hacer el **traffic shift**: actualizar el Ingress para que el Production Load Balancer apunte al namespace recién desplegado.
- [ ] Conservar el namespace anterior intacto por unas horas como red de seguridad para rollback.

### Rollback

- [ ] Procedimiento documentado: actualizar el Ingress para volver a apuntar al namespace anterior (segundos).
- [ ] El rollback se dispara automáticamente si la validación falla, o manualmente desde un workflow dedicado.

---

## 9. Fase 6 — Testing automatizado e integración con Jira

**Objetivo:** validar cada despliegue antes del traffic shift y crear tickets automáticos ante fallos.

### Repositorio `taskbot-tests`

- [ ] Estructura:
  - [ ] `tests/` — scripts pytest por servicio (`test_auth_service.py`, `test_kpi_service.py`, etc.)
  - [ ] `integrations/` — módulo de integración con Jira
  - [ ] `runner.py` — orquestador que ejecuta todo y decide el resultado
  - [ ] `requirements.txt` — pytest, requests, jira
  - [ ] `config.yaml` — endpoints del Test Load Balancer
- [ ] Tipos de prueba:
  - [ ] Smoke tests (`/actuator/health` de cada servicio responde 200)
  - [ ] Integración (task-service → kpi-service vía Feign)
  - [ ] Funcionales (login → crear tarea → consultar KPI)
  - [ ] Conexión a DB (cada servicio conecta a la Autonomous DB)
  - [ ] Frontend (la home carga y los assets están disponibles)

### Integración con Jira

- [ ] El `runner.py` lee credenciales de Jira desde el Vault (o GitHub Secret).
- [ ] Ante un fallo, recopila contexto (test, error, stack trace, microservicio, namespace, SHA, timestamp).
- [ ] Llama a la API REST de Jira para crear un issue tipo **Bug** en el proyecto `TASKBOT`.
- [ ] Aplica labels: `auto-generated`, `devops`, `rollback`, `environment-green`, nombre del microservicio.
- [ ] Adjunta el reporte completo.

### Integración con el flujo

- [ ] El job de testing se ejecuta dentro del workflow de Deploy (como step) o como una **OCI Function** (`fn-jira-ticket-creator`) invocada desde el workflow.
- [ ] Si el testing falla → rollback automático + ticket en Jira.

---

## 10. Fase 7 — Observabilidad en OCI

**Objetivo:** registrar y monitorear todo el sistema usando servicios nativos de OCI.

### Tareas

- [ ] **Logging Service**: confirmar que los logs de todos los pods llegan a OCI Logging vía el agente instalado en Fase 2.
- [ ] **Monitoring Service**: crear dashboards y métricas clave (latencia, uso de CPU/memoria por pod, tasa de errores).
- [ ] **Notification Service**: configurar el topic `taskbot-notifications` para enviar alertas (email/Slack) ante:
  - [ ] Fallos de despliegue
  - [ ] Pods en CrashLoopBackOff
  - [ ] Alarmas de métricas (CPU alta, errores 5xx)
- [ ] **OCI Functions**: desplegar `fn-jira-ticket-creator` en `taskbot-functions-app`, suscrita al topic de notificaciones.
- [ ] Crear **alarmas** en Monitoring que disparen notificaciones cuando se degraden las métricas post-deploy.

---

## 11. Fase 8 — Migración de DNS y corte de producción

**Objetivo:** mover el tráfico real de la VPS actual al cluster OKE.

### Tareas

- [ ] Validar que toda la aplicación funciona en OKE accediendo vía el Production Load Balancer (IP directa o subdominio temporal).
- [ ] Verificar el mapeo completo de rutas (todas las rutas de la tabla del Ingress responden correctamente).
- [ ] Confirmar que cert-manager emitió el certificado Let's Encrypt para `sammy-ulfh.dev`.
- [ ] Bajar el TTL del registro DNS a 300s con anticipación (24h antes).
- [ ] **Cambiar el registro DNS** de `sammy-ulfh.dev` para apuntar al Production Load Balancer del cluster OKE.
- [ ] Monitorear el tráfico y los logs durante el corte.
- [ ] Mantener la VPS antigua encendida unos días como respaldo.
- [ ] Una vez estable, decomisionar la VPS.

---

## 12. División del trabajo entre 4 personas

> Principio: dividir por **capas horizontales**, no por microservicio. Cada persona es dueña de una capa completa de extremo a extremo. Con el contrato de nombres de la Fase 0, cada quien trabaja contra identificadores acordados aunque los recursos reales aún no existan.

### Persona 1 — Infraestructura base y networking (Terraform)

**Entrega:** Compartment, VCN, subnets, gateways, Vault con todos los secretos, Load Balancers, conexión a la Autonomous DB, Notification Topics, Log Groups, coordinación del DNS.

**Bloquea a:** Personas 2, 3 y 4.
**Desbloqueo día 1:** publicar documento de OCIDs simulados acordados en el kick-off.

### Persona 2 — Cluster OKE y configuración Kubernetes

**Entrega:** cluster OKE, node pool, namespaces vs-blue/vs-green, NGINX Ingress (con el mapeo de rutas completo), cert-manager, metrics-server, Kubernetes Secrets desde Vault, ConfigMap `taskbot-config`, imagePullSecret para GHCR, RBAC, Service Account para GitHub Actions, templates de manifests YAML.

**Bloquea a:** Persona 3 (deploy) y Persona 4 (pruebas e2e reales).
**Desbloqueo día 1:** escribir los manifests YAML base sin cluster real, usando los nombres acordados.

### Persona 3 — CI/CD con GitHub Actions e integración Jira

**Entrega:** workflows de Build y Deploy en `taskbot-backend`, workflow del frontend, GitHub Environment `production` con approval, GitHub Secrets, configuración de GHCR, lógica Blue/Green en el workflow, OCI Function `fn-jira-ticket-creator`, suscripción al Notification Topic.

**Bloquea a:** Persona 4 (push real que dispare los workflows).
**Desbloqueo día 1:** escribir los workflows YAML contra los nombres acordados; probar con un repo dummy "hello world".

### Persona 4 — Aplicación, contenerización, testing y demo

**Entrega:** Dockerfiles de los 5 microservicios (incluyendo el caso especial WAR de kpi-service), Dockerfile multi-stage del frontend, limpieza de Kafka, repositorio `taskbot-tests` completo con integración Jira, el cambio/bug a demostrar, guión y grabación del video.

**Bloquea a:** nadie (consumidor final).
**Desbloqueo día 1:** trabajar localmente con docker-compose; escribir tests con mocks; cuando los Load Balancers existan, cambiar el endpoint en `config.yaml`.

### Resumen de bloqueos cruzados

| Persona | Recurso crítico que entrega | A quién bloquea |
|---|---|---|
| Persona 1 | VCN, Vault, Load Balancers, DNS, conexión a DB | Personas 2, 3, 4 |
| Persona 2 | Cluster OKE, namespaces, Ingress, Secrets, kubeconfig | Personas 3 y 4 |
| Persona 3 | Workflows de GitHub Actions, GHCR, approval | Persona 4 |
| Persona 4 | Código contenerizado y tests | Nadie |

---

## 13. Cronograma sugerido

### Semana 1

| Día | Actividad |
|---|---|
| 1 | Kick-off, definir contratos de nombres, crear repos en GitHub y proyecto en Jira. Todos arrancan en paralelo. |
| 2-3 | P1 termina red y Vault. P2 escribe manifests YAML y plan de Ingress. P3 escribe workflows de GitHub Actions contra repo dummy. P4 crea Dockerfiles y limpia Kafka. |
| 4-5 | P2 levanta cluster OKE + Ingress + cert-manager. P3 conecta workflows reales + GHCR + Environment con approval. P4 hace primer push de prueba a `taskbot-backend`. |

### Semana 2

| Día | Actividad |
|---|---|
| 6-7 | Integración end-to-end: primer despliegue completo de los 5 microservicios + frontend al namespace vs-blue. |
| 8 | Implementar testing (`taskbot-tests`) + integración Jira. Probar Blue/Green con un cambio real. |
| 9 | Migración de DNS de `sammy-ulfh.dev` al cluster. Validar mapeo completo de rutas. Pruebas de rollback intencional + verificación de tickets Jira. |
| 10 | Grabar el video del Sprint con un cambio real, editar y subir a Canvas. |

### Puntos críticos de sincronización

1. **Kick-off (día 1):** contratos de nombres.
2. **Integración inicial (día 4-5):** primer despliegue end-to-end.
3. **Migración de DNS (día 9):** afecta a usuarios reales.

---

## 14. Checklist maestro

### Infraestructura OCI
- [ ] Compartment, IAM, VCN, subnets, gateways
- [ ] Vault con todos los secretos
- [ ] Conexión a la Autonomous DB `botbd_tp`
- [ ] Load Balancers (prod + test)
- [ ] Log Groups, Notification Topics, Functions App

### Kubernetes (OKE)
- [ ] Cluster + node pool en `mx-queretaro-1`
- [ ] Namespaces vs-blue y vs-green
- [ ] NGINX Ingress con mapeo de rutas completo
- [ ] cert-manager + certificado Let's Encrypt
- [ ] metrics-server
- [ ] imagePullSecret para GHCR
- [ ] Secrets y ConfigMap
- [ ] RBAC + Service Account para GitHub Actions

### Aplicación
- [ ] Dockerfiles de los 5 microservicios (kpi-service WAR contemplado)
- [ ] Dockerfile multi-stage del frontend
- [ ] Kafka eliminado del código y del `.env`
- [ ] Wallet leído desde `/app/Wallet`
- [ ] docker-compose local funcional

### CI/CD (GitHub Actions)
- [ ] Workflow de Build con path filters
- [ ] Push a GHCR con tags por SHA
- [ ] Workflow de Deploy con kubeconfig
- [ ] GitHub Environment `production` con approval
- [ ] Lógica Blue/Green + traffic shift
- [ ] Workflow independiente del frontend

### Testing y Jira
- [ ] Repo `taskbot-tests` con pytest
- [ ] Integración con API de Jira
- [ ] Job de validación en el workflow de Deploy
- [ ] Rollback automático ante fallo

### Observabilidad
- [ ] Logs de pods llegando a OCI Logging
- [ ] Dashboards en Monitoring
- [ ] Alarmas + notificaciones
- [ ] `fn-jira-ticket-creator` desplegada

### Producción
- [ ] Validación completa en OKE
- [ ] DNS migrado a `sammy-ulfh.dev`
- [ ] VPS antigua como respaldo temporal

---

## 15. Preparación del video del Sprint

El video debe durar **máximo 4 minutos** y mostrar el ciclo de vida de un cambio (el flujo recurrente, no la creación de infraestructura).

| Sección del video | Qué mostrar |
|---|---|
| 1. Cambio o bug a resolver | Editor de código + terminal con `git push` |
| 2. Build (GitHub Actions) | Pestaña Actions de GitHub mostrando el workflow de Build corriendo |
| 3. Push a GHCR | La imagen apareciendo en GitHub Packages / GHCR |
| 4. Deploy + Approval | Workflow de Deploy pausado esperando approval, luego aprobado |
| 5. Ejecución sin errores | Pods actualizándose en OKE (`kubectl get pods`) y el cambio visible en `sammy-ulfh.dev` |

**Recomendación:** mostrar el camino feliz (todo pasa) y explicar verbalmente el flujo de rollback + Jira mientras se enseña el diagrama de arquitectura, en lugar de grabar un fallo en vivo.

---

*Documento generado como guía de implementación para el Sprint 3 de TaskBot. Los puntos marcados como asumidos (Blue/Green con 2 namespaces, testing + Jira, estructura de repos) deben confirmarse con el equipo antes de comenzar.*

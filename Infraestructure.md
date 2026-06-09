# TaskBot — Documentación de Infraestructura y Operaciones

> Documento de referencia técnica y manual operativo para el sistema TaskBot desplegado en Oracle Kubernetes Engine (OKE).
>
> **Última actualización**: Junio 2026
> **Dominio productivo**: https://sammy-ulfh.dev
> **Región OCI**: mx-queretaro-1
> **Cluster**: taskbot-oke

---

## Tabla de contenidos

1. [Resumen ejecutivo](#1-resumen-ejecutivo)
2. [Arquitectura general](#2-arquitectura-general)
3. [Componentes de infraestructura (OCI)](#3-componentes-de-infraestructura-oci)
4. [Componentes de Kubernetes](#4-componentes-de-kubernetes)
5. [Microservicios](#5-microservicios)
6. [Routing y networking](#6-routing-y-networking)
7. [Secrets y configuración](#7-secrets-y-configuración)
8. [CI/CD: Build y Deploy](#8-cicd-build-y-deploy)
9. [Flujo de deploy paso a paso](#9-flujo-de-deploy-paso-a-paso)
10. [Rollback](#10-rollback)
11. [Operaciones del día a día](#11-operaciones-del-día-a-día)
12. [Troubleshooting](#12-troubleshooting)
13. [Procedimientos de emergencia](#13-procedimientos-de-emergencia)
14. [Mejoras pendientes (roadmap)](#14-mejoras-pendientes-roadmap)
15. [Anexos](#15-anexos)

---

## 1. Resumen ejecutivo

TaskBot es una aplicación distribuida compuesta por **5 microservicios backend** (Spring Boot 3/4 con Java 17), un **frontend SPA** (Vite + React) y una **base de datos Oracle Autonomous Database**. Funciona en un cluster Kubernetes (OKE) en Oracle Cloud, expuesto al exterior a través de un Load Balancer y NGINX Ingress Controller, con dominio `sammy-ulfh.dev` y TLS público.

### Capacidades del sistema

| Capacidad | Estado |
|---|---|
| Despliegue blue/green con cero downtime entre versiones funcionales | ✅ |
| Rollback automático si los smoke tests post-deploy fallan | ✅ |
| Tolerancia a caídas de la base de datos sin matar pods | ✅ |
| Secretos cifrados en OCI Vault, sincronizados a K8s vía ESO | ✅ |
| Build automático de imágenes en GitHub Actions | ✅ |
| Deploy controlado manualmente desde GitHub UI o CLI | ✅ |
| Swagger UI unificado con dropdown para los 5 servicios | ✅ |
| CORS configurado para producción + desarrollo local (Vite) | ✅ |
| Bot de Telegram con webhook directo al cluster | ✅ |
| Alta disponibilidad: 2 réplicas por servicio | ✅ |

### Datos clave

- **Cluster**: 2 nodes amd64 v1.36.0 en mx-queretaro-1
- **Dominio**: `sammy-ulfh.dev` (TLS ZeroSSL, vence 21-Jul-2026)
- **Namespaces de aplicación**: `vs-blue` y `vs-green` (uno activo a la vez)
- **Repositorios**: 3 (backend, frontend, infra)
- **Imágenes Docker**: 6 en GHCR (5 backend + 1 frontend)

---

## 2. Arquitectura general

```
                              Internet
                                  │
                                  ▼
                        ┌────────────────────┐
                        │  DNS: sammy-ulfh   │
                        │  .dev → LB IP      │
                        └────────┬───────────┘
                                 │
                                 ▼
                     ┌───────────────────────────┐
                     │ OCI Load Balancer (Flex)  │
                     │ 163.192.133.25:443        │
                     │ TLS termination en NGINX  │
                     └───────────┬───────────────┘
                                 │
                                 ▼
            ┌────────────────────────────────────────────┐
            │     OKE Cluster (mx-queretaro-1)           │
            │                                            │
            │  ┌──────────────────────────────────────┐  │
            │  │  Namespace: ingress-nginx            │  │
            │  │  • NGINX Ingress Controller          │  │
            │  │  • Secret sammy-ulfh-dev-tls         │  │
            │  └────────────┬─────────────────────────┘  │
            │               │ (route by Host + Path)     │
            │               │                            │
            │  ┌────────────▼─────────────────────────┐  │
            │  │  Namespace ACTIVO (vs-blue OR        │  │
            │  │  vs-green según cutover)             │  │
            │  │                                      │  │
            │  │  ┌──────┐ ┌──────┐ ┌──────┐ ┌─────┐  │  │
            │  │  │ auth │ │ kpi  │ │  ai  │ │ task│  │  │
            │  │  │ x2   │ │ x2   │ │ x2   │ │ x2  │  │  │
            │  │  └──┬───┘ └──┬───┘ └──┬───┘ └──┬──┘  │  │
            │  │     │        │        │        │     │  │
            │  │     └────────┴────┬───┴────────┘     │  │
            │  │   ┌───────────────▼─────────────┐    │  │
            │  │   │ Wallet (initContainer)      │    │  │
            │  │   │ desde OCI Object Storage    │    │  │
            │  │   └──┬──────────────────────────┘    │  │
            │  │      │                                │  │
            │  │  ┌───▼──┐  ┌──────────┐  ┌─────────┐  │  │
            │  │  │ tele │  │ frontend │  │ secrets │  │  │
            │  │  │ x2   │  │ x2       │  │ (ESO)   │  │  │
            │  │  └──────┘  └──────────┘  └────┬────┘  │  │
            │  │                                │       │  │
            │  └────────────────────────────────┼───────┘  │
            │                                   │           │
            │  ┌────────────────────────────────▼───────┐  │
            │  │  Namespace: external-secrets-system    │  │
            │  │  • ESO Controller                      │  │
            │  │  • ClusterSecretStore (OCI Vault)      │  │
            │  └─────────────────┬──────────────────────┘  │
            │                    │                          │
            └────────────────────┼──────────────────────────┘
                                 │ (instance principal auth)
                ┌────────────────┼─────────────────┐
                │                │                 │
                ▼                ▼                 ▼
        ┌─────────────┐  ┌─────────────┐  ┌──────────────┐
        │ OCI Vault   │  │ Object      │  │ Autonomous   │
        │ 6 secrets   │  │ Storage     │  │ Database     │
        │ cifrados    │  │ wallet.zip  │  │ (otra cuenta)│
        └─────────────┘  └─────────────┘  └──────────────┘
```

### Componentes principales en capas

| Capa | Tecnología |
|---|---|
| **DNS** | Registrar externo (A record → LB IP) |
| **Load Balancer** | OCI Flexible LB |
| **TLS termination** | NGINX Ingress Controller |
| **Routing HTTP** | NGINX Ingress (host + path matching) |
| **Aplicación** | Spring Boot 3.3-3.5 / Spring Boot 4.0 / Vite-React |
| **Orquestación** | Kubernetes 1.36 (OKE) |
| **Secretos** | OCI Vault + External Secrets Operator (ESO) |
| **Archivos** | OCI Object Storage (wallet) |
| **Base de datos** | Oracle Autonomous Database (cuenta separada) |
| **Container Registry** | GitHub Container Registry (GHCR) |
| **CI/CD** | GitHub Actions |

---

## 3. Componentes de infraestructura (OCI)

Todos los recursos están en el compartment `taskbot-compartment` y región `mx-queretaro-1`. Gestionados por Terraform en el repo `taskbot-infra/infra/terraform/`.

### 3.1 Virtual Cloud Network (VCN)

VCN privada con subnets públicas y privadas:
- **Subnet pública**: para el Load Balancer
- **Subnet privada**: para los worker nodes del OKE

### 3.2 OKE Cluster

- **Nombre**: taskbot-oke
- **Versión Kubernetes**: 1.36.0
- **Nodes**: 2 worker nodes (amd64)
- **Plano de control**: gestionado por OCI (gratis en plan free)
- **Networking**: VCN-Native CNI (OCI VCN-Native Pod Networking)

Comando para verificar estado:
```bash
kubectl get nodes
# Esperado: 2 nodes en STATUS=Ready
```

### 3.3 Object Storage

- **Bucket**: `taskbot-wallet` (acceso `NoPublicAccess`)
- **Object**: `Wallet_gestiondetareasbd_tp.zip`
- **Namespace**: `ax5o32ww5jyq`
- **Acceso**: vía Dynamic Group + IAM Policy para que los nodes lo puedan leer con autenticación de "instance principal"

### 3.4 OCI Vault

- **Vault**: contiene un master encryption key
- **Secretos almacenados**:
  - `JWT_SECRET` — firma de tokens JWT
  - `OPENAI_API_KEY` — para ai-service
  - `TELEGRAM_BOT_TOKEN` — para telegram-service
  - `DB_ADMIN_USERNAME` — credenciales DB
  - `DB_ADMIN_PASSWORD` — credenciales DB
  - `WALLET_PASSWORD` — para descifrar el wallet de la DB

Los secretos están protegidos por `lifecycle.ignore_changes = [secret_content]` en Terraform, lo que significa que los valores reales se ponen manualmente (no quedan commiteados).

### 3.5 Load Balancer

- **Tipo**: Flexible Load Balancer
- **IP pública**: `163.192.133.25`
- **Listeners**: 80 (HTTP, redirect a HTTPS) y 443 (HTTPS)
- **Backend**: pods del NGINX Ingress Controller en el cluster
- **Creado automáticamente** cuando se instaló el Helm chart de NGINX Ingress

### 3.6 IAM Policies

Dos políticas principales:
- **oke_nodes_vault_access**: permite a los nodes del OKE leer secrets de Vault y objetos del bucket `taskbot-wallet`
- **dynamic-group taskbot-oke-nodes-dg**: agrupa los compute instances que son worker nodes

### 3.7 Autonomous Database

- **Vive en otra cuenta OCI** (importante para gestión)
- **TNS alias**: `gestiondetareasbd_tp`
- **JDBC URL**: `jdbc:oracle:thin:@gestiondetareasbd_tp?TNS_ADMIN=/app/Wallet`
- **Operativa**: se enciende/apaga manualmente para ahorrar créditos (la app es tolerante a esto)

> ⚠️ Las aplicaciones backend están configuradas para **arrancar y seguir corriendo incluso si la DB está caída**. Cuando la DB cae, los pods salen del pool de endpoints (readiness probe falla) pero no se reinician. Cuando vuelve, se re-incorporan automáticamente.

---

## 4. Componentes de Kubernetes

### 4.1 Namespaces

| Namespace | Propósito |
|---|---|
| `vs-blue` | Aplicación TaskBot (color blue del blue/green) |
| `vs-green` | Aplicación TaskBot (color green del blue/green) |
| `ingress-nginx` | NGINX Ingress Controller + TLS secret |
| `external-secrets-system` | ESO Controller |
| `cert-manager` | (placeholder, no usado por ahora) |
| `kube-system` | Componentes del propio K8s |

### 4.2 Patrón Blue/Green

En cualquier momento, **solo uno** de `vs-blue` o `vs-green` tiene un `Ingress` activo apuntando a `sammy-ulfh.dev`. El otro namespace mantiene la versión anterior de la app corriendo (pods Ready) como "rollback instantáneo".

```
Estado normal:
  vs-blue   → Ingress activo, sirve tráfico                  ← ACTIVO
  vs-green  → pods corriendo, sin Ingress                    ← PASIVO

Después de un deploy exitoso:
  vs-blue   → pods corriendo, sin Ingress                    ← PASIVO (versión vieja)
  vs-green  → Ingress activo, sirve tráfico (versión nueva) ← ACTIVO
```

El cutover (switch entre colores) es atómico: se borra el Ingress viejo, se aplica el nuevo (~5-10 seg de downtime breve durante la transición).

### 4.3 External Secrets Operator (ESO)

ESO sincroniza los secrets de OCI Vault hacia K8s.

- **ClusterSecretStore**: define cómo conectarse a OCI Vault (usa instance principal auth de los nodes)
- **ClusterExternalSecret**: define qué secrets sincronizar y a qué namespace

El resultado es un `Secret` de Kubernetes llamado `taskbot-secrets` en cada namespace (`vs-blue` y `vs-green`), con las 6 keys en formato UPPER_SNAKE_CASE.

Los Deployments referencian ese Secret vía `envFrom`:

```yaml
envFrom:
  - secretRef:
      name: taskbot-secrets
```

Esto convierte las 6 keys del Secret en variables de entorno disponibles para el container.

> 💡 Los nombres deben ser UPPER_SNAKE_CASE porque Kubernetes filtra silenciosamente las env vars con caracteres inválidos (como guiones). Por eso es `JWT_SECRET` y no `jwt-secret`.

### 4.4 NGINX Ingress Controller

- Instalado vía Helm chart oficial
- Configurado con flag `--default-ssl-certificate=ingress-nginx/sammy-ulfh-dev-tls`
- Sirve el cert real para `sammy-ulfh.dev` incluso si los Ingress individuales no especifican TLS
- El Secret del cert debe contener el `fullchain.crt` (cert hoja + intermedios), NO solo `certificate.crt`

### 4.5 ConfigMaps

`infra/k8s/40-apps/00-config/oci-config.yaml` define el ConfigMap `oci-config` en ambos namespaces:

```yaml
OS_NAMESPACE: ax5o32ww5jyq
WALLET_BUCKET: taskbot-wallet
WALLET_OBJECT: Wallet_gestiondetareasbd_tp.zip
```

Los pods que necesitan el wallet (backends con DB) usan estos valores en su initContainer para bajar el archivo del bucket.

### 4.6 RBAC

Cada namespace tiene un `ServiceAccount` llamado `github-deployer` con permisos restringidos para que el workflow de GitHub Actions pueda aplicar Deployments e Ingresses **solo en su propio namespace**.

- Blue's SA solo puede manipular vs-blue
- Green's SA solo puede manipular vs-green
- Los tokens largos viven en Secrets de tipo `kubernetes.io/service-account-token`
- Los kubeconfigs generados con estos tokens se almacenan en GitHub como `OKE_KUBECONFIG_BLUE` y `OKE_KUBECONFIG_GREEN` (en el environment `production` del repo `taskbot-infra`)

---

## 5. Microservicios

### 5.1 Tabla resumen

| Servicio | Puerto | Tipo | DB | Spring Security | Actuator | Probes |
|---|---|---|---|---|---|---|
| auth-service | 8082 | Spring Boot 3.3 JAR | ✅ | ✅ JWT | ✅ | HTTP /health/{liveness,readiness} |
| kpi-service | 8080 | Spring Boot 4.0 WAR | ✅ | ✅ JWT | ✅ | HTTP /health/{liveness,readiness} |
| ai-service | 8083 | Spring Boot 3.5 JAR | ✅ | ❌ | ✅ | HTTP /health/{liveness,readiness} |
| task-service | 8084 | Spring Boot JAR | ✅ | ❌ | ❌ | TCP socket |
| telegram-service | 8081 | Spring Boot JAR | ❌ | ❌ | ❌ | TCP socket |
| frontend | 80 | nginx (sirviendo SPA) | ❌ | ❌ | n/a | HTTP /healthz |

### 5.2 Detalles por servicio

#### auth-service

- **Paquete**: `dev.sammy_ulfh.authentication`
- **Imagen**: `ghcr.io/oracletelegrambot/taskbot-auth-service`
- **Endpoints públicos**: `/api/v1/auth/login`, `/api/v1/auth/register`
- **Spring Security**: JWT-based, permite paths de Swagger y Actuator en `permitAll()`
- **Variables de entorno principales**:
  - `JWT_SECRET` (via ESO)
  - `DB_ADMIN_USERNAME`, `DB_ADMIN_PASSWORD` (via ESO)
  - `WALLET_PASSWORD` (via ESO)
  - `ORACLE_WALLET_PATH=/app/Wallet`, `TNS_ADMIN=/app/Wallet`
- **Hosts el dropdown unificado de Swagger UI** (porque `/swagger-ui` y `/webjars` rutean aquí)

#### kpi-service

- **Paquete**: `dev.sammy_ulfh.kpi`
- **Tipo de artefacto**: WAR (Spring Boot ejecutable)
- **Endpoints**: `/api/kpis`
- **Mismas env vars que auth-service** (DB + JWT)
- **Nota especial**: Spring Boot 4.0, Spring Security 7.x

#### ai-service

- **Paquete**: `dev.sammy_ulfh.ai`
- **Endpoints**: `/api/ai`
- **Sin Spring Security** (acceso libre)
- **Variables únicas**:
  - `OPENAI_API_KEY` (via ESO)
  - Wallet + DB (como auth/kpi)

#### task-service

- **Paquete**: `dev.sammy_ulfh.tasks` (verificar)
- **Endpoints**: `/api/sprints`, `/api/tasks`
- **Sin Spring Security**
- **Variables únicas**:
  - `KPI_SERVICE_URL=http://kpi-service:8080` (llamadas Feign internas)
  - `CORS_ALLOWED_ORIGINS` (configurado para localhost + producción)
- **Probes TCP** porque no tiene Actuator

#### telegram-service

- **Paquete**: `dev.sammy_ulfh.telegram` (verificar)
- **Endpoints**: `/api/webhook/telegram` (POST de Telegram), `/api/anuncios`
- **Webhook URL registrada en Telegram**: `https://sammy-ulfh.dev/api/webhook/telegram`
- **No usa DB, no usa Spring Security**
- **Variables únicas**:
  - `TELEGRAM_BOT_TOKEN` (via ESO)
  - `FEIGN_CLIENT_CONFIG_KPI_SERVICE_URL=http://kpi-service:8080`
  - `AUTH_SERVICE_URL=http://auth-service:8082`

#### frontend

- **Imagen**: `ghcr.io/lilianaramosvz/taskbot-frontend`
- **Tecnología**: Vite + React, build static, servido por nginx
- **Endpoint salud**: `/healthz`
- **Fallback SPA**: nginx tiene `try_files $uri $uri/ /index.html` para react-router
- **Llamadas API**: directas a `https://sammy-ulfh.dev/api/...` (URL hardcoded)

### 5.3 Características comunes de los backend

Todos los servicios backend que usan DB (auth, kpi, ai, task) comparten:

#### InitContainer para wallet

Antes de que arranque el container principal, un initContainer:
1. Se autentica contra OCI usando instance principal del node
2. Descarga `Wallet_gestiondetareasbd_tp.zip` del bucket
3. Extrae el contenido a `/app/Wallet` (volumen compartido tipo `emptyDir`)
4. El container principal lo usa para conectar a la DB

#### Probes Liveness/Readiness divididos

Para tolerar caídas de DB:
- **Liveness** (`/actuator/health/liveness`): solo verifica que la JVM está viva. NO depende de DB.
- **Readiness** (`/actuator/health/readiness`): incluye check de DB. Si falla, el pod sale del pool del Service.

#### HikariCP no fail-fast

```properties
spring.datasource.hikari.initialization-fail-timeout=-1
```

El pool intenta conectarse pero si falla, no mata el contexto de Spring. La app arranca sin DB y lazy-mente intentará conectarse cuando lo necesite.

---

## 6. Routing y networking

### 6.1 DNS

| Host | Tipo | Valor | TTL |
|---|---|---|---|
| `sammy-ulfh.dev` | A | `163.192.133.25` | 300s (recomendado) |

El registro A apunta directamente a la IP pública del Load Balancer.

### 6.2 TLS

- **Proveedor**: ZeroSSL (DV)
- **Cert**: `sammy-ulfh.dev`
- **Validez**: 22-Abr-2026 al 21-Jul-2026 (90 días, renovable)
- **Archivo cargado**: `fullchain.crt` (incluye cert + cadena intermedia)
- **Almacenado en**: Secret `sammy-ulfh-dev-tls` namespace `ingress-nginx`
- **Configurado como default**: vía flag `--default-ssl-certificate` en el Ingress controller

> ⚠️ **Crítico**: el Secret DEBE contener el `fullchain.crt`, no solo el cert leaf. Sin la cadena, Telegram (y otros validadores estrictos) rechazan la conexión TLS aunque navegadores la acepten.

### 6.3 Rutas del Ingress

Cada Ingress (`ingress-blue.yaml` e `ingress-green.yaml`) define las siguientes rutas con `Host: sammy-ulfh.dev`:

| Path | pathType | Backend |
|---|---|---|
| `/api/v1/auth` | Prefix | auth-service:8082 |
| `/api/kpis` | Prefix | kpi-service:8080 |
| `/api/webhook/telegram` | Prefix | telegram-service:8081 |
| `/api/anuncios` | Prefix | telegram-service:8081 |
| `/api/ai` | Prefix | ai-service:8083 |
| `/api/sprints` | Prefix | task-service:8084 |
| `/api/tasks` | Prefix | task-service:8084 |
| `/swagger-ui-auth.html` | Exact | auth-service:8082 |
| `/swagger-ui-auth` | Prefix | auth-service:8082 |
| `/v3/api-docs/auth` | Prefix | auth-service:8082 |
| `/swagger-ui-kpi.html` | Exact | kpi-service:8080 |
| `/swagger-ui-kpi` | Prefix | kpi-service:8080 |
| `/v3/api-docs/kpi` | Prefix | kpi-service:8080 |
| `/swagger-ui-ai.html` | Exact | ai-service:8083 |
| `/swagger-ui-ai` | Prefix | ai-service:8083 |
| `/v3/api-docs/ai` | Prefix | ai-service:8083 |
| `/swagger-ui-task.html` | Exact | task-service:8084 |
| `/swagger-ui-task` | Prefix | task-service:8084 |
| `/v3/api-docs/task` | Prefix | task-service:8084 |
| `/swagger-ui-telegram.html` | Exact | telegram-service:8081 |
| `/swagger-ui-telegram` | Prefix | telegram-service:8081 |
| `/v3/api-docs/telegram` | Prefix | telegram-service:8081 |
| `/swagger-ui` | Prefix | auth-service:8082 (assets compartidos) |
| `/webjars` | Prefix | auth-service:8082 (assets compartidos) |
| `/` | Prefix | frontend:80 (catch-all, debe ir al final) |

> ⚠️ El orden importa: la regla `/` debe estar al **final**. Si va al principio, captura todas las requests y no llegan al backend.

### 6.4 Service mesh interno

Los servicios se descubren entre sí usando DNS de Kubernetes:

```
http://auth-service:8082
http://kpi-service:8080
http://ai-service:8083
http://task-service:8084
http://telegram-service:8081
http://frontend:80
```

Estos nombres resuelven dentro del mismo namespace (vs-blue OR vs-green). El cluster los ruta automáticamente al pod menos cargado.

### 6.5 CORS

Cada microservicio backend tiene una clase `CorsConfig.java` que lee la variable `CORS_ALLOWED_ORIGINS` (separada por comas).

**Orígenes permitidos**:
```
https://sammy-ulfh.dev
http://localhost:5173
http://localhost:4173
http://127.0.0.1:5173
```

Permite:
- Producción (browser → `sammy-ulfh.dev`)
- Desarrollo local con Vite (puerto 5173 default)
- Vite preview (puerto 4173)

---

## 7. Secrets y configuración

### 7.1 Diagrama del flujo de secrets

```
┌─────────────────┐          ┌──────────────────┐
│  OCI Vault      │  ESO     │  K8s Secret      │
│  6 secrets      │  sync    │  taskbot-secrets │
│  cifrados       │ ───────→ │  (cleartext B64) │
└─────────────────┘          └────────┬─────────┘
                                       │ envFrom
                                       ▼
                              ┌──────────────────┐
                              │ Pod env vars     │
                              │ JWT_SECRET=...   │
                              │ OPENAI_API_KEY=  │
                              │ ...              │
                              └──────────────────┘
```

### 7.2 Populación inicial de secrets en Vault

Los secrets se crean en Vault con un placeholder `REPLACE_ME` durante `terraform apply`. Después se actualizan manualmente:

#### Vía Console OCI
1. OCI Console → Identity & Security → Vault → seleccionar vault
2. Para cada secret, "Create new version" con el valor real

#### Vía CLI
```bash
SECRET_OCID=$(oci vault secret list \
  --compartment-id <compartment-ocid> \
  --name "JWT_SECRET" \
  --query 'data[0].id' --raw-output)

NEW_VALUE_B64=$(echo -n "valor-real-del-secret" | base64)

oci vault secret update-base64 \
  --secret-id "$SECRET_OCID" \
  --secret-content-content "$NEW_VALUE_B64"
```

#### Forzar sync de ESO
Si actualizas un secret en Vault, ESO lo detecta en su próximo intervalo de refresh (configurado en el ClusterExternalSecret). Para forzar sync inmediato:

```bash
kubectl annotate clusterexternalsecret taskbot-secrets \
  force-sync="$(date +%s)" --overwrite
```

### 7.3 ConfigMaps no-secret

`oci-config` (no contiene secretos):
```yaml
OS_NAMESPACE: ax5o32ww5jyq
WALLET_BUCKET: taskbot-wallet
WALLET_OBJECT: Wallet_gestiondetareasbd_tp.zip
```

Los pods lo referencian con `envFrom.configMapRef`.

---

## 8. CI/CD: Build y Deploy

### 8.1 Repositorios y sus workflows

| Repo | Workflow | Disparador | Resultado |
|---|---|---|---|
| `OracleTelegramBot/Backend` | `build.yml` | push a `main` o `develop` | Build de 5 imágenes a GHCR |
| `lilianaramosvz/admindeproyectos` | `build.yml` | push a `main` | Build de la imagen frontend |
| `OracleTelegramBot/taskbot-infra` | `deploy.yml` | manual (`workflow_dispatch`) | Deploy blue/green al cluster |

### 8.2 Build workflow del backend

Ubicación: `Backend/.github/workflows/build.yml`

**Inputs**:
- Disparado en push a `main` o `develop`
- Ignora cambios en `**.md`, `taskbot-backend/docker-compose.yml`, `.gitignore`

**Comportamiento**:
- Build paralelo de 5 servicios (matrix)
- Cada servicio se buildea con su `Dockerfile` en `taskbot-backend/<servicio>/`
- Imágenes etiquetadas con:
  - SHA del commit (siempre): `ghcr.io/oracletelegrambot/taskbot-<svc>:<sha>`
  - `latest` (si la rama es main)
  - `develop` (si la rama es develop)
- Plataforma: `linux/amd64`
- Cache: GitHub Actions cache scoped por servicio + branch

**Cómo ver builds**:
```bash
# Listar últimos runs
gh run list --repo OracleTelegramBot/Backend --workflow=build.yml --limit 5

# Ver detalle de un run
gh run view <run-id> --repo OracleTelegramBot/Backend
```

### 8.3 Build workflow del frontend

Ubicación: `admindeproyectos/.github/workflows/build.yml`

Mismo esquema, una sola imagen (`ghcr.io/lilianaramosvz/taskbot-frontend`).

### 8.4 Deploy workflow (blue/green)

Ubicación: `taskbot-infra/.github/workflows/deploy.yml`

**Inputs**:
- `image_tag` — qué tag deployar (default: `develop`)
- `target_color` — `auto` (default, detecta opuesto del activo), `blue` o `green`
- `skip_cutover` — si `true`, aplica pero no switchea Ingress

**Steps principales**:

1. **Checkout** del repo
2. **Install kubectl** v1.32.0
3. **Write kubeconfigs** desde secrets `OKE_KUBECONFIG_BLUE` y `OKE_KUBECONFIG_GREEN`
4. **Verify cluster connectivity** — falla loud si los kubeconfigs no funcionan
5. **Determine active and target colors** — detecta cuál Ingress existe
6. **Substitute IMAGE_TAG in target manifests** — reemplaza `:IMAGE_TAG` por el SHA/tag real
7. **Apply deployments to target color** — `kubectl apply` al namespace destino
8. **Wait for BACKEND rollouts** — bloquea 300s esperando que los 5 backend estén Ready
9. **Wait for FRONTEND rollout (non-blocking)** — 180s, no bloquea si falla
10. **Cutover (delete old, apply new)** — borra Ingress viejo, aplica nuevo
11. **Verify cutover** — muestra Ingress activo
12. **Post-cutover smoke tests** — curl a 11 endpoints, falla si hay 5xx
13. **Auto-rollback on smoke test failure** — revierte si los smoke tests fallaron
14. **Summary** — markdown con resumen del deploy

---

## 9. Flujo de deploy paso a paso

### 9.1 Desarrollo a producción (camino feliz)

```bash
# 1. Trabajas en una feature branch o develop
git checkout develop
git pull
# ... haces cambios ...
git commit -m "feat: nueva feature"
git push origin develop

# 2. Esperas ~10 min a que el build workflow termine
gh run watch --repo OracleTelegramBot/Backend
# O en GitHub UI: https://github.com/OracleTelegramBot/Backend/actions

# 3. Cuando termina, captura el SHA
NEW_SHA=$(git -C ../Backend rev-parse HEAD)
echo "Imagen lista: ghcr.io/oracletelegrambot/taskbot-auth-service:$NEW_SHA"

# 4. Disparas el deploy
gh workflow run deploy.yml --repo OracleTelegramBot/taskbot-infra \
  -f image_tag=$NEW_SHA \
  -f target_color=auto \
  -f skip_cutover=false

# 5. Captura el ID del run (para watch sin menu)
sleep 5
RUN_ID=$(gh run list --repo OracleTelegramBot/taskbot-infra \
  --workflow=deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId')

# 6. Monitorea el progreso
gh run watch $RUN_ID --repo OracleTelegramBot/taskbot-infra
```

### 9.2 ¿Qué pasa en cada step?

**Step 1: Detect colors**

El workflow consulta ambos namespaces:
```bash
KUBECONFIG=kc-blue kubectl get ingress taskbot -n vs-blue
KUBECONFIG=kc-green kubectl get ingress taskbot -n vs-green
```

Determina cuál está activo (tiene el Ingress) y cuál es target (el otro).

**Step 2-3: Substitute & apply**

```bash
sed -i "s|:IMAGE_TAG|:<sha-real>|g" infra/k8s/40-apps/10-deployments-<target>/*.yaml
kubectl apply -f infra/k8s/40-apps/10-deployments-<target>/
```

Esto crea/actualiza los Deployments del color destino. Kubernetes inicia un rolling update.

**Step 4: Wait rollouts**

```bash
for svc in auth kpi telegram ai task; do
  kubectl rollout status deployment/$svc -n vs-<target> --timeout=300s
done
```

Espera a que cada Deployment reporte que todos los pods nuevos están Ready. Si después de 5 min no llegan, el step falla y el workflow se detiene **antes del cutover** — producción intacta.

**Step 5: Cutover**

```bash
# Delete viejo
KUBECONFIG=kc-<active> kubectl delete ingress taskbot -n vs-<active>
sleep 5

# Apply nuevo
KUBECONFIG=kc-<target> kubectl apply -f ingress-<target>.yaml
sleep 10
```

Aproximadamente 5-10 segundos de "downtime" durante el switch. NGINX deja de tener el Ingress viejo y empieza a usar el nuevo.

**Step 6: Smoke tests**

11 curls a endpoints críticos:
- `/api/v1/auth/login`
- `/api/kpis`
- `/api/ai`
- `/api/sprints`
- `/v3/api-docs/{auth,kpi,ai,task,telegram}`
- `/swagger-ui/index.html`
- `/`

Cada respuesta:
- **2xx, 3xx, 4xx**: OK (el backend responde, aunque la request sea inválida)
- **5xx**: FAIL (backend roto)
- **Timeout**: FAIL (backend colgado)

Si CUALQUIER endpoint da 5xx o timeout, los smoke tests fallan y se dispara el rollback.

**Step 7 (condicional): Auto-rollback**

Solo se ejecuta si los smoke tests fallaron Y había un color activo previo:

```bash
# Borra el Ingress del color nuevo (roto)
kubectl delete ingress taskbot -n vs-<target>

# Re-aplica el Ingress del color viejo
kubectl apply -f ingress-<active>.yaml
```

El workflow termina con `exit 1` para señalar el fallo en GitHub Actions, pero **producción queda restaurada al estado anterior**.

### 9.3 Casos especiales

#### Primer deploy (no hay color activo)

`steps.colors.outputs.active == 'none'`. El workflow:
- Aplica al color default (blue) o al especificado
- No hay cutover de ingress (no había uno)
- Si smoke tests fallan, no hay rollback posible — termina con error

#### Re-deploy al mismo color activo

Si fuerzas `target_color=blue` cuando blue ya está activo:
- Se hace rolling update en blue
- No hay cutover de ingress
- Smoke tests se ejecutan igual

#### Skip cutover (validación)

Con `skip_cutover=true`:
- Se aplica al color destino
- Se esperan rollouts
- **NO se borra el ingress viejo ni se aplica el nuevo**
- Te quedan los pods nuevos corriendo en el color pasivo, accesibles solo vía `kubectl port-forward`
- Útil para probar antes de switchear tráfico real

---

## 10. Rollback

### 10.1 Tipos de rollback

| Tipo | Cuándo se dispara | Velocidad |
|---|---|---|
| **Auto-rollback de smoke tests** | Automático si los curls post-cutover dan 5xx | ~30 seg |
| **Rollback manual rápido** | Tú lo disparas si detectas un bug runtime | ~30-60 seg |
| **Rollback a versión más vieja** | Para volver a un SHA específico anterior | Tiempo de un deploy normal (~5-10 min) |

### 10.2 Rollback automático (smoke tests)

Es transparente. Si haces un deploy y los smoke tests fallan:

```
✓ Apply deployments
✓ Wait rollouts
✓ Cutover (delete old, apply new)
✗ Smoke tests (1+ endpoints respondió 5xx)
→ Auto-rollback (delete new ingress, re-apply old)
✗ Workflow termina con exit 1
```

Producción queda en el estado anterior. Investigas los pods del color que se quería deployar para entender qué pasó.

### 10.3 Rollback manual rápido (al color pasivo)

Si el deploy completó (smoke tests pasaron) pero después detectas un problema:

```bash
# 1. Ver qué color es el activo actual
kubectl get ingress -A | grep taskbot
# Ej: vs-blue

# 2. El color al que vas a revertir es el pasivo (vs-green en este ejemplo)
# Verifica qué versión está corriendo ahí (debería ser la anterior funcional)
kubectl get deployment -n vs-green -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.template.spec.containers[0].image}{"\n"}{end}'

# 3. Dispara el deploy forzando el color pasivo
gh workflow run deploy.yml --repo OracleTelegramBot/taskbot-infra \
  -f image_tag=develop \
  -f target_color=green \
  -f skip_cutover=false

# El workflow:
# - Detecta active=blue
# - Target forzado=green (donde están los pods funcionales)
# - Skip step de apply (los pods ya están corriendo con la versión vieja)
# - Hace cutover: borra ingress-blue, aplica ingress-green
# - Smoke tests sobre la versión vieja (deberían pasar)
```

### 10.4 Rollback a un SHA específico (no necesariamente el pasivo)

Si quieres volver a una versión arbitraria:

```bash
# 1. Encuentra el SHA en el historial
cd Backend
git log --oneline -20

# 2. Verifica que esa imagen sigue en GHCR
docker pull ghcr.io/oracletelegrambot/taskbot-auth-service:<sha-viejo>
# Si funciona, la imagen existe

# 3. Dispara el deploy con ese SHA
gh workflow run deploy.yml --repo OracleTelegramBot/taskbot-infra \
  -f image_tag=<sha-viejo> \
  -f target_color=auto \
  -f skip_cutover=false
```

> 💡 **Importante**: las imágenes en GHCR no se borran automáticamente, así que puedes volver a cualquier SHA que haya sido buildeado en algún momento.

---

## 11. Operaciones del día a día

### 11.1 Pre-requisitos del entorno local

```bash
# OCI CLI configurado
oci setup config

# kubectl configurado (genera kubeconfig una vez)
oci ce cluster create-kubeconfig \
  --cluster-id <cluster-ocid> \
  --file ~/.kube/config \
  --region mx-queretaro-1 \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT

export KUBECONFIG=~/.kube/config

# GitHub CLI
gh auth login
```

### 11.2 Comandos esenciales

#### Estado general del sistema

```bash
# ¿Qué color es el activo?
kubectl get ingress -A | grep taskbot

# Pods de ambos namespaces
kubectl get pods -A | grep -E "vs-blue|vs-green"

# Detalle del color activo
ACTIVE_NS=$(kubectl get ingress -A --no-headers | grep taskbot | awk '{print $1}')
kubectl get all -n $ACTIVE_NS

# Eventos recientes del cluster
kubectl get events -A --sort-by='.lastTimestamp' | tail -30
```

#### Logs

```bash
# Logs de un servicio (todos los pods)
kubectl logs -n $ACTIVE_NS -l app=auth-service --tail=100

# Logs en vivo
kubectl logs -n $ACTIVE_NS -l app=auth-service -f

# Logs del intento anterior (si el pod crasheó)
kubectl logs -n $ACTIVE_NS <pod-name> --previous --tail=100

# Logs del initContainer (descarga de wallet)
kubectl logs -n $ACTIVE_NS <pod-name> -c download-wallet
```

#### Probes y endpoints

```bash
# Health de un pod específico
POD=$(kubectl get pods -n $ACTIVE_NS -l app=auth-service -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $ACTIVE_NS $POD -- wget -qO- http://localhost:8082/actuator/health
kubectl exec -n $ACTIVE_NS $POD -- wget -qO- http://localhost:8082/actuator/health/liveness
kubectl exec -n $ACTIVE_NS $POD -- wget -qO- http://localhost:8082/actuator/health/readiness

# Endpoints del Service (qué pods están Ready)
kubectl get endpoints -n $ACTIVE_NS auth-service
```

#### Tests desde el exterior

```bash
# CORS preflight
curl -i -X OPTIONS https://sammy-ulfh.dev/api/v1/auth/login \
  -H "Origin: http://localhost:5173" \
  -H "Access-Control-Request-Method: POST"

# Swagger UI
curl -i https://sammy-ulfh.dev/swagger-ui/index.html

# JSON spec
curl -s https://sammy-ulfh.dev/v3/api-docs/auth | jq '.info'

# Health del LB (TLS chain)
echo | openssl s_client -connect sammy-ulfh.dev:443 -servername sammy-ulfh.dev \
  -showcerts 2>/dev/null | grep -c "BEGIN CERTIFICATE"
# Esperado: 2 o 3 (cadena completa)
```

#### Webhook de Telegram

```bash
TOKEN=$(kubectl get secret taskbot-secrets -n $ACTIVE_NS -o jsonpath='{.data.TELEGRAM_BOT_TOKEN}' | base64 -d)

# Estado del webhook
curl -s "https://api.telegram.org/bot${TOKEN}/getWebhookInfo" | jq

# Re-registrar webhook (si la IP cambió)
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://sammy-ulfh.dev/api/webhook/telegram",
    "drop_pending_updates": true
  }' | jq
```

### 11.3 URLs operativas

| Recurso | URL |
|---|---|
| App productiva | https://sammy-ulfh.dev |
| Swagger UI unificado | https://sammy-ulfh.dev/swagger-ui/index.html |
| Swagger por servicio | https://sammy-ulfh.dev/swagger-ui/index.html?urls.primaryName=`<auth\|kpi\|ai\|task\|telegram>` |
| Workflow runs (deploys) | https://github.com/OracleTelegramBot/taskbot-infra/actions |
| Workflow runs (builds backend) | https://github.com/OracleTelegramBot/Backend/actions |
| Workflow runs (builds frontend) | https://github.com/lilianaramosvz/admindeproyectos/actions |
| Imágenes Docker | https://github.com/orgs/OracleTelegramBot/packages |
| OCI Console (general) | https://cloud.oracle.com |
| Cost Analysis | https://cloud.oracle.com/account-management/cost-analysis |
| OKE Cluster | OCI Console → Developer Services → Kubernetes Clusters |

---

## 12. Troubleshooting

### 12.1 Síntoma: HTTP 503 Service Temporarily Unavailable

**Causa típica**: el Service del backend no tiene pods Ready.

**Diagnóstico**:
```bash
kubectl describe ingress taskbot -n $ACTIVE_NS | grep -A1 "auth-service\|kpi-service\|ai-service"
# Si ves "(  )" en vez de IPs → no hay endpoints

kubectl get endpoints -n $ACTIVE_NS
```

**Resolución**:
- Si los pods están en `CrashLoopBackOff`: ver §12.3
- Si los pods están `Running` pero `0/1` Ready: la readiness probe falla. Causa #1: DB caída.

### 12.2 Síntoma: la DB está apagada (operativo)

**Comportamiento esperado tras los cambios de resiliencia**:
- Pods siguen `Running`
- Readiness probe falla → `READY 0/1`
- NGINX responde 503 limpio (no timeouts)
- RESTARTS column no aumenta

**Acción**:
1. Pídele al equipo que tiene acceso a la DB que la encienda en OCI Console
2. Espera ~30-60 segundos
3. Los pods recuperan readiness automáticamente

**Verificación**:
```bash
kubectl get pods -n $ACTIVE_NS
# Esperado: READY 1/1, RESTARTS sin cambios
```

### 12.3 Síntoma: pods en CrashLoopBackOff

**Diagnóstico**:
```bash
# Log del último intento (puede estar vacío si recién se reinició)
kubectl logs -n $ACTIVE_NS <pod-name> --tail=100

# Log del intento ANTERIOR (donde está el error real)
kubectl logs -n $ACTIVE_NS <pod-name> --previous --tail=100

# Eventos del pod
kubectl describe pod -n $ACTIVE_NS <pod-name> | tail -30
```

**Causas comunes**:

| Mensaje en log | Causa | Acción |
|---|---|---|
| `ORA-12514: ... is not registered with the listener` | DB caída (ver §12.2) | Encender DB |
| `Could not resolve placeholder 'X'` | Falta env var | Verificar Deployment yaml y Secrets |
| `Connection refused` (a otro service) | Servicio interno no responde | Ver estado del otro servicio |
| `OutOfMemoryError` | Memory limit muy bajo | Subir `resources.limits.memory` |
| `Error: ImagePullBackOff` | Imagen no existe o no pública | Ver §12.5 |

### 12.4 Síntoma: nuevo deploy nunca completa los rollouts

**Síntoma**: el workflow falla en "Wait for BACKEND rollouts" después de 5 min.

**Diagnóstico**:
```bash
# Mira los pods nuevos del color destino
TARGET_NS=vs-green  # ajusta
kubectl get pods -n $TARGET_NS

# Si están en CrashLoopBackOff, sigue §12.3
# Si están en Pending, ver §12.7
# Si están en ImagePullBackOff, ver §12.5
```

**Importante**: como los rollouts fallaron, el cutover NO se ejecutó. Producción está intacta. Solo tienes pods rotos en el color destino que se pueden borrar:

```bash
kubectl delete pods -n $TARGET_NS --field-selector=status.phase!=Running
```

### 12.5 Síntoma: ImagePullBackOff

**Causas**:
1. La imagen no fue buildeada todavía (el workflow de build aún no terminó o falló)
2. El tag especificado no existe
3. La imagen está privada y no hay pull secret

**Diagnóstico**:
```bash
# Verifica que la imagen existe en GHCR
docker pull ghcr.io/oracletelegrambot/taskbot-auth-service:<sha>

# Si falla con "not found": el build no terminó. Espera o revisa el workflow:
gh run list --repo OracleTelegramBot/Backend --workflow=build.yml --limit 3

# Si falla con "denied" o "unauthorized": la imagen es privada
# Verifica en https://github.com/orgs/OracleTelegramBot/packages
# Hazla pública en Package settings → Change visibility
```

### 12.6 Síntoma: Telegram dejó de responder

**Diagnóstico #1**: Estado del webhook
```bash
TOKEN=$(kubectl get secret taskbot-secrets -n $ACTIVE_NS -o jsonpath='{.data.TELEGRAM_BOT_TOKEN}' | base64 -d)
curl -s "https://api.telegram.org/bot${TOKEN}/getWebhookInfo" | jq
```

**Errores típicos en `last_error_message`**:

| Error | Causa | Fix |
|---|---|---|
| `SSL error {certificate verify failed}` | Cadena TLS incompleta | Re-crear Secret con `fullchain.crt` (§12.10) |
| `Wrong response from the webhook: 502` | telegram-service caído | Ver pods, restart si necesario |
| `Wrong response from the webhook: 503` | telegram-service sin endpoints Ready | Ver §12.1 |
| `Connection timeout` | Network issue, LB no responde | Verificar LB en OCI Console |
| `Wrong response from the webhook: 404` | Path mal configurado en Ingress | Verificar `/api/webhook/telegram` en ingress |

**Re-registrar webhook**:
```bash
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://sammy-ulfh.dev/api/webhook/telegram",
    "drop_pending_updates": true
  }' | jq
```

**Logs del servicio**:
```bash
kubectl logs -n $ACTIVE_NS -l app=telegram-service -f
# Manda un mensaje al bot y mira si aparece el POST
```

### 12.7 Síntoma: pods en Pending

**Causa típica**: recursos insuficientes en los nodes.

**Diagnóstico**:
```bash
kubectl describe pod -n $ACTIVE_NS <pod-name> | grep -A5 "Events:"
# Buscar: "Insufficient cpu", "Insufficient memory", "FailedScheduling"

# Estado de los nodes
kubectl describe nodes | grep -E "Allocated|cpu|memory" | head -20
```

**Acción**:
- Si hay pods huérfanos de deploys anteriores en `ImagePullBackOff` u otros estados rotos, bórralos:
  ```bash
  kubectl delete pods -n $ACTIVE_NS --field-selector=status.phase!=Running
  ```
- Si los recursos están legítimamente llenos: bajar replicas temporalmente, o escalar nodos.

### 12.8 Síntoma: Swagger UI redirige al frontend

**Causa**: el Ingress activo no tiene las rules de Swagger.

**Diagnóstico**:
```bash
kubectl describe ingress taskbot -n $ACTIVE_NS | grep -E "swagger|v3/api-docs"
# Si no aparecen las rules → el Ingress es viejo, falta actualizar
```

**Fix**: re-deployar para que se aplique el Ingress nuevo.

### 12.9 Síntoma: CORS error en el browser

**Diagnóstico**:
```bash
# Verifica que el preflight responde con headers correctos
curl -i -X OPTIONS https://sammy-ulfh.dev/api/v1/auth/login \
  -H "Origin: http://localhost:5173" \
  -H "Access-Control-Request-Method: POST" 2>&1 | grep -i "access-control"
```

**Esperado**:
```
access-control-allow-origin: http://localhost:5173
access-control-allow-methods: GET, POST, PUT, PATCH, DELETE, OPTIONS
access-control-allow-credentials: true
```

**Si faltan headers**:
- Verificar que el pod tiene la env var `CORS_ALLOWED_ORIGINS` correcta:
  ```bash
  kubectl exec -n $ACTIVE_NS <pod> -- env | grep CORS
  ```
- Si la env var no incluye tu origen: actualizar el Deployment yaml y re-deployar.

### 12.10 Síntoma: error "certificate verify failed" (de Telegram u otros validadores estrictos)

**Causa**: el Secret de TLS tiene solo el cert leaf, no la cadena completa.

**Diagnóstico**:
```bash
echo | openssl s_client -connect sammy-ulfh.dev:443 -servername sammy-ulfh.dev \
  -showcerts 2>/dev/null | grep -c "BEGIN CERTIFICATE"
# Si devuelve 1 → cadena incompleta
# Si devuelve 2 o 3 → cadena OK
```

**Fix**:
```bash
# Confirma que tienes fullchain.crt
grep -c "BEGIN CERTIFICATE" infra/certs/fullchain.crt
# Esperado: 2 o 3

# Si solo tienes los archivos separados, constrúyelo:
cd infra/certs
cat certificate.crt ca_bundle.crt > fullchain.crt

# Re-crea el Secret
kubectl delete secret sammy-ulfh-dev-tls -n ingress-nginx
kubectl create secret tls sammy-ulfh-dev-tls \
  --cert=infra/certs/fullchain.crt \
  --key=infra/certs/private.key \
  -n ingress-nginx

# NGINX detecta automáticamente y recarga (~15 seg)
sleep 15

# Verifica
echo | openssl s_client -connect sammy-ulfh.dev:443 -servername sammy-ulfh.dev \
  -showcerts 2>/dev/null | grep -c "BEGIN CERTIFICATE"
```

### 12.11 Síntoma: el cert TLS está por vencer

El cert actual vence el **21 de Julio de 2026**. Renovación:

**Opción A: manual con ZeroSSL** (cada 90 días)
1. Loguearse a https://zerossl.com
2. Renovar el cert para `sammy-ulfh.dev`
3. Descargar `fullchain.crt` y `private.key`
4. Re-crear el Secret (ver §12.10)

**Opción B: cert-manager + Let's Encrypt** (renovación automática)
- Setup inicial: ~1 hora
- Después: cero mantenimiento

(Ver §14 para más detalles del roadmap.)

### 12.12 Síntoma: ambos Ingresses existen (split brain)

Si por algún motivo (interrupción del workflow, aplicación manual incorrecta) ambos namespaces tienen un Ingress activo simultáneamente:

```bash
kubectl get ingress -A | grep taskbot
# Si ves dos líneas (vs-blue y vs-green)...
```

NGINX se confunde y puede rutear inconsistentemente. **Borra uno manualmente**:

```bash
# Decide cuál mantener (el "bueno") y borra el otro
kubectl delete ingress taskbot -n vs-blue   # o vs-green
```

El próximo deploy automatizado va a detectar correctamente cuál es activo.

---

## 13. Procedimientos de emergencia

### 13.1 Rollback de emergencia

**Cuándo**: producción rota, necesitas volver a la última versión funcional YA.

```bash
# 1. Identifica el color activo
ACTIVE=$(kubectl get ingress -A --no-headers | grep taskbot | awk '{print $1}' | sed 's/vs-//')
OLD=$([[ "$ACTIVE" == "blue" ]] && echo "green" || echo "blue")
echo "Active: $ACTIVE → Rollback a: $OLD"

# 2. Dispara el rollback (forzando el color pasivo, que tiene la versión anterior)
gh workflow run deploy.yml --repo OracleTelegramBot/taskbot-infra \
  -f image_tag=develop \
  -f target_color=$OLD \
  -f skip_cutover=false

# 3. Verifica que el cutover sucedió
sleep 60
kubectl get ingress -A | grep taskbot
# Esperado: vs-$OLD ahora activo
```

**Tiempo estimado**: 1-3 minutos.

### 13.2 Limpieza del cluster (cuando los namespaces están sucios)

Si después de muchos deploys fallidos quedan ReplicaSets y pods huérfanos:

```bash
# Borrar pods broken
kubectl delete pods -n vs-blue --field-selector=status.phase!=Running
kubectl delete pods -n vs-green --field-selector=status.phase!=Running

# Borrar ReplicaSets viejos (sin pods activos)
for ns in vs-blue vs-green; do
  kubectl get rs -n $ns --no-headers | awk '$2==0 && $3==0 {print $1}' | xargs -r kubectl delete rs -n $ns
done
```

### 13.3 Reset completo de un color (cuando todo está catastrófico)

Si un namespace entero está corrupto:

```bash
TARGET=green  # o blue

# Borra TODO en ese namespace (excepto Services y ConfigMaps que son estables)
kubectl delete deployment --all -n vs-$TARGET
kubectl delete replicaset --all -n vs-$TARGET
kubectl delete pod --all -n vs-$TARGET --grace-period=0 --force
# Si el Ingress está corrupto:
kubectl delete ingress --all -n vs-$TARGET

# Re-aplica desde los manifests
kubectl apply -f infra/k8s/40-apps/10-deployments-$TARGET/

# (Nota: las Services y ConfigMaps no se tocaron, siguen ahí)

# Si quieres también re-aplicar el Ingress:
kubectl apply -f infra/k8s/40-apps/30-ingress/ingress-$TARGET.yaml
```

### 13.4 La DB está caída y no podemos contactar al equipo que tiene acceso

**Comportamiento esperado**:
- Pods siguen Running
- NGINX devuelve 503 a endpoints que necesitan DB
- Frontend sigue funcionando (no necesita DB)
- Webhook de Telegram sigue recibiendo (telegram-service no usa DB)

**Acción**: comunicar al usuario que el servicio está degradado, esperar a que se restablezca la DB. **No es necesario tocar el cluster**.

### 13.5 El LB se quedó sin IP / IP cambió

Si por algún motivo (recreación del cluster, intervención manual) la IP del Load Balancer cambia:

```bash
# Nueva IP
kubectl get svc -n ingress-nginx
# Anota la EXTERNAL-IP

# Actualiza el A record en el registrar de sammy-ulfh.dev
# El cambio propaga en ~5-60 min según TTL

# Re-registra el webhook de Telegram (también valida la nueva IP)
TOKEN=$(...)  # extraer del secret
curl -X POST "https://api.telegram.org/bot${TOKEN}/setWebhook" \
  -d '{"url":"https://sammy-ulfh.dev/api/webhook/telegram","drop_pending_updates":true}'
```

### 13.6 Reconstrucción desde cero (terraform destroy + apply)

Solo si la situación es catastrófica y vale la pena perder ~1 hora de re-setup manual.

**Antes de destroy** — backup crítico:
```bash
# 1. Guarda el wallet ZIP localmente (debes tenerlo)
ls -la ~/Downloads/Wallet*.zip

# 2. Documenta los valores de los 6 secrets en un gestor de contraseñas
#    (las copias actuales en Vault se borrarán con destroy)

# 3. Verifica que Terraform code está commiteado
cd taskbot-infra && git status
```

**Destroy**:
```bash
cd infra/terraform
terraform plan -destroy
terraform destroy  # confirma con 'yes', tarda ~10-15 min
```

**Reconstrucción**:
```bash
terraform apply  # tarda ~15-20 min

# Pasos manuales post-apply:
# 1. Re-popular Vault secrets con los valores guardados
# 2. Re-upload del wallet al bucket
# 3. Re-instalar charts de NGINX Ingress, ESO, etc.
# 4. Re-aplicar manifests K8s (ClusterStore, deployments, services, ingress)
# 5. Re-crear el Secret TLS con fullchain
# 6. Regenerar kubeconfigs y subir a GitHub Secrets
# 7. Actualizar DNS con la nueva IP del LB
# 8. Re-registrar webhook de Telegram
# 9. Disparar deploy workflow
```

Tiempo total: ~45-60 min.

---

## 14. Mejoras pendientes (roadmap)

Ideas para mejorar el sistema cuando haya tiempo:

### 14.1 Renovación automática de TLS

Setup de cert-manager + ClusterIssuer de Let's Encrypt:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: tu-email@ejemplo.com
    privateKeySecretRef:
      name: letsencrypt-prod-private-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

Y un `Certificate` resource:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: sammy-ulfh-dev-tls
  namespace: ingress-nginx
spec:
  secretName: sammy-ulfh-dev-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  commonName: sammy-ulfh.dev
  dnsNames:
    - sammy-ulfh.dev
```

cert-manager renueva automáticamente cuando faltan 30 días.

### 14.2 Monitoreo y alerting

**Opción ligera**: UptimeRobot o BetterStack pingeando `https://sammy-ulfh.dev/` cada 5 min. Email/Slack si baja.

**Opción robusta**: Prometheus + Grafana en el cluster. Métricas de:
- Latencia de endpoints
- Tasa de errores
- Uso de CPU/memoria por pod
- Estado de la DB (via custom probe)

### 14.3 Logs centralizados

Hoy los logs están solo en cada pod. Si un pod se reinicia, se pierden los logs viejos.

**Opción**: Loki + Promtail en el cluster, dashboards en Grafana.

### 14.4 Staging environment

Hoy: cluster productivo único. Cambios se prueban directamente con `skip_cutover=true`.

**Opción**: cluster aparte para staging, mismo deploy workflow con diferente kubeconfig.

### 14.5 Notificaciones de deploy

Agregar step al final del `deploy.yml` que mande mensaje a Slack/Telegram/Discord con resultado del deploy.

### 14.6 Autoscaling

`HorizontalPodAutoscaler` para escalar réplicas según CPU/RAM:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: auth-service-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: auth-service
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### 14.7 Frontend image en cuenta del org

Hoy la imagen del frontend está en `ghcr.io/lilianaramosvz/taskbot-frontend` (cuenta personal). Idealmente debería estar en `ghcr.io/oracletelegrambot/taskbot-frontend` para que todo el equipo pueda gestionarla.

Requiere: cambiar el workflow del frontend repo para que pushee al org.

### 14.8 Limpieza automática de ReplicaSets viejos

Cron job que cada noche borra RSs sin pods activos:

```bash
kubectl get rs -A --no-headers | awk '$3==0 && $4==0 {print $1, $2}' | xargs -L1 kubectl delete rs -n
```

---

## 15. Anexos

### 15.1 Estructura del repo `taskbot-infra`

```
taskbot-infra/
├── .github/
│   └── workflows/
│       └── deploy.yml                     # Workflow blue/green con auto-rollback
├── architecture/                          # Diagramas C4
├── images/
├── infra/
│   ├── certs/
│   │   ├── ca_bundle.crt                  # Intermedios
│   │   ├── certificate.crt                # Solo cert leaf
│   │   ├── fullchain.crt                  # Cert + intermedios (lo que se usa)
│   │   └── private.key
│   ├── k8s/
│   │   ├── 00-namespaces.yaml
│   │   ├── 10-ingress/
│   │   │   └── values.yaml                # Helm values de NGINX Ingress
│   │   ├── 20-cert-manager/               # (placeholder, no usado)
│   │   ├── 30-secrets/
│   │   │   ├── cluster-secret-store.yaml  # Conexión a OCI Vault
│   │   │   └── cluster-external-secret.yaml # Sync de los 6 secrets
│   │   └── 40-apps/
│   │       ├── 00-config/
│   │       │   └── oci-config.yaml        # ConfigMap con namespace/bucket/object
│   │       ├── 00-rbac/
│   │       │   ├── github-deployer-blue.yaml
│   │       │   └── github-deployer-green.yaml
│   │       ├── 10-deployments-blue/
│   │       │   ├── auth-service.yaml
│   │       │   ├── kpi-service.yaml
│   │       │   ├── telegram-service.yaml
│   │       │   ├── ai-service.yaml
│   │       │   ├── task-service.yaml
│   │       │   └── frontend.yaml
│   │       ├── 10-deployments-green/      # (espejo de blue)
│   │       ├── 20-services/               # 6 Services (uno por app)
│   │       └── 30-ingress/
│   │           ├── ingress-blue.yaml
│   │           └── ingress-green.yaml
│   ├── terraform/
│   │   ├── main.tf
│   │   ├── vault.tf
│   │   ├── iam.tf
│   │   ├── storage.tf
│   │   ├── network.tf
│   │   ├── oke.tf
│   │   └── variables.tf
│   └── short_tenancy.txt
├── scripts/
│   └── generate-kubeconfig.sh             # Genera kubeconfig por namespace
├── Plan_de_Accion_DevOps_TaskBot.md
├── README.md
└── taskbot-estado-proyecto.md
```

### 15.2 Glosario

| Término | Significado |
|---|---|
| **Blue/Green** | Patrón de deploy con dos environments idénticos, switcheas tráfico entre ellos |
| **Cutover** | Momento en que el tráfico cambia del color viejo al nuevo |
| **GHCR** | GitHub Container Registry — donde viven las imágenes Docker |
| **Ingress** | Recurso K8s que define reglas de routing HTTP/HTTPS |
| **Liveness probe** | Check que K8s usa para decidir si el pod está vivo (si falla → restart) |
| **NGINX Ingress** | Implementación de Ingress que usa NGINX como reverse proxy |
| **OKE** | Oracle Kubernetes Engine — el K8s managed de OCI |
| **Readiness probe** | Check para decidir si el pod puede recibir tráfico (si falla → sale del pool) |
| **ReplicaSet (RS)** | Recurso K8s que mantiene N réplicas de un pod corriendo |
| **Service** | Recurso K8s que da una IP virtual + DNS a un grupo de pods |
| **ESO** | External Secrets Operator — sincroniza secrets desde fuentes externas |
| **TNS** | Transparent Network Substrate — sistema de naming de Oracle DB |
| **Wallet** | Bundle de credenciales y certs para conectar a Oracle Autonomous DB |
| **SPA** | Single Page Application — el frontend con react-router |

### 15.3 Variables de entorno por servicio

#### auth-service
```
JWT_SECRET=<via ESO>
DB_ADMIN_USERNAME=<via ESO>
DB_ADMIN_PASSWORD=<via ESO>
WALLET_PASSWORD=<via ESO>
ORACLE_WALLET_PATH=/app/Wallet
TNS_ADMIN=/app/Wallet
CORS_ALLOWED_ORIGINS=https://sammy-ulfh.dev,http://localhost:5173,http://localhost:4173,http://127.0.0.1:5173
SPRING_PROFILES_ACTIVE=prod
```

#### kpi-service
```
(mismas que auth-service)
```

#### ai-service
```
OPENAI_API_KEY=<via ESO>
DB_ADMIN_USERNAME=<via ESO>
DB_ADMIN_PASSWORD=<via ESO>
WALLET_PASSWORD=<via ESO>
ORACLE_WALLET_PATH=/app/Wallet
TNS_ADMIN=/app/Wallet
CORS_ALLOWED_ORIGINS=https://sammy-ulfh.dev,http://localhost:5173,http://localhost:4173,http://127.0.0.1:5173
SPRING_PROFILES_ACTIVE=prod
```

#### task-service
```
DB_ADMIN_USERNAME=<via ESO>
DB_ADMIN_PASSWORD=<via ESO>
WALLET_PASSWORD=<via ESO>
ORACLE_WALLET_PATH=/app/Wallet
TNS_ADMIN=/app/Wallet
KPI_SERVICE_URL=http://kpi-service:8080
CORS_ALLOWED_ORIGINS=https://sammy-ulfh.dev,http://localhost:5173,http://localhost:4173,http://127.0.0.1:5173
SPRING_PROFILES_ACTIVE=prod
```

#### telegram-service
```
TELEGRAM_BOT_TOKEN=<via ESO>
AUTH_SERVICE_URL=http://auth-service:8082
FEIGN_CLIENT_CONFIG_KPI_SERVICE_URL=http://kpi-service:8080
SPRING_PROFILES_ACTIVE=prod
```

### 15.4 Resumen de imágenes Docker

| Servicio | Imagen | Tags disponibles |
|---|---|---|
| auth-service | `ghcr.io/oracletelegrambot/taskbot-auth-service` | `<sha>`, `latest`, `develop` |
| kpi-service | `ghcr.io/oracletelegrambot/taskbot-kpi-service` | `<sha>`, `latest`, `develop` |
| ai-service | `ghcr.io/oracletelegrambot/taskbot-ai-service` | `<sha>`, `latest`, `develop` |
| task-service | `ghcr.io/oracletelegrambot/taskbot-task-service` | `<sha>`, `latest`, `develop` |
| telegram-service | `ghcr.io/oracletelegrambot/taskbot-telegram-service` | `<sha>`, `latest`, `develop` |
| frontend | `ghcr.io/lilianaramosvz/taskbot-frontend` | `<sha>`, `latest` |

### 15.5 Comandos de referencia rápida

```bash
# === ESTADO ===
kubectl get ingress -A | grep taskbot                          # Color activo
kubectl get pods -A | grep -E "vs-blue|vs-green"               # Pods de la app
kubectl get events -A --sort-by='.lastTimestamp' | tail -20    # Eventos recientes

# === LOGS ===
ACTIVE_NS=$(kubectl get ingress -A --no-headers | grep taskbot | awk '{print $1}')
kubectl logs -n $ACTIVE_NS -l app=auth-service --tail=100 -f   # Logs en vivo

# === DEPLOY ===
gh workflow run deploy.yml --repo OracleTelegramBot/taskbot-infra \
  -f image_tag=$(git -C ../Backend rev-parse HEAD) \
  -f target_color=auto \
  -f skip_cutover=false

# === ROLLBACK RÁPIDO ===
OLD=$([[ "$(kubectl get ingress -A --no-headers | grep taskbot | awk '{print $1}')" == "vs-blue" ]] && echo "green" || echo "blue")
gh workflow run deploy.yml --repo OracleTelegramBot/taskbot-infra \
  -f image_tag=develop -f target_color=$OLD -f skip_cutover=false

# === WEBHOOK TELEGRAM ===
TOKEN=$(kubectl get secret taskbot-secrets -n $ACTIVE_NS -o jsonpath='{.data.TELEGRAM_BOT_TOKEN}' | base64 -d)
curl -s "https://api.telegram.org/bot${TOKEN}/getWebhookInfo" | jq

# === TLS CHECK ===
echo | openssl s_client -connect sammy-ulfh.dev:443 -servername sammy-ulfh.dev \
  -showcerts 2>/dev/null | grep -c "BEGIN CERTIFICATE"          # Esperado: 2 o 3

# === CORS CHECK ===
curl -i -X OPTIONS https://sammy-ulfh.dev/api/v1/auth/login \
  -H "Origin: http://localhost:5173" \
  -H "Access-Control-Request-Method: POST" 2>&1 | grep -i "access-control"
```

### 15.6 Contactos / responsables

| Recurso | Responsable / acceso |
|---|---|
| OCI Cuenta principal (cluster, vault, bucket) | Equipo TaskBot |
| OCI Cuenta de la DB | Otro miembro del equipo |
| Repo backend | `OracleTelegramBot/Backend` — admins del org |
| Repo frontend | `lilianaramosvz` — cuenta personal (limita acceso) |
| Repo infra | `OracleTelegramBot/taskbot-infra` |
| Bot de Telegram | Token en Vault, propietario del bot definido en BotFather |
| Dominio sammy-ulfh.dev | Registrar externo |

---

## Cierre

Este documento debería cubrir el ~95% de los casos operativos. Si encuentras un caso que no está aquí, agrégalo — la documentación viva es la documentación útil.

**Para futuros mantenedores**: el sistema fue diseñado con foco en:
1. **Reproducibilidad**: todo en Git, infra como código
2. **Resiliencia**: tolerante a fallos de DB
3. **Reversibilidad**: blue/green + auto-rollback
4. **Auditabilidad**: cada deploy queda en GitHub Actions con su SHA

Cualquier cambio que rompa estos principios debería pensarse dos veces.

---

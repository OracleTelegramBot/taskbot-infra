# TaskBot — Estado del proyecto y próximos pasos

> Documento de handoff. Captura el estado actual de la infraestructura, las decisiones tomadas, y los pasos específicos pendientes para tener la aplicación corriendo en producción con CI/CD automatizado.

---

## 0. Cómo usar este documento

Está estructurado en tres bloques principales:

1. **Contexto y decisiones** (§1-2): por qué el proyecto se ve como se ve. Incluye desviaciones del plan original.
2. **Lo que está hecho** (§3): inventario detallado con OCIDs, archivos y comandos de validación.
3. **Lo que falta** (§4): pasos accionables con código de ejemplo donde aplica.

Si vas a continuar en otra sesión de chat: pega este documento como contexto inicial y arranca desde el primer punto pendiente de §4.

---

## 1. Resumen ejecutivo

**Objetivo final**: aplicación de 5 microservicios Java + frontend Vite corriendo en OCI Kubernetes (OKE), con CI/CD automatizado vía GitHub Actions y despliegue Blue/Green, accesible públicamente en `https://sammy-ulfh.dev`.

**Estado actual**:
- ✅ Infraestructura cloud completa (compartment, red, OKE, vault, secrets, IAM)
- ✅ Cluster Kubernetes operativo con 2 worker nodes registrados
- ✅ Ingress Controller (NGINX) con Load Balancer público activo
- ✅ Certificado TLS (ZeroSSL) cargado en el cluster
- ✅ Sincronización automática de secretos OCI Vault → Kubernetes via ESO
- ⏳ Manifests de los microservicios (no escritos aún)
- ⏳ Pipelines de CI/CD (no escritos aún)
- ⏳ DNS apuntando al cluster (intencionalmente diferido, la VPS actual sigue sirviendo)
- ⏳ Valores reales en los secretos (todavía `REPLACE_ME`)

**Tiempo estimado para terminar**: 1-2 días de trabajo concentrado.

---

## 2. Contexto del proyecto

### 2.1 Qué es TaskBot

Sistema de gestión de tareas + bot de Telegram con integración de IA. Cinco microservicios Java (Spring Boot) más un frontend Vite. Base de datos en Oracle Autonomous Database (ATP).

| Microservicio      | Puerto | Tipo  | Propósito                                     |
|--------------------|--------|-------|-----------------------------------------------|
| `kpi-service`      | 8080   | WAR   | Métricas y KPIs                               |
| `telegram-service` | 8081   | JAR   | Integración con Telegram Bot API              |
| `auth-service`     | 8082   | JAR   | Autenticación con JWT                         |
| `ai-service`       | 8083   | JAR   | Llamadas a OpenAI gpt-4o-mini                 |
| `task-service`     | 8084   | JAR   | Lógica de tareas (CRUD principal)             |

**Imagen base de todos**: `eclipse-temurin:17-jre-alpine`
**Réplicas por servicio**: 2 (en cada namespace activo)

### 2.2 Arquitectura

```
Internet
   │
   ▼
DNS sammy-ulfh.dev  ──── (apuntará a la IP pública del LB cuando se haga cutover)
   │
   ▼
OCI Load Balancer (creado por NGINX Service tipo LoadBalancer)
   │
   ▼
NGINX Ingress Controller (namespace: ingress-nginx)
   │ termina TLS aquí usando el cert de ZeroSSL
   │
   ▼
Services en namespace activo (vs-blue o vs-green)
   │
   ▼
Pods de los 5 microservicios (2 réplicas cada uno)
   │
   ▼
Oracle Autonomous DB (gestiondetareasbd_tp) ← conexión via Service Gateway
External: OpenAI API, Telegram Bot API ← salida via NAT Gateway
```

**Estrategia de despliegue Blue/Green**:
- Dos namespaces espejo: `vs-blue` y `vs-green`
- Solo uno tiene tráfico real en cada momento
- El deploy va al inactivo, se valida (manualmente por ahora, sin testing automático), y luego se mueve el tráfico cambiando una regla del Ingress
- El namespace que era activo queda como "rollback target"

### 2.3 Decisiones que divergen del plan original

Estas decisiones se tomaron durante la implementación y vale la pena documentarlas:

1. **Testing automatizado eliminado del scope**. El plan original incluía un repo `taskbot-tests` con suite pytest + integración con Jira para abrir tickets al fallar. Se cortó por simplicidad. El usuario ya tiene un proyecto Python con `runner.py` que corre tests contra una VPS vía SSH — se integrará al pipeline en una fase posterior si se desea.

2. **Cert-manager + Let's Encrypt reemplazado por ZeroSSL manual**. El usuario ya tenía certificados de ZeroSSL para `sammy-ulfh.dev`. Se cargan como Secret tipo TLS en Kubernetes y se renuevan manualmente cada 90 días. Cert-manager NO se instaló. Si en el futuro se quiere auto-renovación, se puede instalar después.

3. **OCI Vault tipo DEFAULT + master key SOFTWARE**. Ambos GRATIS (vs VIRTUAL_PRIVATE + HSM que cuesta ~$1500/mes + $22/mes por key). Apropiado para este nivel de proyecto.

4. **OKE cluster tipo BASIC**. Control plane gratuito. ENHANCED suma Workload Identity, Virtual Nodes y gestión de add-ons — no las necesitamos.

5. **CNI Flannel overlay** en vez de VCN-Native. Más simple, los pods viven en CIDR separado (10.244.0.0/16) y no consumen IPs de la VCN.

6. **External Secrets Operator (ESO) con Instance Principal** para sincronizar OCI Vault → K8s Secrets. Los pods consumen `Secret` nativos como cualquier app, sin SDK de OCI ni initContainers.

7. **Security Lists con `lifecycle.ignore_changes`** en vez de NSGs. El OCI Cloud Controller Manager modifica las security lists dinámicamente cuando crea LoadBalancers; con `ignore_changes` Terraform no se pelea con él.

8. **Trabajo solo (no equipo de 4 personas)**. Las menciones a "Persona 1/2/3/4" del plan original no aplican.

---

## 3. Infraestructura completada

### 3.1 Terraform — repo `taskbot-infra`

**Provider**: `oracle/oci` ~> 8.0
**Terraform version**: >= 1.5.0
**Auth**: lee de `~/.oci/config` profile `DEFAULT` (no hay credenciales en `terraform.tfvars`)
**Región**: `mx-queretaro-1`

**Estructura de archivos**:

```
taskbot-infra/
├── infra/
│   ├── versions.tf           # providers oci ~> 8.0 + time ~> 0.11
│   ├── main.tf               # provider config con config_file_profile
│   ├── variables.tf          # variables del proyecto
│   ├── terraform.tfvars      # solo project_name, env, region, parent_compartment_ocid (no commitear)
│   ├── iam.tf                # compartment + 3 policies + dynamic group
│   ├── network.tf            # VCN, subnets, gateways, security lists (con ignore_changes)
│   ├── oke.tf                # cluster + node pool + outputs
│   └── vault.tf              # vault + master key + 5 secretos + time_sleep
└── infra/k8s/
    ├── 00-namespaces.yaml
    ├── 10-ingress/values.yaml
    ├── 30-secrets/cluster-secret-store.yaml
    └── 30-secrets/cluster-external-secret.yaml
```

`.gitignore` debe incluir: `terraform.tfvars`, `*.tfstate*`, `.terraform/`, `.terraform.lock.hcl`, `*.tfplan`, `*.pem`.

#### Recursos creados (con OCIDs reales del entorno actual)

| Recurso                     | Nombre                          | OCID / Identificador                                                                                                                                       |
|-----------------------------|---------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Compartment                 | `taskbot-compartment`           | `ocid1.compartment.oc1..aaaaaaaasc7skqcllhtzaohqv2ee4c7qznox74hxo6bftrknasa232p2lloq`                                                                       |
| VCN                         | `taskbot-vcn`                   | CIDR `10.0.0.0/16`, DNS label `taskbot`                                                                                                                    |
| Subnet pública              | `taskbot-public-subnet`         | CIDR `10.0.0.0/24` — Load Balancers + K8s API endpoint                                                                                                     |
| Subnet privada              | `taskbot-private-subnet`        | CIDR `10.0.1.0/24` — worker nodes (sin IPs públicas)                                                                                                       |
| Internet Gateway            | `taskbot-igw`                   | salida internet desde subnet pública                                                                                                                       |
| NAT Gateway                 | `taskbot-nat`                   | salida internet desde subnet privada                                                                                                                       |
| Service Gateway             | `taskbot-sgw`                   | acceso interno a servicios OCI                                                                                                                             |
| Cluster OKE                 | `taskbot-oke-cluster`           | `ocid1.cluster.oc1.mx-queretaro-1.aaaaaaaa57t3v7twgvozft4r3xtrqrb7rvul7hftblbcmy3hbcbb7xrpyd6a` <br> Kubernetes v1.36.0, endpoint público `159.54.144.242:6443` |
| Node pool                   | `taskbot-oke-nodepool`          | 2× `VM.Standard.E3.Flex`, 2 OCPU + 16 GB RAM cada uno                                                                                                      |
| Vault                       | `taskbot-vault`                 | `ocid1.vault.oc1.mx-queretaro-1.ibvb7hzyaad46.abyxeljrwokl5rntglkq3px2rhn5fpypmscevlyv6nwtblwd3tweucxryo6q` <br> tipo DEFAULT, gratis                       |
| Master Key                  | `taskbot-master-key`            | AES-256, protection mode SOFTWARE                                                                                                                          |
| Secretos                    | 5 con prefijo `taskbot-`        | `jwt-secret`, `openai-api-key`, `telegram-bot-token`, `db-admin-username`, `db-admin-password` <br> contenido placeholder `REPLACE_ME` con `ignore_changes` |
| Dynamic Group               | `taskbot-oke-nodes-dg`          | match: instancias compute en el compartment de taskbot                                                                                                     |
| Políticas IAM               | 3 policies                      | `taskbot-oke-service-policy`, `taskbot-oke-nodes-vault-access` (read vaults + read secret-family + use keys)                                              |

#### Variables clave de Terraform (defaults en `variables.tf`)

```hcl
region                  = "mx-queretaro-1"
project_name            = "taskbot"
environment             = "prod"
vcn_cidr                = "10.0.0.0/16"
public_subnet_cidr      = "10.0.0.0/24"
private_subnet_cidr     = "10.0.1.0/24"
node_shape              = "VM.Standard.E3.Flex"
node_ocpus              = 2
node_memory_gb          = 16
node_count              = 2
parent_compartment_ocid = "<tu tenancy OCID>"   # único valor en tfvars
```

#### Outputs (en `oke.tf` y `vault.tf`)

- `oke_cluster_id`
- `oke_cluster_endpoint`
- `vault_id`
- `secret_ocids` (mapa nombre → OCID de los 5 secretos)

**Nota**: en la sesión actual `terraform output` reportó "No outputs found" en algún momento — si vuelve a pasar, usar `terraform state show oci_kms_vault.taskbot | grep "^\s*id\s"` o pedir vía OCI CLI.

#### Patrones aprendidos durante el setup

- **OCI Vault DNS race condition**: al crear un vault, su `management_endpoint` tarda 1-3 min en propagar DNS. Por eso `vault.tf` tiene un `time_sleep` de 120s entre la creación del vault y la creación de la master key (requiere provider `time`).
- **OKE 12250 requirement**: el registro de worker nodes contra el control plane no es solo por puerto 6443, también necesita 12250 abierto desde la subnet privada. Por eso el security list pública tiene un ingress `all TCP` desde `vcn_cidr`.
- **Imágenes OKE incompatibles entre shapes**: las imágenes Oracle-Linux-OKE vienen en 4 variantes (x86_64 estándar, aarch64, Gen2-GPU, OL 7.9). El filtro en `oke.tf` selecciona la estándar para E3.Flex con regex que excluye `aarch64` y `GPU`.
- **OCI CCM modifica security lists dinámicamente**: cuando creas Services tipo LoadBalancer, el OCI Cloud Controller Manager (que vive dentro del cluster) abre puertos NodePort en las security lists. Por eso `network.tf` tiene `lifecycle.ignore_changes` en las dos security lists.
- **Compartment cleanup en OCI**: los compartments no se borran de inmediato con `terraform destroy`; quedan en estado `DELETED` durante ~6 min. Si re-creas con el mismo nombre durante ese tiempo, error 409.
- **IAM permission boundary**: el policy del Dynamic Group para acceso al Vault necesita `read vaults` (sobre el recurso vault), `read secret-family` (sobre secretos) Y `use keys` (para descifrar). Faltarle uno hace que ESO falle.

### 3.2 Kubernetes

Todo en `taskbot-infra/infra/k8s/`.

#### Namespaces

`00-namespaces.yaml` aplicado. Ambos namespaces tienen label `project: taskbot` (clave para que el ClusterExternalSecret los seleccione).

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vs-blue
  labels:
    project: taskbot
    environment: prod
    color: blue
---
apiVersion: v1
kind: Namespace
metadata:
  name: vs-green
  labels:
    project: taskbot
    environment: prod
    color: green
```

#### NGINX Ingress Controller

Instalado vía Helm en namespace `ingress-nginx`. Archivo `10-ingress/values.yaml`:

```yaml
controller:
  replicaCount: 2
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/oci-load-balancer-shape: "flexible"
      service.beta.kubernetes.io/oci-load-balancer-shape-flex-min: "10"
      service.beta.kubernetes.io/oci-load-balancer-shape-flex-max: "100"
  publishService:
    enabled: true
  livenessProbe:
    initialDelaySeconds: 10
    periodSeconds: 10
  readinessProbe:
    initialDelaySeconds: 5
    periodSeconds: 10
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits: { cpu: 500m, memory: 512Mi }
```

Comando de instalación usado:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f 10-ingress/values.yaml
```

El Service `ingress-nginx-controller` tiene una IP pública asignada — es la que se usará para apuntar el DNS al hacer cutover. Recuperable con `kubectl get svc -n ingress-nginx`.

#### TLS Cert (ZeroSSL)

Cargado como Secret tipo TLS en namespace `ingress-nginx`:

```bash
cat certificate.crt ca_bundle.crt > fullchain.crt
kubectl create secret tls sammy-ulfh-dev-tls \
  --cert=fullchain.crt --key=private.key \
  -n ingress-nginx
```

**Nombre del Secret**: `sammy-ulfh-dev-tls`
**Vigencia**: 90 días (renovar manualmente)

Para renovar:
```bash
kubectl create secret tls sammy-ulfh-dev-tls \
  --cert=fullchain-new.crt --key=private-new.key \
  -n ingress-nginx \
  --dry-run=client -o yaml | kubectl apply -f -
```

#### External Secrets Operator (ESO)

Instalado en namespace `external-secrets`:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set installCRDs=true
```

#### ClusterSecretStore (puente ESO ↔ OCI Vault)

`30-secrets/cluster-secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: oci-vault
spec:
  provider:
    oracle:
      vault: ocid1.vault.oc1.mx-queretaro-1.ibvb7hzyaad46.abyxeljrwokl5rntglkq3px2rhn5fpypmscevlyv6nwtblwd3tweucxryo6q
      region: mx-queretaro-1
      principalType: InstancePrincipal
```

Estado actual: `STATUS: Valid, READY: True`.

#### ClusterExternalSecret (sincroniza los 5 secretos en ambos namespaces)

`30-secrets/cluster-external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterExternalSecret
metadata:
  name: taskbot-secrets
spec:
  externalSecretName: taskbot-secrets
  namespaceSelector:
    matchLabels:
      project: taskbot
  externalSecretSpec:
    refreshInterval: 5m
    secretStoreRef:
      kind: ClusterSecretStore
      name: oci-vault
    target:
      name: taskbot-secrets
      creationPolicy: Owner
    data:
      - secretKey: jwt-secret
        remoteRef: { key: taskbot-jwt-secret }
      - secretKey: openai-api-key
        remoteRef: { key: taskbot-openai-api-key }
      - secretKey: telegram-bot-token
        remoteRef: { key: taskbot-telegram-bot-token }
      - secretKey: db-admin-username
        remoteRef: { key: taskbot-db-admin-username }
      - secretKey: db-admin-password
        remoteRef: { key: taskbot-db-admin-password }
```

**Resultado**: Secret `taskbot-secrets` (tipo Opaque, 5 keys) presente en `vs-blue` y `vs-green`. ESO re-sincroniza cada 5 min. Forzar sync inmediato:

```bash
kubectl annotate clusterexternalsecret taskbot-secrets force-sync="$(date +%s)" --overwrite
```

---

## 4. Lo que falta

### 4.1 Poblar valores reales en OCI Vault

**Estado actual**: los 5 secretos tienen valor `REPLACE_ME` (base64).
**Trabajo**: 10 min, manual en la consola de OCI.

**Pasos**:

1. Consola OCI → menú hamburguesa → *Identity & Security → Vault* → `taskbot-vault` → tab *Secrets*.
2. Para cada secreto, click → *Create New Version* → seleccionar *Plain-Text* → pegar el valor real → *Create*.
3. Valores requeridos:
   - `taskbot-jwt-secret`: cadena random ≥32 chars. Generar con `openssl rand -base64 48`.
   - `taskbot-openai-api-key`: API key real de OpenAI (empieza con `sk-...`).
   - `taskbot-telegram-bot-token`: token de @BotFather.
   - `taskbot-db-admin-username`: usuario admin de la Autonomous DB.
   - `taskbot-db-admin-password`: password admin de la Autonomous DB.

ESO propaga los nuevos valores a Kubernetes en máximo 5 min (o forzar con `kubectl annotate clusterexternalsecret taskbot-secrets force-sync="$(date +%s)" --overwrite`).

**Validar**:
```bash
kubectl get secret taskbot-secrets -n vs-blue -o jsonpath='{.data.jwt-secret}' | base64 -d
```

### 4.2 Oracle Wallet para la Autonomous Database

**Contexto**: para conectar a OCI ATP, los servicios Java necesitan un Wallet (zip con certs TLS y `tnsnames.ora`). En el plan: montado en `/app/Wallet` de cada pod.

**Estrategia recomendada**: subir el zip a OCI Object Storage y descargar al pod vía initContainer.

#### Pasos:

**A. Descargar el Wallet de OCI:**
1. Consola OCI → *Oracle Database → Autonomous Database* → `gestiondetareasbd_tp` → botón *Database Connection* → *Download Wallet* → asignar password al wallet → descargar `Wallet_gestiondetareasbd_tp.zip`.

**B. Crear bucket de Object Storage** (puede ser via Terraform, agregar a `taskbot-infra/infra/`):

```hcl
# storage.tf
resource "oci_objectstorage_bucket" "wallet" {
  compartment_id = oci_identity_compartment.taskbot.id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "${local.name_prefix}-wallet"
  access_type    = "NoPublicAccess"
  freeform_tags  = local.common_tags
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = oci_identity_compartment.taskbot.id
}
```

Y agregar al policy del dynamic group (en `iam.tf`):

```hcl
"Allow dynamic-group ${oci_identity_dynamic_group.oke_nodes.name} to read objects in compartment ${oci_identity_compartment.taskbot.name} where target.bucket.name='${local.name_prefix}-wallet'",
```

**C. Subir el wallet:**
```bash
oci os object put \
  --bucket-name taskbot-wallet \
  --name Wallet_gestiondetareasbd_tp.zip \
  --file ./Wallet_gestiondetareasbd_tp.zip
```

**D. Agregar el password del wallet al Vault**:
- Nuevo secreto `taskbot-wallet-password`
- Agregar al `local.secrets` en `vault.tf`
- Agregar al `ClusterExternalSecret` con key `wallet-password`

**E. initContainer en los deployments** (ver §4.3 ejemplo).

### 4.3 Manifests de aplicación

**Ubicación**: `taskbot-infra/infra/k8s/40-apps/`

#### Estructura sugerida

```
40-apps/
├── 00-rbac.yaml                   # ServiceAccount + RoleBinding para CI/CD (§4.4)
├── 10-deployments-blue/
│   ├── ai-service.yaml
│   ├── auth-service.yaml
│   ├── kpi-service.yaml
│   ├── task-service.yaml
│   ├── telegram-service.yaml
│   └── frontend.yaml
├── 10-deployments-green/          # idem pero con namespace: vs-green
│   └── ...
├── 20-services/
│   └── (uno por microservicio, en ambos namespaces)
└── 30-ingress/
    ├── ingress-blue.yaml
    └── ingress-green.yaml         # solo uno aplicado a la vez
```

#### Template de Deployment (ejemplo: auth-service en vs-blue)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service
  namespace: vs-blue
  labels:
    app: auth-service
    color: blue
spec:
  replicas: 2
  selector:
    matchLabels:
      app: auth-service
  template:
    metadata:
      labels:
        app: auth-service
        color: blue
    spec:
      # initContainer descarga el Wallet de OCI Object Storage
      initContainers:
        - name: download-wallet
          image: ghcr.io/oracle/oci-cli:latest
          command:
            - /bin/sh
            - -c
            - |
              oci os object get \
                --auth instance_principal \
                --bucket-name taskbot-wallet \
                --name Wallet_gestiondetareasbd_tp.zip \
                --file /wallet/wallet.zip
              cd /wallet && unzip wallet.zip && rm wallet.zip
          volumeMounts:
            - name: wallet
              mountPath: /wallet

      containers:
        - name: auth-service
          image: ghcr.io/<org>/taskbot-auth-service:<tag>
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8082
          envFrom:
            - secretRef:
                name: taskbot-secrets    # los 5 secretos como env vars
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: "prod"
            - name: TNS_ADMIN
              value: "/app/Wallet"
          volumeMounts:
            - name: wallet
              mountPath: /app/Wallet
              readOnly: true
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits: { cpu: 1000m, memory: 1Gi }
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8082
            initialDelaySeconds: 60
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8082
            initialDelaySeconds: 30
            periodSeconds: 10

      volumes:
        - name: wallet
          emptyDir: {}

      # Para que GitHub Actions pueda pullear imágenes privadas de GHCR
      imagePullSecrets:
        - name: ghcr-pull-secret
```

**Nota sobre imagePullSecrets**: hay que crear un Secret `ghcr-pull-secret` en cada namespace con credenciales de GHCR. Comando:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-personal-access-token> \
  -n vs-blue

# Repetir para vs-green
```

El PAT necesita scope `read:packages`.

#### Template de Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: auth-service
  namespace: vs-blue
spec:
  type: ClusterIP
  selector:
    app: auth-service
  ports:
    - port: 8082
      targetPort: 8082
      protocol: TCP
```

Mapeo puertos:
| Service           | Puerto |
|-------------------|--------|
| kpi-service       | 8080   |
| telegram-service  | 8081   |
| auth-service      | 8082   |
| ai-service        | 8083   |
| task-service      | 8084   |
| frontend          | 80 (o 3000 según el build de Vite) |

#### Template de Ingress (con TLS y rutas por path)

El Secret TLS está en namespace `ingress-nginx`. Para que un Ingress en `vs-blue` lo use, hay 3 opciones:

1. **Copiar el secret a vs-blue/vs-green** (duplicado, simple).
2. **Usar el patrón "edge ingress"**: un Ingress en `ingress-nginx` que enrute a Services de otros namespaces vía `ExternalName` o `kubernetes.io/ingress.class`. Más limpio pero más complejo.
3. **Usar `nginx.ingress.kubernetes.io/default-ssl-certificate`** del controller para hacer del `sammy-ulfh-dev-tls` el cert por defecto del cluster — entonces cualquier Ingress lo puede referenciar sin duplicar.

**Recomendación**: opción 3 (default-ssl-certificate). Actualizar `values.yaml` del controller:

```yaml
controller:
  # ... lo que ya hay ...
  extraArgs:
    default-ssl-certificate: "ingress-nginx/sammy-ulfh-dev-tls"
```

Re-deploy:
```bash
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx -f 10-ingress/values.yaml
```

Después el Ingress queda simple:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: taskbot-ingress
  namespace: vs-blue
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - sammy-ulfh.dev
      # No se pone secretName porque el controller usa el default
  rules:
    - host: sammy-ulfh.dev
      http:
        paths:
          - path: /api/auth
            pathType: Prefix
            backend:
              service:
                name: auth-service
                port:
                  number: 8082
          - path: /api/ai
            pathType: Prefix
            backend:
              service:
                name: ai-service
                port:
                  number: 8083
          - path: /api/kpi
            pathType: Prefix
            backend:
              service:
                name: kpi-service
                port:
                  number: 8080
          - path: /api/task
            pathType: Prefix
            backend:
              service:
                name: task-service
                port:
                  number: 8084
          - path: /api/telegram
            pathType: Prefix
            backend:
              service:
                name: telegram-service
                port:
                  number: 8081
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 80
```

**El traffic switch Blue/Green se hace cambiando este único recurso**: solo un Ingress activo a la vez, en `vs-blue` O en `vs-green`. La forma más simple es aplicar/eliminar el Ingress del namespace inactivo.

### 4.4 RBAC para GitHub Actions

**Objetivo**: que el workflow de Deploy en GitHub Actions pueda hacer `kubectl apply` sobre `vs-blue` y `vs-green` sin tener kubeconfig de admin.

`00-rbac.yaml`:

```yaml
# ServiceAccount al que se le va a generar el kubeconfig
apiVersion: v1
kind: ServiceAccount
metadata:
  name: github-actions-deployer
  namespace: vs-blue   # se crea uno por cada namespace, o uno cluster-wide
---
# Mismo SA en vs-green
apiVersion: v1
kind: ServiceAccount
metadata:
  name: github-actions-deployer
  namespace: vs-green
---
# Role: qué puede hacer dentro de cada namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
  namespace: vs-blue
rules:
  - apiGroups: ["", "apps", "networking.k8s.io"]
    resources: ["deployments", "services", "ingresses", "pods", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
  namespace: vs-green
rules:
  - apiGroups: ["", "apps", "networking.k8s.io"]
    resources: ["deployments", "services", "ingresses", "pods", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
# Binding: vincular SA al Role
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer-binding
  namespace: vs-blue
subjects:
  - kind: ServiceAccount
    name: github-actions-deployer
    namespace: vs-blue
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer-binding
  namespace: vs-green
subjects:
  - kind: ServiceAccount
    name: github-actions-deployer
    namespace: vs-green
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
```

#### Generar el kubeconfig para GitHub Actions

En K8s 1.24+, los Secret de token para ServiceAccount no se crean automáticamente. Hay que crearlos manualmente:

```yaml
# Agregar al 00-rbac.yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-actions-deployer-token
  namespace: vs-blue
  annotations:
    kubernetes.io/service-account.name: github-actions-deployer
type: kubernetes.io/service-account-token
```

Después, generar el kubeconfig:

```bash
SA_TOKEN=$(kubectl get secret github-actions-deployer-token -n vs-blue -o jsonpath='{.data.token}' | base64 -d)
CA_CERT=$(kubectl get secret github-actions-deployer-token -n vs-blue -o jsonpath='{.data.ca\.crt}')
CLUSTER_ENDPOINT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

cat > github-actions-kubeconfig.yaml <<EOF
apiVersion: v1
kind: Config
clusters:
- name: taskbot-oke
  cluster:
    certificate-authority-data: ${CA_CERT}
    server: ${CLUSTER_ENDPOINT}
contexts:
- name: github-actions
  context:
    cluster: taskbot-oke
    user: github-actions-deployer
    namespace: vs-blue
current-context: github-actions
users:
- name: github-actions-deployer
  user:
    token: ${SA_TOKEN}
EOF
```

Guardar el contenido de `github-actions-kubeconfig.yaml` como GitHub Secret llamado `OKE_KUBECONFIG`.

### 4.5 GitHub Actions — Build workflow

**Ubicación**: `taskbot-backend/.github/workflows/build.yml` (asumiendo monorepo) o uno por servicio.

**Disparador**: push a `main` que toque archivos del servicio.

```yaml
name: Build & Push

on:
  push:
    branches: [main]
    paths:
      - 'services/**'
      - '.github/workflows/build.yml'

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        service: [ai-service, auth-service, kpi-service, task-service, telegram-service, frontend]
    permissions:
      contents: read
      packages: write   # para pushear a GHCR

    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build & push ${{ matrix.service }}
        uses: docker/build-push-action@v5
        with:
          context: ./services/${{ matrix.service }}
          platforms: linux/amd64   # E3.Flex es x86_64; si fueras ARM sería linux/arm64
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/taskbot-${{ matrix.service }}:${{ github.sha }}
            ghcr.io/${{ github.repository_owner }}/taskbot-${{ matrix.service }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

**Cosas importantes**:
- Las imágenes en GHCR son privadas por default. Para que los pods las puedan pullear, hay que crear el imagePullSecret (ya descrito en §4.3).
- El tag `${{ github.sha }}` es lo que el Deploy workflow va a usar para detectar cambios (immutable, único por commit).

### 4.6 GitHub Actions — Deploy workflow (Blue/Green)

**Ubicación**: `taskbot-infra/.github/workflows/deploy.yml` (en el repo de infra).

**Disparador**: push de tags `v*` (release tags), o manual via workflow_dispatch.

**Estrategia**: detectar namespace activo, deployar al inactivo, aprobación manual, traffic shift.

```yaml
name: Deploy (Blue/Green)

on:
  workflow_dispatch:
    inputs:
      image_tag:
        description: 'Tag de imágenes a desplegar (commit SHA)'
        required: true

jobs:
  detect-active:
    runs-on: ubuntu-latest
    outputs:
      active: ${{ steps.detect.outputs.active }}
      inactive: ${{ steps.detect.outputs.inactive }}
    steps:
      - uses: azure/setup-kubectl@v4
        with:
          version: 'latest'

      - name: Set kubeconfig
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.OKE_KUBECONFIG }}" > ~/.kube/config

      - id: detect
        name: Detect active color
        run: |
          # Busca el Ingress activo (asumiendo que solo existe uno a la vez)
          if kubectl get ingress taskbot-ingress -n vs-blue 2>/dev/null; then
            echo "active=blue" >> $GITHUB_OUTPUT
            echo "inactive=green" >> $GITHUB_OUTPUT
          else
            echo "active=green" >> $GITHUB_OUTPUT
            echo "inactive=blue" >> $GITHUB_OUTPUT
          fi

  deploy-inactive:
    needs: detect-active
    runs-on: ubuntu-latest
    env:
      INACTIVE: ${{ needs.detect-active.outputs.inactive }}
      IMAGE_TAG: ${{ github.event.inputs.image_tag }}
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-kubectl@v4

      - name: Set kubeconfig
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.OKE_KUBECONFIG }}" > ~/.kube/config

      - name: Substituir image tag en manifests
        run: |
          sed -i "s|:<tag>|:${IMAGE_TAG}|g" infra/k8s/40-apps/10-deployments-${INACTIVE}/*.yaml

      - name: Apply manifests al namespace inactivo
        run: |
          kubectl apply -f infra/k8s/40-apps/10-deployments-${INACTIVE}/
          kubectl apply -f infra/k8s/40-apps/20-services/   # idempotente

      - name: Esperar a que todos los pods estén Ready
        run: |
          kubectl rollout status deployment -n vs-${INACTIVE} --timeout=5m

  approve-traffic-shift:
    needs: [detect-active, deploy-inactive]
    runs-on: ubuntu-latest
    environment: production-approval   # configura este environment en GitHub con required reviewers
    steps:
      - run: echo "Aprobado por humano. Procediendo al traffic shift."

  switch-traffic:
    needs: [detect-active, approve-traffic-shift]
    runs-on: ubuntu-latest
    env:
      ACTIVE: ${{ needs.detect-active.outputs.active }}
      INACTIVE: ${{ needs.detect-active.outputs.inactive }}
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-kubectl@v4

      - name: Set kubeconfig
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.OKE_KUBECONFIG }}" > ~/.kube/config

      - name: Aplicar Ingress en el nuevo namespace activo
        run: kubectl apply -f infra/k8s/40-apps/30-ingress/ingress-${INACTIVE}.yaml

      - name: Eliminar Ingress del antiguo activo (ahora idle)
        run: kubectl delete ingress taskbot-ingress -n vs-${ACTIVE} --ignore-not-found

      - name: Confirmación
        run: |
          echo "Tráfico ahora en vs-${INACTIVE}"
          echo "vs-${ACTIVE} queda como rollback target hasta el próximo deploy"
```

**GitHub Secrets necesarios**:
- `OKE_KUBECONFIG`: el kubeconfig generado en §4.4
- `GITHUB_TOKEN`: automático

**Aprobación manual**: configurar un *Environment* llamado `production-approval` en *Settings → Environments* con required reviewers.

### 4.7 DNS cutover

**Cuándo hacerlo**: cuando los puntos §4.1 a §4.6 estén funcionando y haya tráfico real validado en el cluster (puedes probar antes editando el `/etc/hosts` local para apuntar `sammy-ulfh.dev` a la IP del LB del cluster).

**Pasos**:

1. Obtener la IP pública del LB:
   ```bash
   kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```

2. En el registrar del dominio, actualizar el registro A:
   ```
   @   A   <IP_del_LB>
   *   A   <IP_del_LB>      # wildcard, cubre cualquier subdominio
   ```

3. Esperar propagación (5-30 min usualmente):
   ```bash
   dig +short sammy-ulfh.dev
   dig +short api.sammy-ulfh.dev
   ```

4. Validar HTTPS:
   ```bash
   curl -v https://sammy-ulfh.dev
   ```

5. Apagar la VPS antigua una vez que el cluster esté sirviendo tráfico real estable por 24-48h.

---

## 5. Referencia rápida

### Comandos clave

```bash
# Estado del cluster
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get svc -n ingress-nginx

# Validar ESO
kubectl get clustersecretstore oci-vault
kubectl get clusterexternalsecret taskbot-secrets
kubectl get secrets -n vs-blue
kubectl get secrets -n vs-green

# Forzar resync de secretos
kubectl annotate clusterexternalsecret taskbot-secrets force-sync="$(date +%s)" --overwrite

# Regenerar kubeconfig si se pierde
oci ce cluster create-kubeconfig \
  --cluster-id ocid1.cluster.oc1.mx-queretaro-1.aaaaaaaa57t3v7twgvozft4r3xtrqrb7rvul7hftblbcmy3hbcbb7xrpyd6a \
  --file ~/.kube/config \
  --region mx-queretaro-1 \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT

# Terraform desde la raíz del módulo
terraform plan
terraform apply
terraform state list
terraform state show <recurso>
```

### Tooling versions usadas

- Terraform: `>= 1.5.0`
- OCI Terraform provider: `~> 8.0`
- time provider: `~> 0.11`
- Kubernetes: `v1.36.0` (OKE)
- Helm: cualquier 3.x
- OCI CLI: instalado vía venv de Python (`pip install oci-cli`)

### OCI Auth en local

Configurado vía `oci setup config` → `~/.oci/config` profile `DEFAULT` + llave privada en `~/.oci/oci_api_key.pem`. Terraform lo lee con `provider "oci" { config_file_profile = "DEFAULT" }`.

### Cuando muevas Terraform a CI/CD

Necesitarás un step bash que genere `~/.oci/config` desde GitHub Secrets antes de correr terraform:

```bash
mkdir -p ~/.oci
echo "${{ secrets.OCI_PRIVATE_KEY }}" > ~/.oci/oci_api_key.pem
chmod 600 ~/.oci/oci_api_key.pem

cat > ~/.oci/config <<EOF
[DEFAULT]
user=${{ secrets.OCI_USER_OCID }}
fingerprint=${{ secrets.OCI_FINGERPRINT }}
tenancy=${{ secrets.OCI_TENANCY_OCID }}
region=mx-queretaro-1
key_file=~/.oci/oci_api_key.pem
EOF
```

Y mover el state a OCI Object Storage con backend `s3` para que sea compartido entre runs.

### Mantenimiento periódico

| Tarea                                  | Frecuencia            |
|----------------------------------------|-----------------------|
| Renovar cert ZeroSSL                   | Cada 90 días          |
| Rotar JWT secret                       | Cada 6 meses o on-demand |
| Actualizar OKE a versión K8s superior  | Cada 4-6 meses        |
| Revisar facturación OCI                | Mensual               |
| Validar backups de la Autonomous DB    | Trimestral            |

---

## Apéndice: Glosario de OCIDs y valores reales

| Variable                     | Valor                                                                                                                                                       |
|------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Compartment OCID             | `ocid1.compartment.oc1..aaaaaaaasc7skqcllhtzaohqv2ee4c7qznox74hxo6bftrknasa232p2lloq`                                                                        |
| Cluster OKE OCID             | `ocid1.cluster.oc1.mx-queretaro-1.aaaaaaaa57t3v7twgvozft4r3xtrqrb7rvul7hftblbcmy3hbcbb7xrpyd6a`                                                              |
| Vault OCID                   | `ocid1.vault.oc1.mx-queretaro-1.ibvb7hzyaad46.abyxeljrwokl5rntglkq3px2rhn5fpypmscevlyv6nwtblwd3tweucxryo6q`                                                  |
| API server endpoint público  | `159.54.144.242:6443`                                                                                                                                       |
| Región                       | `mx-queretaro-1`                                                                                                                                            |
| Dominio                      | `sammy-ulfh.dev`                                                                                                                                            |
| Base de datos                | Oracle Autonomous Database `gestiondetareasbd_tp`                                                                                                           |
| Imagen base de microservicios| `eclipse-temurin:17-jre-alpine`                                                                                                                             |
| Container registry           | `ghcr.io/<github-org>/taskbot-<service-name>`                                                                                                               |
| TLS secret name              | `sammy-ulfh-dev-tls` (en namespace `ingress-nginx`)                                                                                                          |
| App secret name              | `taskbot-secrets` (en `vs-blue` y `vs-green`, 5 keys)                                                                                                       |

---

*Documento generado al cierre de la sesión de implementación de infraestructura. Última verificación: cluster `Ready`, ESO sincronizando, 5 K8s Secrets presentes en ambos namespaces.*

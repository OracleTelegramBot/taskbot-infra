# Diagramas C4 — TaskBot (vista rápida en GitHub)

> Estos diagramas en **Mermaid** se renderizan automáticamente al abrir este archivo en GitHub.
> Son una capa de visualización cómoda; el artefacto de arquitectura formal es el modelo
> **Structurizr** (`model.dsl` + `model.json`), que se renderiza con Structurizr Lite (ver `README.md`).

---

## 1. System Landscape

Panorama de TaskBot en su ecosistema: actores, el sistema y los servicios externos (incluida la plataforma de CI/CD).

```mermaid
flowchart TB
    admin([Admin])
    pm([Project Manager])
    dev([Developer])

    taskbot["TaskBot<br/>Plataforma de gestión de tareas Scrum"]

    openai["OpenAI API"]
    telegram["Telegram Bot API"]
    jira["Jira"]
    cicd["CI/CD Platform<br/>GitHub Actions + GHCR"]

    admin --> taskbot
    pm --> taskbot
    dev --> taskbot
    taskbot -->|"recomendaciones IA"| openai
    taskbot -->|"notificaciones"| telegram
    taskbot -->|"tickets de fallo"| jira
    cicd -->|"construye y despliega"| taskbot
```

---

## 2. System Context

TaskBot como caja negra: quién lo usa y con qué sistemas externos interactúa en tiempo de ejecución.

```mermaid
flowchart TB
    admin([Admin])
    pm([Project Manager])
    dev([Developer])

    taskbot["TaskBot<br/>Plataforma de gestión de tareas Scrum"]

    openai["OpenAI API<br/>gpt-4o-mini"]
    telegram["Telegram Bot API"]
    jira["Jira · proyecto TASKBOT"]

    admin -->|"registra usuarios y roles"| taskbot
    pm -->|"gestiona proyectos, sprints y KPIs"| taskbot
    dev -->|"gestiona tareas, Kanban y chatbot"| taskbot
    taskbot -->|"prompt con contexto"| openai
    taskbot -->|"sendMessage"| telegram
    taskbot -->|"crea tickets Bug"| jira
```

---

## 3. Containers

Contenedores internos de TaskBot: SPA, API Gateway, los 5 microservicios y la base de datos.

```mermaid
flowchart TB
    admin([Admin])
    pm([Project Manager])
    dev([Developer])

    subgraph TaskBot["TaskBot"]
        spa["Single Page Application<br/>React + Vite / Nginx"]
        ingress{{"API Gateway<br/>NGINX Ingress Controller"}}
        auth["auth-service<br/>Spring Boot · :8082"]
        task["task-service<br/>Spring Boot · :8084"]
        kpi["kpi-service<br/>Spring Boot WAR · :8080"]
        ai["ai-service<br/>Spring Boot · :8083"]
        tg["telegram-service<br/>Spring Boot · :8081"]
        db[("Oracle Autonomous DB<br/>gestiondetareasbd_tp")]
    end

    openai["OpenAI API"]
    telegram["Telegram Bot API"]

    admin --> spa
    pm --> spa
    dev --> spa
    spa -->|"HTTPS/JSON"| ingress
    ingress -->|"/api/v1/auth"| auth
    ingress -->|"/api/tasks · /api/sprints"| task
    ingress -->|"/api catch-all"| kpi
    ingress -->|"/api/ai"| ai
    ingress -->|"/api/webhook/telegram"| tg
    auth --> db
    task --> db
    kpi --> db
    ai --> db
    task -->|"REST Feign"| kpi
    task -->|"REST"| tg
    ai -->|"REST · contexto"| task
    ai -->|"completions"| openai
    tg -->|"sendMessage"| telegram
```

---

## 4. Components — `task-service`

El `task-service` aloja dos bounded contexts de Sprint 1: **Task Management** y **Project & Sprint**.

```mermaid
flowchart TB
    ingress{{"API Gateway"}}
    ai["ai-service"]
    kpi["kpi-service"]
    tg["telegram-service"]
    db[("Oracle ATP")]

    subgraph task["task-service"]
        tc["TaskController"]
        ts["TaskService<br/>(Task Management)"]
        sc["SprintController"]
        ss["SprintService<br/>(Project / Sprint)"]
        tr["TaskRepository"]
        sr["SprintRepository"]
        kc["KpiFeignClient"]
    end

    ingress -->|"/api/tasks"| tc
    ingress -->|"/api/sprints"| sc
    ai -->|"contexto"| tc
    tc --> ts
    sc --> ss
    ts --> tr
    ss --> sr
    ts -->|"tarea completada"| kc
    kc -->|"REST Feign"| kpi
    ts -->|"tarea bloqueada"| tg
    ss -->|"sprint por vencer"| tg
    tr --> db
    sr --> db
```

---

## 5. Deployment — OCI / OKE (namespace activo `vs-blue`)

```mermaid
flowchart TB
    subgraph github["GitHub"]
        gha["GitHub Actions<br/>Build + Deploy"]
        ghcr["GHCR<br/>ghcr.io/&lt;org&gt;/taskbot"]
    end

    subgraph oci["OCI · región mx-queretaro-1"]
        lb["Production Load Balancer"]
        subgraph oke["OKE Cluster · taskbot-oke-cluster"]
            subgraph ingns["ns: ingress-nginx"]
                ingc{{"NGINX Ingress Controller"}}
            end
            subgraph vsblue["ns: vs-blue · activo · 2 réplicas c/u"]
                fe["frontend"]
                auth["auth-service"]
                task["task-service"]
                kpi["kpi-service"]
                ai["ai-service"]
                tg["telegram-service"]
                cfg["Secrets y ConfigMap<br/>oracle-wallet → /app/Wallet"]
            end
        end
        atp[("Oracle ATP<br/>gestiondetareasbd_tp")]
        subgraph obs["OCI Observability"]
            fn["fn-jira-ticket-creator"]
        end
    end

    openai["OpenAI API"]
    telegram["Telegram Bot API"]
    jira["Jira"]

    gha -->|"docker push"| ghcr
    gha -->|"kubectl apply"| oke
    lb --> ingc
    ingc --> vsblue
    auth --> atp
    task --> atp
    kpi --> atp
    ai --> atp
    ai -->|"completions"| openai
    tg -->|"sendMessage"| telegram
    fn -->|"crea ticket Bug"| jira
```

---

## 6. Dynamic — Caso de uso: recomendación del chatbot de IA

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant SPA as SPA
    participant GW as API Gateway
    participant AI as ai-service
    participant TASK as task-service
    participant OAI as OpenAI API

    Dev->>SPA: Escribe una consulta en lenguaje natural
    SPA->>GW: POST /api/ai/chat
    GW->>AI: Enruta la consulta
    AI->>TASK: GET contexto de tareas y sprints activos
    TASK-->>AI: Contexto del proyecto
    AI->>OAI: Prompt con el contexto
    OAI-->>AI: Recomendación generada
    AI-->>SPA: Respuesta
    SPA-->>Dev: Muestra la recomendación
```

---

## 7. Dynamic — Caso de uso: tarea bloqueada → notificación a Telegram

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant SPA as SPA
    participant GW as API Gateway
    participant TASK as task-service
    participant TG as telegram-service
    participant TEL as Telegram Bot API

    Dev->>SPA: Cambia el estado de una tarea a Blocked
    SPA->>GW: PUT /api/tasks/{id}/status
    GW->>TASK: Actualiza el estado
    TASK->>TG: Notifica la tarea bloqueada
    TG->>TEL: sendMessage()
    TEL-->>TG: 200 OK
    TG-->>TASK: Notificación enviada
    TASK-->>SPA: Estado actualizado
```

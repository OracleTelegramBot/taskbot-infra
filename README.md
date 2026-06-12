# TaskBot — Infraestructura y Arquitectura

Repositorio de infraestructura como código (Terraform) y documentación de arquitectura del sistema **TaskBot**: una plataforma de gestión de tareas tipo Scrum con tablero Kanban, KPIs y chatbot de IA.

El sistema se compone de cinco microservicios Java desplegados sobre **Oracle Container Engine for Kubernetes (OKE)** en la región `mx-queretaro-1`, con CI/CD orquestado por **GitHub Actions** e imágenes almacenadas en **GitHub Container Registry (GHCR)**.

---

## Tabla de contenidos

- [Diagramas de arquitectura (modelo C4)](#diagramas-de-arquitectura-modelo-c4)
  - [1. System Landscape](#1-system-landscape)
  - [2. System Context](#2-system-context)
  - [3. Container Diagram](#3-container-diagram)
  - [4. Component Diagram — task-service](#4-component-diagram--task-service)
- [Arquitectura de despliegue (DevOps)](#arquitectura-de-despliegue-devops)
- [Vistas dinámicas (casos de uso)](#vistas-dinámicas-casos-de-uso)
  - [UC01 — Consulta al chatbot](#uc01--consulta-al-chatbot)
  - [UC02 — Tarea bloqueada](#uc02--tarea-bloqueada)
- [Documentación adicional](#documentación-adicional)

---

## Diagramas de arquitectura (modelo C4)

La arquitectura del sistema se documenta siguiendo el **modelo C4** de Simon Brown. Cada nivel ofrece una vista con mayor grado de detalle: desde el panorama general del ecosistema (Landscape) hasta los componentes internos de un microservicio específico (Component).

Los diagramas fueron generados con [Structurizr](https://structurizr.com/) y exportados como PNG.

---

### 1. System Landscape

Vista del ecosistema completo en el que opera TaskBot: usuarios del sistema, sistemas externos con los que interactúa y plataforma de CI/CD que lo construye y despliega.

<p align="center">
  <img src="images/Landscape.png" alt="System Landscape Diagram" width="900">
</p>

<details>
<summary><b>Leyenda</b></summary>

<p align="center">
  <img src="images/Landscape-key.png" alt="Landscape legend" width="700">
</p>
</details>

---

### 2. System Context

Vista enfocada en TaskBot como sistema central, mostrando los actores que lo utilizan (Developer, Project Manager, Admin) y los sistemas externos con los que se integra (OpenAI API, Telegram Bot API).

<p align="center">
  <img src="images/Context.png" alt="System Context Diagram" width="900">
</p>

<details>
<summary><b>Leyenda</b></summary>

<p align="center">
  <img src="images/Context-key.png" alt="Context legend" width="700">
</p>
</details>

---

### 3. Container Diagram

Descomposición del sistema en sus contenedores ejecutables: la Single Page Application, el API Gateway (NGINX Ingress Controller), los cinco microservicios Spring Boot y la base de datos Oracle Autonomous.

<p align="center">
  <img src="images/Containers.png" alt="Container Diagram" width="900">
</p>

<details>
<summary><b>Leyenda</b></summary>

<p align="center">
  <img src="images/Containers-key.png" alt="Containers legend" width="700">
</p>
</details>

---

### 4. Component Diagram — task-service

Vista interna del microservicio `task-service`, que muestra sus componentes principales: controladores REST (`TaskController`, `SprintController`), servicios de lógica de negocio (`TaskService`, `SprintService`), repositorios de acceso a datos (`TaskRepository`, `SprintRepository`) y el cliente Feign hacia `kpi-service`.

<p align="center">
  <img src="images/Components.png" alt="Component Diagram" width="900">
</p>

<details>
<summary><b>Leyenda</b></summary>

<p align="center">
  <img src="images/Components-key.png" alt="Components legend" width="700">
</p>
</details>

---

## Arquitectura de despliegue (DevOps)

Diagrama de alto nivel del pipeline de CI/CD y la infraestructura de despliegue: desde el `git push` del desarrollador hasta la actualización de los pods en el cluster OKE, incluyendo la integración con servicios externos (Autonomous DB, OpenAI, Telegram) y la observabilidad nativa de OCI.

<p align="center">
  <img src="images/Infraestructure_Diagram.png" alt="DevOps Architecture" width="900">
</p>

---

## Vistas dinámicas (casos de uso)

Las vistas dinámicas muestran el flujo de interacción entre contenedores para casos de uso específicos del sistema.

### UC01 — Consulta al chatbot

Flujo en el que un Developer realiza una consulta en lenguaje natural al chatbot de IA. La petición atraviesa el SPA, el API Gateway y el `ai-service`, que recupera contexto desde `task-service` antes de enviar el prompt a OpenAI.

<p align="center">
  <img src="images/uc01_chatbot.png" alt="UC01 - Consulta al chatbot" width="900">
</p>

<details>
<summary><b>Leyenda</b></summary>

<p align="center">
  <img src="images/uc01_chatbot-key.png" alt="UC01 legend" width="700">
</p>
</details>

---

### UC02 — Tarea bloqueada

Flujo en el que un Developer cambia el estado de una tarea a `Blocked`. El `task-service` detecta el cambio y notifica al `telegram-service`, que envía una alerta al canal del equipo en Telegram.

<p align="center">
  <img src="images/uc02_blocked_task.png" alt="UC02 - Tarea bloqueada" width="900">
</p>

<details>
<summary><b>Leyenda</b></summary>

<p align="center">
  <img src="images/uc02_blocked_task-key.png" alt="UC02 legend" width="700">
</p>
</details>

---

## Documentación adicional

| Documento | Descripción |
|---|---|
| [`Plan_de_Accion_DevOps_TaskBot.md`](./Plan_de_Accion_DevOps_TaskBot.md) | Documentación detallada de la arquitectura DevOps: infraestructura OCI, configuración de Kubernetes, pipeline CI/CD, estrategia Blue/Green, observabilidad y migración a producción |
| [`architecture/`](./architecture) | Definición de la arquitectura en Structurizr DSL |
---

## Sprint 5 — Nivel 4 (Código): Generación automática de diagramas de clases

Esta entrega automatiza la generación del Nivel 4 (Code) del modelo C4 para el contenedor `task-service`, manteniendo la documentación de arquitectura sincronizada con el código fuente mediante el pipeline de CI/CD. Se actualizó el modelo para reflejar el código real (renombres de `TaskRepository` a `TareaRepository`, `KpiFeignClient` a `KpiServiceClient`, y se agregaron componentes faltantes).

### Funcionamiento

1. El plugin `plantuml-generator-maven-plugin` lee las clases compiladas de `task-service` y genera un archivo `.puml` por cada componente del Nivel 3.
2. Un workflow de GitHub Actions regenera los diagramas en cada push que modifique código Java de `task-service` y los commitea automáticamente al repositorio.
3. Cada componente del Nivel 3 en `model.dsl` incluye la propiedad `url` apuntando a su diagrama de clases, navegable desde Structurizr con doble click.

### Ubicación de los entregables

| Entregable | Ubicación |
|---|---|
| Configuración del plugin (build config) | [`task-service/pom.xml`](https://github.com/OracleTelegramBot/Backend/blob/develop/taskbot-backend/task-service/pom.xml) — repo Backend |
| Pipeline de generación | [`architecture-diagrams.yml`](https://github.com/OracleTelegramBot/Backend/blob/develop/.github/workflows/architecture-diagrams.yml) — repo Backend |
| Diagramas generados (`.puml`) | [`docs/diagrams/`](https://github.com/OracleTelegramBot/Backend/tree/develop/docs/diagrams) — repo Backend |
| DSL con componentes enlazados | [`architecture/model.dsl`](./architecture/model.dsl) — este repositorio |

### Diagramas de clases generados (Nivel 4)

<!-- Renderizados en vivo desde los .puml del repo Backend vía proxy de PlantUML. Se actualizan automáticamente cuando el pipeline regenera los archivos. -->

#### TaskService

<p align="center">
  <img src="http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/OracleTelegramBot/Backend/develop/docs/diagrams/task-service-TaskService.puml" alt="TaskService Class Diagram" width="900">
</p>

#### TaskController

<p align="center">
  <img src="http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/OracleTelegramBot/Backend/develop/docs/diagrams/task-service-TaskController.puml" alt="TaskController Class Diagram" width="900">
</p>

#### SprintController

<p align="center">
  <img src="http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/OracleTelegramBot/Backend/develop/docs/diagrams/task-service-SprintController.puml" alt="SprintController Class Diagram" width="900">
</p>

#### TareaRepository

<p align="center">
  <img src="http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/OracleTelegramBot/Backend/develop/docs/diagrams/task-service-TareaRepository.puml" alt="TareaRepository Class Diagram" width="900">
</p>

#### SprintRepository

<p align="center">
  <img src="http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/OracleTelegramBot/Backend/develop/docs/diagrams/task-service-SprintRepository.puml" alt="SprintRepository Class Diagram" width="900">
</p>

#### RegistroHorasRepository

<p align="center">
  <img src="http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/OracleTelegramBot/Backend/develop/docs/diagrams/task-service-RegistroHorasRepository.puml" alt="RegistroHorasRepository Class Diagram" width="900">
</p>

#### UsuarioTareaRepository

<p align="center">
  <img src="http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/OracleTelegramBot/Backend/develop/docs/diagrams/task-service-UsuarioTareaRepository.puml" alt="UsuarioTareaRepository Class Diagram" width="900">
</p>

#### KpiServiceClient

<p align="center">
  <img src="http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/OracleTelegramBot/Backend/develop/docs/diagrams/task-service-KpiServiceClient.puml" alt="KpiServiceClient Class Diagram" width="900">
</p>

---

*TaskBot · Sprint 5 · Infraestructura sobre Oracle Cloud Infrastructure*

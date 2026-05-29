workspace "TaskBot" "Modelo de arquitectura C4 de la plataforma de gestión de tareas TaskBot (Sprint 3)." {

    !identifiers hierarchical
    !impliedRelationships true

    # Las decisiones de arquitectura (ADRs), renderizandose en Structurizr.
    !adrs doc/arch

    model {

        # ---------------------------------------------------------------------
        # Personas (actores identificados)
        # ---------------------------------------------------------------------
        admin = person "Admin" "Administra el sistema: registra usuarios y asigna roles." "Actor"
        pm    = person "Project Manager" "Crea proyectos, define e inicia/cierra sprints, asigna tareas y consulta KPIs." "Actor"
        dev   = person "Developer" "Actualiza tareas y estados, registra horas, usa el tablero Kanban y el chatbot." "Actor"

        # ---------------------------------------------------------------------
        # Sistemas externos
        # ---------------------------------------------------------------------
        openai   = softwareSystem "OpenAI API" "Modelo de lenguaje (gpt-4o-mini) que genera las recomendaciones del chatbot." "External"
        telegram = softwareSystem "Telegram Bot API" "Canal de mensajería (api.telegram.org) para las notificaciones del equipo." "External"
        jira     = softwareSystem "Jira" "Gestor de incidencias (proyecto TASKBOT) donde se crean tickets de fallo automáticos." "External"
        cicd     = softwareSystem "CI/CD Platform" "GitHub Actions + GitHub Container Registry (ghcr.io/<org>/taskbot): construye y despliega el sistema." "External"

        # ---------------------------------------------------------------------
        # Sistema principal
        # ---------------------------------------------------------------------
        taskbot = softwareSystem "TaskBot" "Plataforma de gestión de tareas tipo Scrum: planeación de sprints, tablero Kanban, KPIs y chatbot de IA." {

            spa = container "Single Page Application" "Interfaz web del equipo: Login, Proyectos/Sprints, Task Manager, Kanban, Dashboard de KPIs y Chatbot." "React + Vite (servida por Nginx)" "WebApp"

            ingress = container "API Gateway" "Punto de entrada único: enrutamiento por ruta, terminación TLS y balanceo hacia los microservicios." "NGINX Ingress Controller" "Gateway"

            authSvc = container "auth-service" "Autenticación con JWT, hash BCrypt, gestión de roles y de perfiles de usuario (Auth + User Management)." "Spring Boot · JAR · :8082" "Microservice"

            taskSvc = container "task-service" "Gestión de tareas, estados, horas y del ciclo de vida de proyectos y sprints (Task + Project & Sprint)." "Spring Boot · JAR · :8084" "Microservice" {
                taskController   = component "TaskController" "API REST de tareas (/api/tasks): crear, asignar, cambiar estado, registrar horas." "Spring MVC"
                taskService      = component "TaskService" "Lógica de negocio de tareas (Task Management Component de Sprint 1)." "Spring Service"
                sprintController = component "SprintController" "API REST de sprints y proyectos (/api/sprints)." "Spring MVC"
                sprintService    = component "SprintService" "Ciclo de vida de sprints: crear, iniciar, cerrar (Project & Sprint Component de Sprint 1)." "Spring Service"
                taskRepo         = component "TaskRepository" "Acceso a datos de tareas." "Spring Data JPA"
                sprintRepo       = component "SprintRepository" "Acceso a datos de proyectos y sprints." "Spring Data JPA"
                kpiClient        = component "KpiFeignClient" "Cliente declarativo hacia kpi-service para disparar cálculos al completar tareas." "Spring Cloud OpenFeign"
            }

            kpiSvc = container "kpi-service" "Cálculo de KPIs (horas por sprint, tareas por developer, velocidad), reportes y comparativas históricas." "Spring Boot · WAR · :8080" "Microservice"

            aiSvc = container "ai-service" "Chatbot: recibe consultas NLP, recupera contexto y llama a OpenAI para generar recomendaciones." "Spring Boot · JAR · :8083" "Microservice"

            telegramSvc = container "telegram-service" "Notificaciones: detecta eventos críticos y envía alertas al canal de Telegram." "Spring Boot · JAR · :8081" "Microservice"

            db = container "Oracle Autonomous DB" "Persistencia compartida del sistema: usuarios, proyectos, sprints, tareas, KPIs e historial de chat." "Oracle ATP · gestiondetareasbd_tp · wallet en /app/Wallet" "Database"
        }

        # ---------------------------------------------------------------------
        # Relaciones — nivel personas / contenedores
        # (las relaciones de nivel sistema se infieren con !impliedRelationships)
        # ---------------------------------------------------------------------
        dev   -> taskbot.spa "Gestiona sus tareas, usa el Kanban y consulta el chatbot" "HTTPS"
        pm    -> taskbot.spa "Gestiona proyectos, sprints, tareas y consulta KPIs" "HTTPS"
        admin -> taskbot.spa "Registra usuarios y asigna roles" "HTTPS"

        taskbot.spa -> taskbot.ingress "Realiza llamadas a la API" "HTTPS/JSON"

        # Enrutamiento del Ingress (mapeo de rutas real)
        taskbot.ingress -> taskbot.authSvc "Enruta /api/v1/auth, /swagger-auth" "HTTP"
        taskbot.ingress -> taskbot.taskSvc.taskController "Enruta /api/tasks, /swagger-tasks" "HTTP"
        taskbot.ingress -> taskbot.taskSvc.sprintController "Enruta /api/sprints" "HTTP"
        taskbot.ingress -> taskbot.kpiSvc "Enruta /api, /swagger-ui (catch-all)" "HTTP"
        taskbot.ingress -> taskbot.aiSvc "Enruta /api/ai, /swagger-ia" "HTTP"
        taskbot.ingress -> taskbot.telegramSvc "Enruta /api/webhook/telegram, /api/anuncios" "HTTP"

        # Acceso a datos (servicios sin componentes modelados)
        taskbot.authSvc -> taskbot.db "Lee/escribe usuarios y roles" "JDBC + Wallet"
        taskbot.kpiSvc  -> taskbot.db "Lee datos operativos y persiste snapshots de KPI" "JDBC + Wallet"
        taskbot.aiSvc   -> taskbot.db "Lee/escribe historial de conversaciones" "JDBC + Wallet"

        # Comunicación entre servicios
        taskbot.aiSvc -> taskbot.taskSvc.taskController "Obtiene contexto de tareas y sprints activos" "REST"

        # Servicios -> sistemas externos
        taskbot.aiSvc       -> openai   "Envía el prompt con el contexto del proyecto" "HTTPS (completions)"
        taskbot.telegramSvc -> telegram "Envía mensajes al canal del equipo" "HTTPS (sendMessage)"

        # Relaciones internas del task-service (vista de componentes)
        taskbot.taskSvc.taskController   -> taskbot.taskSvc.taskService   "Invoca la lógica de tareas"
        taskbot.taskSvc.sprintController -> taskbot.taskSvc.sprintService "Invoca la lógica de sprints"
        taskbot.taskSvc.taskService      -> taskbot.taskSvc.taskRepo      "Lee/escribe tareas"
        taskbot.taskSvc.sprintService    -> taskbot.taskSvc.sprintRepo    "Lee/escribe sprints y proyectos"
        taskbot.taskSvc.taskService      -> taskbot.taskSvc.kpiClient     "Notifica tarea completada"
        taskbot.taskSvc.kpiClient        -> taskbot.kpiSvc                "Dispara cálculo de KPI" "REST (Feign)"
        taskbot.taskSvc.taskService      -> taskbot.telegramSvc          "Notifica tarea bloqueada" "REST"
        taskbot.taskSvc.sprintService    -> taskbot.telegramSvc          "Avisa de sprint próximo a vencer" "REST"
        taskbot.taskSvc.taskRepo         -> taskbot.db                   "Persiste tareas" "JDBC + Wallet"
        taskbot.taskSvc.sprintRepo       -> taskbot.db                   "Persiste sprints y proyectos" "JDBC + Wallet"

        # Relaciones de nivel sistema (CI/CD y Jira)
        cicd    -> taskbot "Construye imágenes y despliega a OKE" "GitHub Actions"
        taskbot -> jira    "Crea tickets Bug ante fallos de despliegue" "REST API"

        # ---------------------------------------------------------------------
        # Entorno de despliegue (Deployment) — OCI / OKE, namespace activo vs-blue
        # ---------------------------------------------------------------------
        production = deploymentEnvironment "Production" {

            github = deploymentNode "GitHub" "Repositorio, CI/CD y registro de imágenes" "GitHub" {
                ghActions = infrastructureNode "GitHub Actions" "Pipelines de Build y Deploy (approval manual)" "Workflows YAML"
                ghcr      = infrastructureNode "GHCR" "Registro de imágenes Docker (ghcr.io/<org>/taskbot)" "Container Registry"
            }

            oci = deploymentNode "Oracle Cloud Infrastructure" "Región mx-queretaro-1" "OCI" {

                prodLb = deploymentNode "Production Load Balancer" "Balanceador público (taskbot-prod-lb)" "OCI Load Balancer" {

                    oke = deploymentNode "OKE Cluster" "taskbot-oke-cluster · node pool >= 2 nodos" "Oracle Container Engine for Kubernetes" {

                        ingressNs = deploymentNode "ingress-nginx" "Namespace de ingress" "Kubernetes Namespace" {
                            ingressInstance = containerInstance taskbot.ingress
                        }

                        vsblue = deploymentNode "Namespace vs-blue" "Namespace activo · estrategia Blue/Green · imagen base eclipse-temurin:17-jre-alpine" "Kubernetes Namespace" {

                            feNode = deploymentNode "frontend" "" "Pod (2 réplicas)" {
                                instances 2
                                spaInstance = containerInstance taskbot.spa
                            }
                            authNode = deploymentNode "auth-service" "" "Pod (2 réplicas)" {
                                instances 2
                                authInstance = containerInstance taskbot.authSvc
                            }
                            taskNode = deploymentNode "task-service" "" "Pod (2 réplicas)" {
                                instances 2
                                taskInstance = containerInstance taskbot.taskSvc
                            }
                            kpiNode = deploymentNode "kpi-service" "" "Pod (2 réplicas)" {
                                instances 2
                                kpiInstance = containerInstance taskbot.kpiSvc
                            }
                            aiNode = deploymentNode "ai-service" "" "Pod (2 réplicas)" {
                                instances 2
                                aiInstance = containerInstance taskbot.aiSvc
                            }
                            telegramNode = deploymentNode "telegram-service" "" "Pod (2 réplicas)" {
                                instances 2
                                telegramInstance = containerInstance taskbot.telegramSvc
                            }
                            config = infrastructureNode "Secrets & ConfigMap" "db/jwt/openai/telegram creds · oracle-wallet (/app/Wallet) · taskbot-config" "Kubernetes"
                        }
                    }
                }

                atp = deploymentNode "Oracle Autonomous DB (ATP)" "gestiondetareasbd_tp" "Oracle ATP" {
                    dbInstance = containerInstance taskbot.db
                }

                observability = deploymentNode "OCI Observability" "Logging · Monitoring · Notification" "OCI" {
                    fnJira = infrastructureNode "fn-jira-ticket-creator" "Crea tickets Bug ante fallos post-deploy" "OCI Functions"
                }
            }

            openaiNode = deploymentNode "OpenAI" "SaaS externo" "Cloud" {
                openaiInstance = softwareSystemInstance openai
            }
            telegramExtNode = deploymentNode "Telegram" "SaaS externo" "Cloud" {
                telegramExtInstance = softwareSystemInstance telegram
            }
            atlassianNode = deploymentNode "Atlassian" "SaaS externo" "Cloud" {
                jiraInstance = softwareSystemInstance jira
            }

            # Relaciones de infraestructura
            github.ghActions -> github.ghcr "Publica imágenes" "docker push"
            github.ghActions -> oci.prodLb.oke "Despliega manifests al namespace inactivo" "kubectl apply"
            oci.observability.fnJira -> atlassianNode.jiraInstance "Crea ticket Bug ante fallo" "REST"
        }
    }

    # =====================================================================
    # Vistas
    # =====================================================================
    views {

        systemLandscape "Landscape" "Panorama de TaskBot en su ecosistema." {
            include *
            autoLayout lr
        }

        systemContext taskbot "Context" "Contexto: actores y sistemas externos alrededor de TaskBot." {
            include *
            autoLayout lr
        }

        container taskbot "Containers" "Contenedores internos de TaskBot." {
            include *
            exclude cicd jira
            autoLayout lr
        }

        component taskbot.taskSvc "Components" "Componentes del task-service (Task Management + Project & Sprint)." {
            include *
            autoLayout lr
        }

        deployment taskbot production "Deployment" "Despliegue en OCI/OKE (namespace activo vs-blue) + CI/CD." {
            include *
            autoLayout lr
        }

        dynamic taskbot "uc01_chatbot" "Caso de uso: recomendación del chatbot de IA." {
            dev -> taskbot.spa "Escribe una consulta en lenguaje natural"
            taskbot.spa -> taskbot.ingress "POST /api/ai/chat"
            taskbot.ingress -> taskbot.aiSvc "Enruta la consulta al chatbot"
            taskbot.aiSvc -> taskbot.taskSvc "Obtiene contexto de tareas y sprints activos"
            taskbot.aiSvc -> openai "Envía el prompt con el contexto del proyecto"
            autoLayout lr
        }

        dynamic taskbot "uc02_blocked_task" "Caso de uso: tarea bloqueada -> notificación a Telegram." {
            dev -> taskbot.spa "Cambia el estado de una tarea a Blocked"
            taskbot.spa -> taskbot.ingress "PUT /api/tasks/{id}/status"
            taskbot.ingress -> taskbot.taskSvc "Actualiza el estado de la tarea"
            taskbot.taskSvc -> taskbot.telegramSvc "Notifica la tarea bloqueada"
            taskbot.telegramSvc -> telegram "Envía el mensaje al canal del equipo"
            autoLayout lr
        }

        styles {
            element "Actor" {
                shape Person
                background #08427b
                color #ffffff
            }
            element "Software System" {
                background #1168bd
                color #ffffff
            }
            element "External" {
                background #999999
                color #ffffff
            }
            element "Container" {
                background #438dd5
                color #ffffff
            }
            element "WebApp" {
                shape WebBrowser
                background #438dd5
                color #ffffff
            }
            element "Gateway" {
                shape Hexagon
                background #85bbf0
                color #000000
            }
            element "Microservice" {
                shape RoundedBox
                background #438dd5
                color #ffffff
            }
            element "Database" {
                shape Cylinder
                background #f5a623
                color #000000
            }
            element "Component" {
                background #85bbf0
                color #000000
            }
            element "Infrastructure Node" {
                background #ffffff
                color #000000
            }
        }
    }
}

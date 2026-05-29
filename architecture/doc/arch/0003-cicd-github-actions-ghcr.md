# 3. CI/CD con GitHub Actions y GHCR

Date: 2026-05-29

## Status

Accepted

## Context

El sistema requiere un pipeline que, ante un cambio, construya las imágenes Docker de los microservicios, las publique en un registro y las despliegue a OKE con una aprobación manual antes de producción. Una opción evaluada fue OCI DevOps (Code Repository + Build/Deployment Pipelines + Container Registry, todo dentro de OCI). El código fuente del equipo ya vive en GitHub.

## Decision

Implementamos el CI/CD con **GitHub Actions** y publicamos las imágenes en **GitHub Container Registry (GHCR)**, en lugar de OCI DevOps y OCI Container Registry.

- Workflow de **Build**: `on: push` a `main` con path filters para construir solo el servicio que cambió; `mvn package` (JAR, o WAR para `kpi-service`), `docker build` con base `eclipse-temurin:17-jre-alpine` y push a `ghcr.io/<org>/taskbot/<servicio>` con tags `:<git-sha>` y `:latest`.
- Workflow de **Deploy**: configura `kubectl` con un kubeconfig guardado como GitHub Secret y despliega a OKE.
- La **aprobación manual** se implementa con un GitHub Environment `production` con required reviewers.
- OKE se autentica contra GHCR mediante un `imagePullSecret`.

## Consequences

**Positivas:**
- Un solo lugar (GitHub) para código, pipelines, registro y revisiones de PR.
- Los workflows son YAML versionados junto al código; fáciles de revisar y reproducir.
- GHCR se integra de forma nativa con los permisos del repositorio y el `GITHUB_TOKEN`.
- No se crea ni mantiene un Container Registry en OCI.

**Negativas / trade-offs:**
- La autenticación GitHub -> OKE depende de un kubeconfig en un Secret; hay que rotarlo y custodiarlo con cuidado.
- Se pierde la integración nativa de OCI DevOps con el resto de la consola de OCI.
- Los runners de GitHub son externos a OCI: el tráfico de deploy sale y entra a la red del cluster, lo que exige reglas de red y credenciales bien acotadas.

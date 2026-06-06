#!/usr/bin/env bash
# =========================================================
# Genera un kubeconfig autocontenido para el ServiceAccount
# github-deployer de un namespace. Lo usaremos como secret
# de GitHub Actions.
#
# Uso:
#   ./scripts/generate-kubeconfig.sh vs-blue  > kubeconfig-blue.yaml
#   ./scripts/generate-kubeconfig.sh vs-green > kubeconfig-green.yaml
#
# Después lo codificamos en base64 y lo metemos como secret en GitHub.
# =========================================================
set -euo pipefail

NAMESPACE="${1:?Uso: $0 <namespace>}"
SA_NAME="github-deployer"
SECRET_NAME="github-deployer-token"

# Confirmar que el secret existe y tiene token
if ! kubectl get secret -n "${NAMESPACE}" "${SECRET_NAME}" >/dev/null 2>&1; then
  echo "ERROR: Secret ${SECRET_NAME} no existe en ${NAMESPACE}. ¿Aplicaste el RBAC?" >&2
  exit 1
fi

# Extraer datos del cluster actual (asume que tu kubectl ya apunta al cluster correcto)
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# Token (decodificado) y CA cert (sigue en base64 para el kubeconfig)
TOKEN=$(kubectl get secret -n "${NAMESPACE}" "${SECRET_NAME}" -o jsonpath='{.data.token}' | base64 -d)
CA_B64=$(kubectl get secret -n "${NAMESPACE}" "${SECRET_NAME}" -o jsonpath='{.data.ca\.crt}')

if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: Token vacío. El Secret aún no ha generado token, espera unos segundos y reintenta." >&2
  exit 1
fi

# Emite el kubeconfig completo
cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_B64}
contexts:
  - name: github-deployer@${NAMESPACE}
    context:
      cluster: ${CLUSTER_NAME}
      namespace: ${NAMESPACE}
      user: github-deployer
users:
  - name: github-deployer
    user:
      token: ${TOKEN}
current-context: github-deployer@${NAMESPACE}
EOF

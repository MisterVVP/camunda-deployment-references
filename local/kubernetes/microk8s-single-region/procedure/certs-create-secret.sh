#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_kubeconfig
cd "$ROOT_DIR"

[[ -f .certs/tls.crt && -f .certs/tls.key ]] || {
    echo "ERROR: certificates not found; run make certs.generate first." >&2
    exit 1
}

for secret in camunda-platform camunda-keycloak-tls; do
    kubectl create secret tls "$secret" \
        --cert=.certs/tls.crt \
        --key=.certs/tls.key \
        --namespace="${CAMUNDA_NAMESPACE:-camunda}" \
        --dry-run=client -o yaml | kubectl apply -f -
done

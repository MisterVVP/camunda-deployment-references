#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_kubeconfig
require_cmd mkcert
CAROOT="$(mkcert -CAROOT 2>/dev/null)"
[[ -f "$CAROOT/rootCA.pem" ]] || {
    echo "ERROR: mkcert root CA not found." >&2
    exit 1
}

kubectl create configmap mkcert-ca \
    --from-file=ca.crt="$CAROOT/rootCA.pem" \
    --namespace="${CAMUNDA_NAMESPACE:-camunda}" \
    --dry-run=client -o yaml | kubectl apply -f -

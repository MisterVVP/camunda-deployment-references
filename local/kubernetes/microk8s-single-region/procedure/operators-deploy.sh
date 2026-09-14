#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_kubeconfig
require_cmd kubectl
require_cmd curl
require_cmd envsubst

SECONDARY_STORAGE="${SECONDARY_STORAGE:-}"
CAMUNDA_MODE="${CAMUNDA_MODE:-no-domain}"
CAMUNDA_NAMESPACE="${CAMUNDA_NAMESPACE:-camunda}"

if [[ "$SECONDARY_STORAGE" != "elasticsearch" && "$SECONDARY_STORAGE" != "postgres" ]]; then
    echo "ERROR: SECONDARY_STORAGE must be elasticsearch or postgres." >&2
    exit 1
fi

CAMUNDA_DOMAIN="${CAMUNDA_DOMAIN:-camunda.example.com}"
export CAMUNDA_DOMAIN CAMUNDA_NAMESPACE

OPERATOR_BASE="$ROOT_DIR/../../../generic/kubernetes/operator-based"
CONFIGS_DIR="$ROOT_DIR/configs"

claim_cluster_resource() {
    local state_key="$1" description="$2"
    shift 2
    if state_true "$state_key"; then
        return
    fi
    for probe in "$@"; do
        if eval "$probe" >/dev/null 2>&1; then
            echo "ERROR: pre-existing $description detected." >&2
            echo "Refusing to modify it because purge must never remove infrastructure it did not create." >&2
            exit 1
        fi
    done
    state_set "$state_key" true
}

echo "Deploying operators for MicroK8s ($CAMUNDA_MODE, $SECONDARY_STORAGE)..."

if [[ "$SECONDARY_STORAGE" == "elasticsearch" ]]; then
    claim_cluster_resource eck_installed_by_us "ECK installation" \
        "kubectl get namespace elastic-system" \
        "kubectl get crd -o name | grep -q '\\.k8s\\.elastic\\.co$'"
    (
        cd "$OPERATOR_BASE/elasticsearch"
        ELASTICSEARCH_CLUSTER_FILE="$CONFIGS_DIR/elasticsearch-cluster.yml" ./deploy.sh
    )
fi

claim_cluster_resource cnpg_installed_by_us "CloudNativePG installation" \
    "kubectl get namespace cnpg-system" \
    "kubectl get crd -o name | grep -q '\\.postgresql\\.cnpg\\.io$'"

(
    cd "$OPERATOR_BASE/postgresql"

    # Deploy the three application PostgreSQL clusters without CLUSTER_FILTER.
    # The generic deploy script only needs yq for filtered deployment, so this
    # keeps yq out of the local MicroK8s dependency set entirely.
    CLUSTER_FILTER="" ./deploy.sh

    if [[ "$SECONDARY_STORAGE" == "postgres" ]]; then
        echo "Deploying PostgreSQL orchestration cluster..."
        # set-secrets.sh above created pg-camunda credentials too because the
        # unfiltered path creates secrets for every known local cluster.
        kubectl apply --server-side \
            -f postgresql-orchestration-cluster.yml \
            -n "$CAMUNDA_NAMESPACE"
        kubectl wait --for=condition=Ready --timeout=600s \
            cluster/pg-camunda -n "$CAMUNDA_NAMESPACE"
    fi
)

claim_cluster_resource keycloak_operator_installed_by_us "Keycloak operator CRDs" \
    "kubectl get crd -o name | grep -q '\\.k8s\\.keycloak\\.org$'"

(
    cd "$OPERATOR_BASE/keycloak"
    if [[ "$CAMUNDA_MODE" == "domain" ]]; then
        require_cmd python3
        ingress_class="$(state_get ingress_class "")"
        if [[ -z "$ingress_class" ]]; then
            echo "ERROR: ingress class state is missing. Run make ingress.configure first." >&2
            exit 1
        fi

        # The shared Keycloak domain manifest is maintained by the Kind reference
        # and currently names Contour explicitly. Generate a local copy with only
        # the IngressClass changed, so MicroK8s can reuse a pre-existing Traefik or
        # Contour without forking the rest of the Keycloak configuration.
        keycloak_source="$OPERATOR_BASE/keycloak/keycloak-instance-domain-contour.yml"
        keycloak_config="$STATE_DIR/keycloak-instance-domain.yml"
        python3 - "$keycloak_source" "$keycloak_config" "$ingress_class" <<'PY'
from pathlib import Path
import sys

source, target, ingress_class = sys.argv[1:]
text = Path(source).read_text()
needle = "    ingressClassName: contour\n"
if text.count(needle) != 1:
    raise SystemExit("ERROR: expected exactly one Contour IngressClass in the shared Keycloak manifest")
Path(target).write_text(text.replace(needle, f"    ingressClassName: {ingress_class}\n"))
PY
        KEYCLOAK_CONFIG_FILE="$keycloak_config" ./deploy.sh
    else
        KEYCLOAK_CONFIG_FILE="keycloak-instance-no-domain.yml" ./deploy.sh
    fi
)

if [[ "$CAMUNDA_MODE" == "domain" ]]; then
    ingress_provider="$(state_get ingress_provider "")"
    ingress_address="$(state_get ingress_external_address "")"
    if [[ -z "$ingress_address" ]]; then
        echo "ERROR: ingress external address is missing." >&2
        exit 1
    fi

    echo "Waiting for Keycloak through ${ingress_provider:-selected} ingress at $ingress_address..."
    probe_url="https://${CAMUNDA_DOMAIN}/auth/realms/master/.well-known/openid-configuration"
    for attempt in $(seq 1 60); do
        if curl -fsSk -o /dev/null \
            --resolve "${CAMUNDA_DOMAIN}:443:${ingress_address}" \
            --connect-timeout 5 --max-time 10 "$probe_url"; then
            echo "✓ Keycloak reachable through ingress."
            break
        fi
        if [[ "$attempt" -eq 60 ]]; then
            echo "ERROR: Keycloak did not become reachable through ingress." >&2
            echo "       Provider: ${ingress_provider:-unknown}, address: $ingress_address" >&2
            exit 1
        fi
        sleep 5
    done
fi

state_set secondary_storage "$SECONDARY_STORAGE"
state_set operators_deployed true

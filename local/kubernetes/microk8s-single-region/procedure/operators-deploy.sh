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
        KEYCLOAK_CONFIG_FILE="keycloak-instance-domain-contour.yml" ./deploy.sh
    else
        KEYCLOAK_CONFIG_FILE="keycloak-instance-no-domain.yml" ./deploy.sh
    fi
)

if [[ "$CAMUNDA_MODE" == "domain" ]]; then
    echo "Waiting for Keycloak through Contour..."
    probe_url="https://${CAMUNDA_DOMAIN}/auth/realms/master/.well-known/openid-configuration"
    for attempt in $(seq 1 60); do
        if curl -fsSk -o /dev/null \
            --resolve "${CAMUNDA_DOMAIN}:443:127.0.0.1" \
            --connect-timeout 5 --max-time 10 "$probe_url"; then
            echo "✓ Keycloak reachable through ingress."
            break
        fi
        if [[ "$attempt" -eq 60 ]]; then
            echo "ERROR: Keycloak did not become reachable through ingress." >&2
            exit 1
        fi
        sleep 5
    done
fi

state_set secondary_storage "$SECONDARY_STORAGE"
state_set operators_deployed true

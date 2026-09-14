#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_kubeconfig
require_cmd helm
require_cmd kubectl
require_cmd ss

# renovate: datasource=helm depName=contour registryUrl=https://projectcontour.github.io/helm-charts
CONTOUR_HELM_CHART_VERSION="0.6.0"

if ! state_true contour_installed_by_us; then
    if kubectl get namespace projectcontour >/dev/null 2>&1 \
        || kubectl get ingressclass contour >/dev/null 2>&1 \
        || kubectl get crd -o name 2>/dev/null | grep -q '\.projectcontour\.io$'; then
        echo "ERROR: an existing Contour installation or CRD was detected." >&2
        echo "Refusing to adopt it because purge must not remove pre-existing infrastructure." >&2
        exit 1
    fi

    # Envoy uses hostNetwork on 80/443 so local TLS works on 127.0.0.1 without
    # LoadBalancer/MetalLB. Fail early if another host service owns those ports.
    if ss -H -ltn '( sport = :80 or sport = :443 )' | grep -q .; then
        echo "ERROR: host ports 80 and/or 443 are already in use." >&2
        echo "Disable the conflicting local ingress/web server before deploying Contour." >&2
        ss -H -ltnp '( sport = :80 or sport = :443 )' || true
        exit 1
    fi
    state_set contour_installed_by_us true
fi

echo "Installing Contour ingress controller..."
helm upgrade --install contour contour \
    --repo https://projectcontour.github.io/helm-charts/ \
    --version "$CONTOUR_HELM_CHART_VERSION" \
    --namespace projectcontour \
    --create-namespace \
    --set envoy.kind=deployment \
    --set envoy.replicaCount=1 \
    --set envoy.hostNetwork=true \
    --set envoy.dnsPolicy=ClusterFirstWithHostNet \
    --set envoy.updateStrategy.type=Recreate \
    --set envoy.containerPorts.http=80 \
    --set envoy.containerPorts.https=443 \
    --set envoy.service.type=NodePort \
    --set contour.ingressClass.default=true

kubectl wait --namespace projectcontour \
    --for=condition=available \
    --timeout=180s \
    deployment/contour-envoy

echo "Contour deployed successfully."

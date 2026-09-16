#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

KIND_DIR="$(cd "$ROOT_DIR/../kind-single-region" && pwd)"
MODE="${1:-}"

state_set camunda_deploy_attempted true
export CAMUNDA_HELM_CHART_CHECKOUT_DIR="$ROOT_DIR/.camunda-platform-helm"

case "$MODE" in
    domain)
        ingress_values="$STATE_DIR/values-ingress.yml"
        if [[ ! -s "$ingress_values" ]]; then
            echo "ERROR: ingress Helm values are missing. Run make ingress.configure first." >&2
            exit 1
        fi
        export CAMUNDA_EXTRA_VALUES_FILE="$ingress_values"
        helper=camunda-deploy-domain.sh
        ;;
    no-domain)
        helper=camunda-deploy-no-domain.sh
        ;;
    *)
        echo "Usage: $0 {domain|no-domain}" >&2
        exit 2
        ;;
esac

# Reuse the Kind local-development Helm layering. Domain mode adds one final,
# MicroK8s-owned values file that selects the detected ingress provider.
cd "$KIND_DIR"
exec "./procedure/$helper"

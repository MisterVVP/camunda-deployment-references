#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

KIND_DIR="$(cd "$ROOT_DIR/../kind-single-region" && pwd)"
MODE="${1:-}"

state_set camunda_deploy_attempted true
export CAMUNDA_HELM_CHART_CHECKOUT_DIR="$ROOT_DIR/.camunda-platform-helm"

case "$MODE" in
    domain)
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

# The Helm values are provider-independent local-development values already
# maintained by kind-single-region. Run from that directory so relative
# helm-values paths keep working, while placing the chart checkout here.
cd "$KIND_DIR"
exec "./procedure/$helper"

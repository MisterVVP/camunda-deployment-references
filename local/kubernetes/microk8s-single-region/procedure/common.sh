#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="${TOOLS_DIR:-$ROOT_DIR/.tools}"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/.state}"
STATE_FILE="$STATE_DIR/install-state"
KUBECONFIG="${KUBECONFIG:-$STATE_DIR/kubeconfig}"
KUBECACHEDIR="${KUBECACHEDIR:-$STATE_DIR/kubectl-cache}"
HELM_CACHE_HOME="${HELM_CACHE_HOME:-$STATE_DIR/helm/cache}"
HELM_CONFIG_HOME="${HELM_CONFIG_HOME:-$STATE_DIR/helm/config}"
HELM_DATA_HOME="${HELM_DATA_HOME:-$STATE_DIR/helm/data}"
PATH="$TOOLS_DIR/bin:$ROOT_DIR/bin:$PATH"
export TOOLS_DIR STATE_DIR STATE_FILE KUBECONFIG KUBECACHEDIR PATH
export HELM_CACHE_HOME HELM_CONFIG_HOME HELM_DATA_HOME

state_get() {
    local key="$1" default="${2:-}"
    if [[ -f "$STATE_FILE" ]]; then
        local value
        value="$(grep -F "${key}=" "$STATE_FILE" | tail -n1 | cut -d= -f2- || true)"
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return
        fi
    fi
    printf '%s\n' "$default"
}

state_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$STATE_DIR"
    tmp="$(mktemp "$STATE_DIR/state.XXXXXX")"
    if [[ -f "$STATE_FILE" ]]; then
        grep -v -F "${key}=" "$STATE_FILE" > "$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

state_true() {
    [[ "$(state_get "$1" false)" == "true" ]]
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command '$1' was not found." >&2
        echo "       Run ./install.sh (golden path) or make prerequisites." >&2
        exit 1
    }
}

ensure_kubeconfig() {
    require_cmd microk8s
    if [[ ! -s "$KUBECONFIG" ]]; then
        mkdir -p "$(dirname "$KUBECONFIG")"
        microk8s config > "$KUBECONFIG"
        chmod 600 "$KUBECONFIG"
    fi
}

wait_for_pv_gone() {
    local pv="$1"
    for _ in $(seq 1 60); do
        if ! kubectl get pv "$pv" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "ERROR: persistent volume '$pv' was not deleted." >&2
    return 1
}

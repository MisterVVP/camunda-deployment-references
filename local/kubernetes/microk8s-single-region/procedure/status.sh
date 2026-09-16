#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

_status_tmp_dir=""
if [[ ! -s "$KUBECONFIG" ]]; then
    _status_tmp_dir="$(mktemp -d)"
    microk8s config > "$_status_tmp_dir/kubeconfig"
    chmod 600 "$_status_tmp_dir/kubeconfig"
    export KUBECONFIG="$_status_tmp_dir/kubeconfig"
    export KUBECACHEDIR="$_status_tmp_dir/kubectl-cache"
    trap 'rm -rf "$_status_tmp_dir"' EXIT
fi

echo "=== MicroK8s ==="
microk8s status || true
echo
echo "=== Nodes ==="
kubectl get nodes -o wide || true
echo
echo "=== Camunda ==="
kubectl get all,pvc -n "${CAMUNDA_NAMESPACE:-camunda}" 2>/dev/null || echo "Camunda namespace not present"
echo
echo "=== Ingress ==="
provider="$(state_get ingress_provider "")"
if [[ -n "$provider" ]]; then
    echo "provider: $provider"
    echo "class:    $(state_get ingress_class unknown)"
    echo "service:  $(state_get ingress_namespace unknown)/$(state_get ingress_service unknown)"
    echo "address:  $(state_get ingress_external_address unknown)"
    echo "owned:    $(state_get ingress_installed_by_us false)"
    kubectl get service "$(state_get ingress_service "")" \
        -n "$(state_get ingress_namespace "")" -o wide 2>/dev/null || true
else
    echo "No ingress selected by this reference."
    kubectl get ingressclass 2>/dev/null || true
fi

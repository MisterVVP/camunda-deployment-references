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
echo "=== Contour ==="
kubectl get pods -n projectcontour 2>/dev/null || echo "Contour not present"

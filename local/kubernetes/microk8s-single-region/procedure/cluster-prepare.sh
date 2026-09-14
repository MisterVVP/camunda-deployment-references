#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd microk8s
require_cmd kubectl
require_cmd helm

echo "Waiting for MicroK8s..."
microk8s status --wait-ready >/dev/null
mkdir -p "$STATE_DIR"

# Use an isolated kubeconfig so this reference never edits ~/.kube/config.
microk8s config > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"

"$SCRIPT_DIR/images.sh" baseline

echo "Using MicroK8s kubeconfig: $KUBECONFIG"
kubectl get nodes

dns_owner="$(state_get dns_enabled_by_us __unset__)"
if ! kubectl -n kube-system get deployment coredns >/dev/null 2>&1; then
    echo "Enabling MicroK8s DNS addon..."
    [[ "$dns_owner" != "__unset__" ]] || state_set dns_enabled_by_us true
    microk8s enable dns
elif [[ "$dns_owner" == "__unset__" ]]; then
    state_set dns_enabled_by_us false
fi

storage_owner="$(state_get hostpath_storage_enabled_by_us __unset__)"
if ! kubectl get storageclass microk8s-hostpath >/dev/null 2>&1; then
    echo "Enabling MicroK8s hostpath-storage addon..."
    [[ "$storage_owner" != "__unset__" ]] || state_set hostpath_storage_enabled_by_us true
    microk8s enable hostpath-storage
elif [[ "$storage_owner" == "__unset__" ]]; then
    state_set hostpath_storage_enabled_by_us false
fi

kubectl rollout status deployment/coredns -n kube-system --timeout=180s

echo "Waiting for microk8s-hostpath StorageClass..."
for _ in $(seq 1 60); do
    if kubectl get storageclass microk8s-hostpath >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
kubectl get storageclass microk8s-hostpath >/dev/null

# The shared PostgreSQL manifests rely on the default StorageClass.
default_scs="$(
    kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
)"
if [[ "$default_scs" != "microk8s-hostpath" ]]; then
    echo "ERROR: expected microk8s-hostpath to be the only default StorageClass." >&2
    echo "Current default StorageClass(es): ${default_scs:-<none>}" >&2
    echo "Refusing to deploy because PostgreSQL PVCs could otherwise land on unrelated storage." >&2
    exit 1
fi

if kubectl get namespace "${CAMUNDA_NAMESPACE:-camunda}" >/dev/null 2>&1; then
    if ! state_true namespace_created_by_us; then
        echo "ERROR: namespace '${CAMUNDA_NAMESPACE:-camunda}' already exists and was not created by this reference." >&2
        echo "Refusing to adopt it because purge must never delete unrelated workloads." >&2
        exit 1
    fi
else
    kubectl create namespace "${CAMUNDA_NAMESPACE:-camunda}"
    state_set namespace_created_by_us true
fi

state_set prepared true
echo "MicroK8s preparation complete."

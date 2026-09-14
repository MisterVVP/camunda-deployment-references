#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd microk8s

# Verification must not recreate .state after a successful purge.
_verify_tmp_dir=""
if [[ ! -s "$KUBECONFIG" ]]; then
    _verify_tmp_dir="$(mktemp -d)"
    microk8s config > "$_verify_tmp_dir/kubeconfig"
    chmod 600 "$_verify_tmp_dir/kubeconfig"
    export KUBECONFIG="$_verify_tmp_dir/kubeconfig"
    export KUBECACHEDIR="$_verify_tmp_dir/kubectl-cache"
    trap 'rm -rf "$_verify_tmp_dir"' EXIT
fi

fail=0
check_absent() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "✗ leftover: $description"
        fail=1
    else
        echo "✓ absent: $description"
    fi
}

ownership_state_present=false
[[ -f "$STATE_FILE" ]] && ownership_state_present=true

if [[ "$ownership_state_present" == "false" ]] || state_true namespace_created_by_us; then
    check_absent "camunda namespace" kubectl get namespace "${CAMUNDA_NAMESPACE:-camunda}"

    if kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="camunda")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -q .; then
        echo "✗ leftover: PVs still reference the camunda namespace"
        fail=1
    else
        echo "✓ absent: Camunda PVs"
    fi
fi

if [[ "$ownership_state_present" == "false" ]] || state_true contour_installed_by_us; then
    check_absent "projectcontour namespace" kubectl get namespace projectcontour
fi

if [[ -f "$STATE_DIR/camunda-hostpaths" ]]; then
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if sudo test -e "$path"; then
            echo "✗ leftover: Camunda hostpath directory $path"
            fail=1
        fi
    done < "$STATE_DIR/camunda-hostpaths"
    ((fail)) || echo "✓ absent: recorded Camunda hostpath directories"
fi

if kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -Fq '# BEGIN camunda-microk8s-reference'; then
    echo "✗ leftover: Camunda CoreDNS rewrite block"
    fail=1
else
    echo "✓ absent: Camunda CoreDNS rewrite block"
fi

if grep -Fq '# camunda-microk8s-reference' /etc/hosts; then
    echo "✗ leftover: Camunda /etc/hosts entries"
    fail=1
else
    echo "✓ absent: Camunda /etc/hosts entries"
fi

for path in "$ROOT_DIR/.certs" "$ROOT_DIR/.camunda-platform-helm"; do
    if [[ -e "$path" ]]; then
        echo "✗ leftover: $path"
        fail=1
    else
        echo "✓ absent: $path"
    fi
done

if state_true contour_installed_by_us; then
    if kubectl get crd -o name 2>/dev/null | grep -q '\.projectcontour\.io$'; then
        echo "✗ leftover: Contour CRDs"
        fail=1
    else
        echo "✓ absent: Contour CRDs"
    fi
fi

if state_true eck_installed_by_us; then
    check_absent "elastic-system namespace" kubectl get namespace elastic-system
    if kubectl get crd -o name 2>/dev/null | grep -q '\.k8s\.elastic\.co$'; then
        echo "✗ leftover: ECK CRDs"
        fail=1
    else
        echo "✓ absent: ECK CRDs"
    fi
fi

if state_true cnpg_installed_by_us; then
    check_absent "cnpg-system namespace" kubectl get namespace cnpg-system
    if kubectl get crd -o name 2>/dev/null | grep -q '\.postgresql\.cnpg\.io$'; then
        echo "✗ leftover: CloudNativePG CRDs"
        fail=1
    else
        echo "✓ absent: CloudNativePG CRDs"
    fi
fi

if state_true keycloak_operator_installed_by_us; then
    check_absent "Keycloak CRDs" kubectl get crd keycloaks.k8s.keycloak.org
fi

if state_true hostpath_storage_enabled_by_us; then
    check_absent "microk8s-hostpath StorageClass" kubectl get storageclass microk8s-hostpath
fi

if state_true dns_enabled_by_us; then
    check_absent "CoreDNS deployment enabled by this reference" kubectl get deployment coredns -n kube-system
fi

if [[ "$(state_get mkcert_ca_preexisting true)" == "false" ]]; then
    caroot="$(state_get mkcert_caroot "")"
    caroot_dir_preexisting="$(state_get mkcert_caroot_dir_preexisting true)"
    if [[ "$caroot_dir_preexisting" == "false" && -n "$caroot" && -e "$caroot" ]]; then
        echo "✗ leftover: mkcert CA directory $caroot"
        fail=1
    elif [[ "$caroot_dir_preexisting" == "true" && -n "$caroot" && ( -e "$caroot/rootCA.pem" || -e "$caroot/rootCA-key.pem" ) ]]; then
        echo "✗ leftover: mkcert CA files created by this reference"
        fail=1
    else
        echo "✓ absent: mkcert CA files created by this reference"
    fi
fi

if ((fail)); then
    echo "ERROR: cleanup verification found leftovers. State was preserved for another purge attempt." >&2
    exit 1
fi

echo "✓ Cleanup verification passed."

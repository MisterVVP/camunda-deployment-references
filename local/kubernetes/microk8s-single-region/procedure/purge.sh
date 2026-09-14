#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd microk8s
require_cmd kubectl
require_cmd helm

CAMUNDA_NAMESPACE="${CAMUNDA_NAMESPACE:-camunda}"
CAMUNDA_RELEASE_NAME="${CAMUNDA_RELEASE_NAME:-camunda}"
PV_FILE="$STATE_DIR/camunda-pvs"
HOSTPATH_FILE="$STATE_DIR/camunda-hostpaths"

echo "Purging Camunda local deployment from MicroK8s..."

if [[ ! -f "$STATE_FILE" && "${FORCE_PURGE:-0}" != "1" ]]; then
    echo "ERROR: ownership state '$STATE_FILE' is missing." >&2
    echo "Refusing destructive cleanup because this script cannot distinguish Camunda resources from pre-existing resources." >&2
    echo "If you intentionally deleted the state file and accept that risk, rerun with FORCE_PURGE=1." >&2
    exit 1
fi

ensure_kubeconfig

namespace_owned=false
if state_true namespace_created_by_us || [[ "${FORCE_PURGE:-0}" == "1" ]]; then
    namespace_owned=true
fi

# Capture image references before deleting the pods that tell us what this
# deployment actually pulled.
"$SCRIPT_DIR/images.sh" capture-owned

# Capture exactly the PVs/backing paths owned by the namespace only when the
# namespace itself is ours (or the user explicitly forced cleanup).
if [[ "$namespace_owned" == "true" ]]; then
    kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="'"$CAMUNDA_NAMESPACE"'")]}{.metadata.name}{"\n"}{end}' \
        > "$PV_FILE" 2>/dev/null || true
    kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="'"$CAMUNDA_NAMESPACE"'")]}{.spec.hostPath.path}{"\n"}{end}' \
        > "$HOSTPATH_FILE" 2>/dev/null || true
else
    : > "$PV_FILE"
    : > "$HOSTPATH_FILE"
fi

if state_true camunda_deploy_attempted || [[ "${FORCE_PURGE:-0}" == "1" ]]; then
    helm uninstall "$CAMUNDA_RELEASE_NAME" -n "$CAMUNDA_NAMESPACE" >/dev/null 2>&1 || true
fi

if [[ "$namespace_owned" == "true" ]] && kubectl get namespace "$CAMUNDA_NAMESPACE" >/dev/null 2>&1; then
    # Let the still-running ECK/CNPG/Keycloak operators finalize their CRs first.
    kubectl delete elasticsearches.elasticsearch.k8s.elastic.co --all -n "$CAMUNDA_NAMESPACE" \
        --ignore-not-found --wait=true --timeout=300s || true
    kubectl delete clusters.postgresql.cnpg.io --all -n "$CAMUNDA_NAMESPACE" \
        --ignore-not-found --wait=true --timeout=300s || true
    kubectl delete keycloaks.k8s.keycloak.org --all -n "$CAMUNDA_NAMESPACE" \
        --ignore-not-found --wait=true --timeout=300s || true
    kubectl delete keycloakrealmimports.k8s.keycloak.org --all -n "$CAMUNDA_NAMESPACE" \
        --ignore-not-found --wait=true --timeout=300s || true

    kubectl delete namespace "$CAMUNDA_NAMESPACE" --wait=true --timeout=300s
fi

# Wait until the provisioner has removed every PV that belonged to Camunda.
if [[ -s "$PV_FILE" ]]; then
    while IFS= read -r pv; do
        [[ -n "$pv" ]] && wait_for_pv_gone "$pv"
    done < "$PV_FILE"
fi

# ReclaimPolicy=Delete should remove hostpath data. If a directory remains after
# its PV is gone, remove only a path whose basename proves it belonged to the
# camunda namespace. Never sweep the MicroK8s storage root.
if [[ -s "$HOSTPATH_FILE" ]]; then
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        base="$(basename -- "$path")"
        if [[ "$path" == /* && "$path" != "/" && "$base" == camunda-* ]]; then
            if sudo test -e "$path"; then
                echo "Removing stale Camunda hostpath data: $path"
                sudo rm -rf --one-file-system -- "$path"
            fi
        elif sudo test -e "$path"; then
            echo "WARNING: not deleting unexpected hostpath path: $path" >&2
        fi
    done < "$HOSTPATH_FILE"
fi

if state_true contour_installed_by_us; then
    helm uninstall contour -n projectcontour >/dev/null 2>&1 || true
    kubectl delete namespace projectcontour --ignore-not-found --wait=true --timeout=180s || true
    mapfile -t contour_crds < <(kubectl get crd -o name 2>/dev/null | grep '\.projectcontour\.io$' || true)
    if ((${#contour_crds[@]})); then
        kubectl delete "${contour_crds[@]}" --ignore-not-found >/dev/null || true
    fi
    kubectl delete ingressclass contour --ignore-not-found >/dev/null 2>&1 || true
fi

if state_true eck_installed_by_us; then
    kubectl delete namespace elastic-system --ignore-not-found --wait=true --timeout=180s || true
    mapfile -t eck_crds < <(kubectl get crd -o name 2>/dev/null | grep '\.k8s\.elastic\.co$' || true)
    if ((${#eck_crds[@]})); then
        kubectl delete "${eck_crds[@]}" --ignore-not-found >/dev/null || true
    fi
fi

if state_true cnpg_installed_by_us; then
    kubectl delete namespace cnpg-system --ignore-not-found --wait=true --timeout=180s || true
    mapfile -t cnpg_crds < <(kubectl get crd -o name 2>/dev/null | grep '\.postgresql\.cnpg\.io$' || true)
    if ((${#cnpg_crds[@]})); then
        kubectl delete "${cnpg_crds[@]}" --ignore-not-found >/dev/null || true
    fi
fi

if state_true keycloak_operator_installed_by_us; then
    kubectl delete crd \
        keycloaks.k8s.keycloak.org \
        keycloakrealmimports.k8s.keycloak.org \
        keycloakoidcclients.k8s.keycloak.org \
        keycloaksamlclients.k8s.keycloak.org \
        --ignore-not-found >/dev/null || true
fi

"$SCRIPT_DIR/images.sh" cleanup

if state_true coredns_modified_by_us && kubectl get configmap coredns -n kube-system >/dev/null 2>&1; then
    "$SCRIPT_DIR/coredns-config.sh" remove
fi

"$SCRIPT_DIR/hosts.sh" remove

rm -rf "$ROOT_DIR/.certs" "$ROOT_DIR/.camunda-platform-helm"

if state_true mkcert_touched && command -v mkcert >/dev/null 2>&1; then
    ca_preexisting="$(state_get mkcert_ca_preexisting true)"
    if [[ "$ca_preexisting" == "false" || "${PURGE_MKCERT_CA:-0}" == "1" ]]; then
        echo "Uninstalling mkcert CA from local trust stores..."
        mkcert -uninstall || true
    fi
    if [[ "$ca_preexisting" == "false" ]]; then
        caroot="$(state_get mkcert_caroot "")"
        caroot_dir_preexisting="$(state_get mkcert_caroot_dir_preexisting true)"
        if [[ -n "$caroot" && "$caroot" == /* && "$caroot" != "/" ]]; then
            if [[ "$caroot_dir_preexisting" == "false" ]]; then
                rm -rf -- "$caroot"
            else
                rm -f -- "$caroot/rootCA.pem" "$caroot/rootCA-key.pem"
            fi
        fi
    fi
fi

# Disable only addons that this deployment enabled.
if state_true hostpath_storage_enabled_by_us; then
    microk8s disable hostpath-storage || true
    for _ in $(seq 1 60); do
        kubectl get storageclass microk8s-hostpath >/dev/null 2>&1 || break
        sleep 2
    done
fi
if state_true dns_enabled_by_us; then
    microk8s disable dns || true
    for _ in $(seq 1 60); do
        kubectl get deployment coredns -n kube-system >/dev/null 2>&1 || break
        sleep 2
    done
fi

# Verify before throwing away the ownership record.
"$SCRIPT_DIR/verify-clean.sh"

rm -rf "$STATE_DIR"
echo "✓ Purge complete. MicroK8s itself was left installed."

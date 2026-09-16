#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd microk8s

ACTION="${1:-}"
BASELINE="$STATE_DIR/images-before"
OWNED="$STATE_DIR/images-owned"
RAW="$STATE_DIR/images-owned.raw"
CURRENT="$STATE_DIR/images-current"
IN_USE="$STATE_DIR/images-in-use"

normalize_image_ref() {
    local ref="$1" first last
    ref="${ref#docker-pullable://}"
    ref="${ref#docker://}"
    ref="${ref#cri-o://}"

    # containerd://sha256:... has no repository reference and cannot be
    # compared safely with `ctr images list -q`; the pod spec/tag is captured too.
    if [[ "$ref" == containerd://* || "$ref" == sha256:* || -z "$ref" ]]; then
        return 0
    fi

    if [[ "$ref" != */* ]]; then
        ref="docker.io/library/$ref"
    else
        first="${ref%%/*}"
        if [[ "$first" != *.* && "$first" != *:* && "$first" != "localhost" ]]; then
            ref="docker.io/$ref"
        fi
    fi

    last="${ref##*/}"
    if [[ "$last" != *:* && "$ref" != *@* ]]; then
        ref="${ref}:latest"
    fi

    printf '%s\n' "$ref"
}

normalize_file() {
    local input="$1" output="$2"
    : > "$output"
    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        normalize_image_ref "$ref" >> "$output"
    done < "$input"
    sort -u -o "$output" "$output"
}

collect_namespace_images() {
    local ns="$1"
    kubectl get namespace "$ns" >/dev/null 2>&1 || return 0
    kubectl get pods -n "$ns" -o jsonpath='
{range .items[*]}
{range .spec.initContainers[*]}{.image}{"\n"}{end}
{range .spec.containers[*]}{.image}{"\n"}{end}
{range .status.initContainerStatuses[*]}{.imageID}{"\n"}{end}
{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}
{end}' 2>/dev/null >> "$RAW" || true
}

collect_selector_images() {
    local ns="$1" selector="$2"
    kubectl get pods -n "$ns" -l "$selector" -o jsonpath='
{range .items[*]}
{range .spec.initContainers[*]}{.image}{"\n"}{end}
{range .spec.containers[*]}{.image}{"\n"}{end}
{range .status.initContainerStatuses[*]}{.imageID}{"\n"}{end}
{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}
{end}' 2>/dev/null >> "$RAW" || true
}

case "$ACTION" in
    baseline)
        if [[ "$(state_get images_baseline_captured __unset__)" != "__unset__" ]]; then
            exit 0
        fi
        mkdir -p "$STATE_DIR"
        if microk8s ctr images list -q > "$BASELINE.raw" 2>/dev/null; then
            normalize_file "$BASELINE.raw" "$BASELINE"
            rm -f "$BASELINE.raw"
            state_set images_baseline_captured true
            echo "Recorded MicroK8s image baseline."
        else
            rm -f "$BASELINE.raw"
            state_set images_baseline_captured false
            echo "WARNING: could not record the MicroK8s image baseline; purge will leave image cache untouched." >&2
        fi
        ;;

    capture-owned)
        require_cmd kubectl
        mkdir -p "$STATE_DIR"
        : > "$RAW"
        [[ -f "$OWNED" ]] && cat "$OWNED" >> "$RAW"

        if state_true namespace_created_by_us || [[ "${FORCE_PURGE:-0}" == "1" ]]; then
            collect_namespace_images "${CAMUNDA_NAMESPACE:-camunda}"
        fi
        state_true contour_installed_by_us && collect_namespace_images projectcontour
        state_true eck_installed_by_us && collect_namespace_images elastic-system
        state_true cnpg_installed_by_us && collect_namespace_images cnpg-system
        # Addons live in kube-system, so capture only their own pods instead of
        # treating all kube-system images as ours.
        state_true dns_enabled_by_us && collect_selector_images kube-system 'k8s-app=kube-dns'
        state_true hostpath_storage_enabled_by_us && collect_selector_images kube-system 'k8s-app=hostpath-provisioner'

        normalize_file "$RAW" "$OWNED"
        rm -f "$RAW"
        ;;

    cleanup)
        require_cmd kubectl
        if ! state_true images_baseline_captured || [[ ! -f "$BASELINE" || ! -f "$OWNED" ]]; then
            echo "Skipping container image cleanup: no reliable pre-install baseline."
            exit 0
        fi

        current_raw="$STATE_DIR/images-current.raw"
        microk8s ctr images list -q 2>/dev/null > "$current_raw"
        normalize_file "$current_raw" "$CURRENT"
        rm -f "$current_raw"

        raw_in_use="$STATE_DIR/images-in-use.raw"
        kubectl get pods -A -o jsonpath='
{range .items[*]}
{range .spec.initContainers[*]}{.image}{"\n"}{end}
{range .spec.containers[*]}{.image}{"\n"}{end}
{end}' 2>/dev/null > "$raw_in_use" || true
        normalize_file "$raw_in_use" "$IN_USE"
        rm -f "$raw_in_use"

        failed=0
        while IFS= read -r image; do
            [[ -n "$image" ]] || continue
            grep -Fxq "$image" "$BASELINE" && continue
            if grep -Fxq "$image" "$IN_USE"; then
                echo "Keeping image still used by another workload: $image"
                continue
            fi
            if grep -Fxq "$image" "$CURRENT"; then
                echo "Removing MicroK8s image introduced by Camunda: $image"
                if ! microk8s ctr images rm "$image" >/dev/null 2>&1; then
                    echo "WARNING: failed to remove image: $image" >&2
                    failed=1
                fi
            fi
        done < "$OWNED"

        if ((failed)); then
            exit 1
        fi
        ;;

    *)
        echo "Usage: $0 {baseline|capture-owned|cleanup}" >&2
        exit 2
        ;;
esac

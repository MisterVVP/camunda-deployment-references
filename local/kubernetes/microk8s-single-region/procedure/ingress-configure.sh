#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_kubeconfig
require_cmd kubectl
require_cmd python3

REQUESTED_PROVIDER="${INGRESS_PROVIDER:-auto}"
ADDRESS_OVERRIDE="${INGRESS_ADDRESS:-}"
VALUES_FILE="$STATE_DIR/values-ingress.yml"

case "$REQUESTED_PROVIDER" in
    auto|traefik|contour) ;;
    *)
        echo "ERROR: INGRESS_PROVIDER must be auto, traefik, or contour." >&2
        exit 2
        ;;
esac

validate_ipv4() {
    python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}

if [[ -n "$ADDRESS_OVERRIDE" ]] && ! validate_ipv4 "$ADDRESS_OVERRIDE"; then
    echo "ERROR: --ingress-address/INGRESS_ADDRESS must be an IPv4 address, got '$ADDRESS_OVERRIDE'." >&2
    exit 2
fi

find_ingress_class() {
    local controller="$1" preferred="$2"
    local actual
    if kubectl get ingressclass "$preferred" >/dev/null 2>&1; then
        actual="$(kubectl get ingressclass "$preferred" -o jsonpath='{.spec.controller}')"
        if [[ "$actual" == "$controller" ]]; then
            printf '%s\n' "$preferred"
            return 0
        fi
    fi

    kubectl get ingressclass \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.controller}{"\n"}{end}' 2>/dev/null \
        | awk -F '\t' -v controller="$controller" '$2 == controller { print $1; exit }'
}

find_traefik_service() {
    if kubectl get service traefik -n ingress >/dev/null 2>&1; then
        printf '%s\n' 'ingress/traefik'
        return 0
    fi

    local candidates
    candidates="$(kubectl get service -A -l app.kubernetes.io/name=traefik \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    if [[ "$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l)" -eq 1 ]]; then
        printf '%s\n' "$candidates"
        return 0
    fi
    return 1
}

find_contour_service() {
    if kubectl get service contour-envoy -n projectcontour >/dev/null 2>&1; then
        printf '%s\n' 'projectcontour/contour-envoy'
        return 0
    fi
    return 1
}

service_has_https() {
    local namespace="$1" service="$2"
    local file="$STATE_DIR/ingress-service.json"
    kubectl get service "$service" -n "$namespace" -o json > "$file"
    python3 - "$file" <<'PY'
import json
import sys
service = json.load(open(sys.argv[1]))
ports = {int(p.get("port", 0)) for p in service.get("spec", {}).get("ports", [])}
raise SystemExit(0 if 443 in ports else 1)
PY
}

service_external_address() {
    local namespace="$1" service="$2"
    local file="$STATE_DIR/ingress-service.json"
    kubectl get service "$service" -n "$namespace" -o json > "$file"
    python3 - "$file" <<'PY'
import ipaddress
import json
import socket
import sys

service = json.load(open(sys.argv[1]))
status = service.get("status", {}).get("loadBalancer", {}).get("ingress", []) or []
for entry in status:
    value = entry.get("ip")
    if value:
        try:
            print(ipaddress.IPv4Address(value))
            raise SystemExit(0)
        except ipaddress.AddressValueError:
            pass

for value in service.get("spec", {}).get("externalIPs", []) or []:
    try:
        print(ipaddress.IPv4Address(value))
        raise SystemExit(0)
    except ipaddress.AddressValueError:
        pass

for entry in status:
    hostname = entry.get("hostname")
    if not hostname:
        continue
    try:
        infos = socket.getaddrinfo(hostname, 443, socket.AF_INET, socket.SOCK_STREAM)
    except socket.gaierror:
        continue
    if infos:
        print(infos[0][4][0])
        raise SystemExit(0)

raise SystemExit(1)
PY
}

controller_uses_host_network() {
    local provider="$1" namespace="$2"
    local resource=""
    case "$provider" in
        traefik)
            for candidate in deployment/traefik daemonset/traefik; do
                if kubectl get "$candidate" -n "$namespace" >/dev/null 2>&1; then
                    resource="$candidate"
                    break
                fi
            done
            ;;
        contour)
            if kubectl get deployment/contour-envoy -n "$namespace" >/dev/null 2>&1; then
                resource=deployment/contour-envoy
            fi
            ;;
    esac
    [[ -n "$resource" ]] || return 1
    [[ "$(kubectl get "$resource" -n "$namespace" -o jsonpath='{.spec.template.spec.hostNetwork}')" == "true" ]]
}

SELECTED_PROVIDER=""
SELECTED_CLASS=""
SELECTED_NAMESPACE=""
SELECTED_SERVICE=""
SELECTED_ADDRESS=""
SELECTED_OWNED="false"

select_existing() {
    local provider="$1" class="$2" service_ref="$3"
    local namespace="${service_ref%%/*}" service="${service_ref#*/}" address=""

    if ! service_has_https "$namespace" "$service"; then
        echo "Existing $provider service '$service_ref' does not expose service port 443." >&2
        return 1
    fi

    if [[ -n "$ADDRESS_OVERRIDE" ]]; then
        address="$ADDRESS_OVERRIDE"
    elif address="$(service_external_address "$namespace" "$service" 2>/dev/null)"; then
        :
    elif controller_uses_host_network "$provider" "$namespace"; then
        address="127.0.0.1"
    else
        echo "Existing $provider ingress '$service_ref' has no usable external IPv4 address." >&2
        echo "If it is reachable on a known address, pass --ingress-address <IP>." >&2
        return 1
    fi

    SELECTED_PROVIDER="$provider"
    SELECTED_CLASS="$class"
    SELECTED_NAMESPACE="$namespace"
    SELECTED_SERVICE="$service"
    SELECTED_ADDRESS="$address"
    SELECTED_OWNED="false"
}

write_values() {
    mkdir -p "$STATE_DIR"
    cat > "$VALUES_FILE" <<EOF_VALUES
---
global:
    ingress:
        className: ${SELECTED_CLASS}
orchestration:
    ingress:
        grpc:
            className: ${SELECTED_CLASS}
EOF_VALUES
    if [[ "$SELECTED_PROVIDER" == "traefik" ]]; then
        cat >> "$VALUES_FILE" <<'EOF_TRAEFIK'
            annotations:
                traefik.ingress.kubernetes.io/service.serversscheme: h2c
EOF_TRAEFIK
    fi
}

saved_provider="$(state_get ingress_provider "")"
if [[ -n "$saved_provider" ]]; then
    if [[ "$REQUESTED_PROVIDER" != "auto" && "$REQUESTED_PROVIDER" != "$saved_provider" ]]; then
        echo "ERROR: this installation already selected ingress provider '$saved_provider'." >&2
        echo "Run 'make purge' before changing ingress providers." >&2
        exit 1
    fi

    SELECTED_PROVIDER="$saved_provider"
    SELECTED_CLASS="$(state_get ingress_class "")"
    SELECTED_NAMESPACE="$(state_get ingress_namespace "")"
    SELECTED_SERVICE="$(state_get ingress_service "")"
    SELECTED_ADDRESS="$(state_get ingress_external_address "")"
    SELECTED_OWNED="$(state_get ingress_installed_by_us false)"

    [[ -n "$SELECTED_CLASS" && -n "$SELECTED_NAMESPACE" && -n "$SELECTED_SERVICE" && -n "$SELECTED_ADDRESS" ]] || {
        echo "ERROR: ingress ownership state is incomplete; run 'make purge' and retry." >&2
        exit 1
    }
    kubectl get ingressclass "$SELECTED_CLASS" >/dev/null
    kubectl get service "$SELECTED_SERVICE" -n "$SELECTED_NAMESPACE" >/dev/null
    if [[ -n "$ADDRESS_OVERRIDE" ]]; then
        SELECTED_ADDRESS="$ADDRESS_OVERRIDE"
        state_set ingress_external_address "$SELECTED_ADDRESS"
    fi
    write_values
    echo "Reusing selected ingress: $SELECTED_PROVIDER ($SELECTED_CLASS), address $SELECTED_ADDRESS"
    exit 0
fi

# If a previous attempt got as far as claiming Contour but not far enough to
# persist generic ingress state, do not silently switch to a pre-existing
# controller. Purge first so ownership stays unambiguous.
if state_true contour_installed_by_us; then
    echo "ERROR: a partial Contour installation is owned by this install state." >&2
    echo "Run 'make purge' before retrying ingress auto-detection." >&2
    exit 1
fi

traefik_class="$(find_ingress_class 'traefik.io/ingress-controller' traefik || true)"
contour_class="$(find_ingress_class 'projectcontour.io/ingress-controller' contour || true)"

try_traefik() {
    [[ -n "$traefik_class" ]] || return 1
    local service_ref
    service_ref="$(find_traefik_service)" || {
        echo "Traefik IngressClass '$traefik_class' exists, but its Service could not be identified." >&2
        return 1
    }
    select_existing traefik "$traefik_class" "$service_ref"
}

try_contour() {
    [[ -n "$contour_class" ]] || return 1
    local service_ref
    service_ref="$(find_contour_service)" || {
        echo "Contour IngressClass '$contour_class' exists, but service projectcontour/contour-envoy was not found." >&2
        return 1
    }
    select_existing contour "$contour_class" "$service_ref"
}

case "$REQUESTED_PROVIDER" in
    auto)
        if try_traefik; then
            :
        elif try_contour; then
            :
        else
            existing_classes="$(kubectl get ingressclass -o name 2>/dev/null || true)"
            if [[ -n "$existing_classes" ]]; then
                echo "ERROR: ingress controllers exist, but none is a usable supported Traefik/Contour installation." >&2
                echo "Detected IngressClasses:" >&2
                kubectl get ingressclass >&2 || true
                echo "Use --mode no-domain, or configure a supported controller before retrying." >&2
                exit 1
            fi
            echo "No supported ingress controller found; installing local Contour fallback..."
            "$SCRIPT_DIR/contour-deploy.sh"
            SELECTED_PROVIDER="contour"
            SELECTED_CLASS="contour"
            SELECTED_NAMESPACE="projectcontour"
            SELECTED_SERVICE="contour-envoy"
            SELECTED_ADDRESS="${ADDRESS_OVERRIDE:-127.0.0.1}"
            SELECTED_OWNED="true"
        fi
        ;;
    traefik)
        if ! try_traefik; then
            echo "ERROR: --ingress-provider traefik requires a usable existing Traefik controller." >&2
            exit 1
        fi
        ;;
    contour)
        if try_contour; then
            :
        elif [[ -n "$contour_class" ]]; then
            echo "ERROR: an existing Contour controller was detected but is not usable by this reference." >&2
            echo "Fix its Service/address (or pass --ingress-address) instead of installing a second Contour." >&2
            exit 1
        else
            other_classes="$(kubectl get ingressclass -o name 2>/dev/null || true)"
            if [[ -n "$other_classes" ]]; then
                echo "ERROR: another ingress controller already exists; refusing to install a second host-networked Contour." >&2
                echo "Use --ingress-provider auto to reuse a supported controller." >&2
                exit 1
            fi
            "$SCRIPT_DIR/contour-deploy.sh"
            SELECTED_PROVIDER="contour"
            SELECTED_CLASS="contour"
            SELECTED_NAMESPACE="projectcontour"
            SELECTED_SERVICE="contour-envoy"
            SELECTED_ADDRESS="${ADDRESS_OVERRIDE:-127.0.0.1}"
            SELECTED_OWNED="true"
        fi
        ;;
esac

state_set ingress_provider "$SELECTED_PROVIDER"
state_set ingress_class "$SELECTED_CLASS"
state_set ingress_namespace "$SELECTED_NAMESPACE"
state_set ingress_service "$SELECTED_SERVICE"
state_set ingress_service_fqdn "${SELECTED_SERVICE}.${SELECTED_NAMESPACE}.svc.cluster.local"
state_set ingress_external_address "$SELECTED_ADDRESS"
state_set ingress_installed_by_us "$SELECTED_OWNED"
if [[ "$SELECTED_PROVIDER" == "contour" && "$SELECTED_OWNED" == "false" ]]; then
    state_set contour_installed_by_us false
fi

write_values

echo "Ingress selected:"
echo "  provider: $SELECTED_PROVIDER"
echo "  class:    $SELECTED_CLASS"
echo "  service:  $SELECTED_NAMESPACE/$SELECTED_SERVICE"
echo "  address:  $SELECTED_ADDRESS"
if [[ "$SELECTED_OWNED" == "true" ]]; then
    echo "  ownership: installed by this reference (removed by purge)"
else
    echo "  ownership: pre-existing (left untouched by purge)"
fi

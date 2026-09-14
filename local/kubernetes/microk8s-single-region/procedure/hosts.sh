#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ACTION="${1:-}"
MARKER="# camunda-microk8s-reference"

if [[ "$ACTION" != "remove" ]] && grep -Fq "$MARKER" /etc/hosts \
    && ! state_true hosts_domain_touched && ! state_true hosts_keycloak_touched; then
    echo "ERROR: Camunda MicroK8s /etc/hosts marker exists but is not owned by this install state." >&2
    echo "Refusing to adopt it because purge must not remove pre-existing configuration." >&2
    exit 1
fi

host_has_mapping() {
    local host="$1" address="$2"
    awk -v host="$host" -v address="$address" '
        $1 == address {
            for (i = 2; i <= NF; i++) {
                if ($i == "#") break
                if ($i == host) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' /etc/hosts
}

host_exists() {
    local host="$1"
    awk -v host="$host" '
        {
            for (i = 2; i <= NF; i++) {
                if ($i == "#") break
                if ($i == host) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' /etc/hosts
}

add_host() {
    local host="$1" address="$2"
    if host_has_mapping "$host" "$address"; then
        echo "Host '$host' already resolves to $address; leaving the existing entry untouched."
        return
    fi
    if host_exists "$host"; then
        echo "ERROR: '$host' already exists in /etc/hosts with a different mapping." >&2
        echo "Refusing to replace a pre-existing entry." >&2
        exit 1
    fi
    printf '%s %s %s\n' "$address" "$host" "$MARKER" | sudo tee -a /etc/hosts >/dev/null
    echo "Added /etc/hosts entry: $address $host"
}

case "$ACTION" in
    add-domain)
        ingress_address="$(state_get ingress_external_address "")"
        if [[ -z "$ingress_address" ]]; then
            echo "ERROR: ingress external address is missing. Run make ingress.configure first." >&2
            exit 1
        fi
        add_host camunda.example.com "$ingress_address"
        add_host zeebe-camunda.example.com "$ingress_address"
        state_set hosts_domain_touched true
        ;;
    add-keycloak)
        add_host keycloak-service 127.0.0.1
        state_set hosts_keycloak_touched true
        ;;
    remove)
        if grep -Fq "$MARKER" /etc/hosts; then
            sudo sed -i "\|$MARKER|d" /etc/hosts
        fi
        state_set hosts_domain_touched false
        state_set hosts_keycloak_touched false
        echo "Camunda-managed /etc/hosts entries removed."
        ;;
    *)
        echo "Usage: $0 {add-domain|add-keycloak|remove}" >&2
        exit 2
        ;;
esac

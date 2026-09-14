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

add_host() {
    local host="$1"
    if grep -Eq "^[[:space:]]*127\.0\.0\.1[[:space:]]+${host//./\\.}([[:space:]]|$)" /etc/hosts; then
        echo "Host '$host' already resolves to 127.0.0.1; leaving the existing entry untouched."
        return
    fi
    if grep -Eq "(^|[[:space:]])${host//./\\.}([[:space:]]|$)" /etc/hosts; then
        echo "ERROR: '$host' already exists in /etc/hosts with a non-local mapping." >&2
        echo "Refusing to add a conflicting entry." >&2
        exit 1
    fi
    printf '127.0.0.1 %s %s\n' "$host" "$MARKER" | sudo tee -a /etc/hosts >/dev/null
    echo "Added /etc/hosts entry for $host."
}

case "$ACTION" in
    add-domain)
        add_host camunda.example.com
        add_host zeebe-camunda.example.com
        state_set hosts_domain_touched true
        ;;
    add-keycloak)
        add_host keycloak-service
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

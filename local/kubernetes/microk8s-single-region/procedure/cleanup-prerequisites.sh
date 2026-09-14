#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.tools"
BOOTSTRAP_STATE="$TOOLS_DIR/bootstrap-state"

bootstrap_get() {
    local key="$1" default="${2:-}"
    if [[ -f "$BOOTSTRAP_STATE" ]]; then
        local value
        value="$(grep -F "${key}=" "$BOOTSTRAP_STATE" | tail -n1 | cut -d= -f2- || true)"
        [[ -n "$value" ]] && { printf '%s\n' "$value"; return; }
    fi
    printf '%s\n' "$default"
}

strict="${PURGE_PREREQUISITES:-0}"
platform="$(bootstrap_get platform "")"

if [[ "$strict" == "1" && -f "$BOOTSTRAP_STATE" ]]; then
    echo "Removing host prerequisites installed by the bootstrap..."

    if [[ "$(bootstrap_get microk8s_installed_by_us false)" == "true" ]]; then
        case "$platform" in
            linux)
                if command -v snap >/dev/null 2>&1 && snap list microk8s >/dev/null 2>&1; then
                    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
                        snap remove microk8s || true
                    else
                        sudo snap remove microk8s || true
                    fi
                fi
                ;;
            darwin)
                command -v microk8s >/dev/null 2>&1 && microk8s uninstall || true
                command -v brew >/dev/null 2>&1 && brew uninstall ubuntu/microk8s/microk8s || true
                ;;
        esac
    fi

    if [[ "$platform" == "linux" ]]; then
        apt_packages="$(bootstrap_get apt_packages_installed_by_us "")"
        if [[ -n "$apt_packages" ]] && command -v apt-get >/dev/null 2>&1; then
            # Remove exactly the packages that were absent before bootstrap. Do
            # not run autoremove: transitive/system cleanup is outside our ownership.
            if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
                apt-get remove -y -- $apt_packages || true
            else
                sudo apt-get remove -y -- $apt_packages || true
            fi
        fi
    elif [[ "$platform" == "darwin" ]]; then
        brew_packages="$(bootstrap_get brew_packages_installed_by_us "")"
        if [[ -n "$brew_packages" ]] && command -v brew >/dev/null 2>&1; then
            brew uninstall $brew_packages || true
        fi
    fi
fi

# Helm, mkcert and the kubectl/microk8s wrappers are deliberately repo-local.
rm -rf "$TOOLS_DIR"
if [[ "$strict" == "1" ]]; then
    echo "✓ Bootstrap tools and owned host prerequisites cleaned."
else
    echo "✓ Repo-local bootstrap tools cleaned."
fi

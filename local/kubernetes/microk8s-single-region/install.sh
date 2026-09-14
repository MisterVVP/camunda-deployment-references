#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

MODE="domain"
SECONDARY_STORAGE="elasticsearch"
ASSUME_YES=false
SKIP_PREREQUISITES=false

usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]

Golden-path local Camunda installation on MicroK8s.

Options:
  --secondary-storage elasticsearch|postgres  Default: elasticsearch
  --mode domain|no-domain                     Default: domain
  --yes, -y                                   Accept prerequisite installation
  --skip-prerequisites                        Only run prerequisite checks
  --help, -h                                  Show this help

Examples:
  ./install.sh
  ./install.sh --yes
  ./install.sh --secondary-storage postgres
  ./install.sh --mode no-domain --secondary-storage postgres
USAGE
}

while (($#)); do
    case "$1" in
        --secondary-storage)
            [[ $# -ge 2 ]] || { echo "ERROR: --secondary-storage needs a value." >&2; exit 2; }
            SECONDARY_STORAGE="$2"
            shift 2
            ;;
        --mode)
            [[ $# -ge 2 ]] || { echo "ERROR: --mode needs a value." >&2; exit 2; }
            MODE="$2"
            shift 2
            ;;
        --yes|-y)
            ASSUME_YES=true
            shift
            ;;
        --skip-prerequisites)
            SKIP_PREREQUISITES=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$SECONDARY_STORAGE" == "elasticsearch" || "$SECONDARY_STORAGE" == "postgres" ]] || {
    echo "ERROR: --secondary-storage must be elasticsearch or postgres." >&2
    exit 2
}
[[ "$MODE" == "domain" || "$MODE" == "no-domain" ]] || {
    echo "ERROR: --mode must be domain or no-domain." >&2
    exit 2
}

# The current reference deliberately owns Linux host networking, /etc/hosts and
# MicroK8s hostpath cleanup. MicroK8s on macOS/Windows runs in a VM, so pretending
# those platforms are equivalent would make purge guarantees false.
case "$(uname -s)" in
    Linux)
        if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
            echo "ERROR: the golden deployment path is not yet supported inside WSL." >&2
            echo "       Run this reference on native Linux/Ubuntu." >&2
            exit 2
        fi
        ;;
    Darwin)
        echo "ERROR: the golden deployment path currently supports native Linux only." >&2
        echo "       The prerequisite installer can bootstrap macOS tooling, but MicroK8s" >&2
        echo "       runs in a VM there and needs separate ingress/cleanup semantics." >&2
        exit 2
        ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "ERROR: the golden deployment path currently supports native Linux only." >&2
        echo "       Run ./procedure/install-prerequisites.sh for Windows/WSL guidance." >&2
        exit 2
        ;;
    *)
        echo "ERROR: unsupported host OS: $(uname -s)" >&2
        exit 2
        ;;
esac

if [[ "$SKIP_PREREQUISITES" == "true" ]]; then
    ./procedure/install-prerequisites.sh --check
else
    prereq_args=()
    [[ "$ASSUME_YES" == "true" ]] && prereq_args+=(--yes)
    ./procedure/install-prerequisites.sh "${prereq_args[@]}"
fi

export SECONDARY_STORAGE
exec make "${MODE}.init"

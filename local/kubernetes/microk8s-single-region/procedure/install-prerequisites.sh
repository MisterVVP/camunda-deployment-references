#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CHECK_ONLY=false
ASSUME_YES=false
MICROK8S_CHANNEL="${MICROK8S_CHANNEL:-1.35/stable}"
HELM_VERSION="${HELM_VERSION:-v3.22.0}"
MKCERT_VERSION="${MKCERT_VERSION:-v1.4.4}"
BOOTSTRAP_STATE="$TOOLS_DIR/bootstrap-state"
TOOLS_BIN="$TOOLS_DIR/bin"

usage() {
    cat <<'USAGE'
Usage: ./procedure/install-prerequisites.sh [--check] [--yes]

Installs/checks prerequisites for the local MicroK8s reference.

  --check   Do not install anything; fail if a prerequisite is missing.
  --yes     Accept package installation without prompting.
USAGE
}

while (($#)); do
    case "$1" in
        --check) CHECK_ONLY=true ;;
        --yes|-y) ASSUME_YES=true ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

bootstrap_get() {
    local key="$1" default="${2:-}"
    if [[ -f "$BOOTSTRAP_STATE" ]]; then
        local value
        value="$(grep -F "${key}=" "$BOOTSTRAP_STATE" | tail -n1 | cut -d= -f2- || true)"
        [[ -n "$value" ]] && { printf '%s\n' "$value"; return; }
    fi
    printf '%s\n' "$default"
}

bootstrap_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$TOOLS_DIR"
    tmp="$(mktemp "$TOOLS_DIR/bootstrap-state.XXXXXX")"
    [[ -f "$BOOTSTRAP_STATE" ]] && grep -v -F "${key}=" "$BOOTSTRAP_STATE" > "$tmp" || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$BOOTSTRAP_STATE"
}

bootstrap_add_words() {
    local key="$1"; shift
    local existing word combined
    existing="$(bootstrap_get "$key" "")"
    combined="$existing"
    for word in "$@"; do
        [[ " $combined " == *" $word "* ]] || combined="${combined:+$combined }$word"
    done
    bootstrap_set "$key" "$combined"
}

confirm() {
    local prompt="$1"
    [[ "$ASSUME_YES" == "true" ]] && return 0
    if [[ ! -t 0 ]]; then
        echo "ERROR: prerequisite installation needs confirmation." >&2
        echo "       Re-run with --yes for non-interactive installation." >&2
        exit 2
    fi
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

check_all() {
    local missing=() cmd
    for cmd in microk8s kubectl helm curl git make openssl mkcert envsubst; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ((${#missing[@]})); then
        echo "ERROR: missing prerequisites: ${missing[*]}" >&2
        echo "       Run ./install.sh (golden path) or make prerequisites." >&2
        return 1
    fi
    echo "✓ Prerequisites available"
}

sudo_prefix() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        printf '%s\n' ""
    else
        command -v sudo >/dev/null 2>&1 || {
            echo "ERROR: sudo is required to install missing host packages." >&2
            exit 1
        }
        printf '%s\n' "sudo"
    fi
}

platform_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' amd64 ;;
        aarch64|arm64) printf '%s\n' arm64 ;;
        *) echo "ERROR: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    esac
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

install_helm_local() {
    [[ -x "$TOOLS_BIN/helm" ]] && return
    local os="$1" arch archive url expected actual tmp
    arch="$(platform_arch)"
    archive="helm-${HELM_VERSION}-${os}-${arch}.tar.gz"
    url="https://get.helm.sh/${archive}"
    tmp="$(mktemp -d)"
    echo "Installing Helm ${HELM_VERSION} into .tools/bin..."
    curl -fsSL "$url" -o "$tmp/$archive"
    expected="$(curl -fsSL "$url.sha256sum" | awk '{print $1}')"
    actual="$(sha256_file "$tmp/$archive")"
    [[ "$actual" == "$expected" ]] || {
        echo "ERROR: Helm checksum mismatch." >&2
        exit 1
    }
    tar -xzf "$tmp/$archive" -C "$tmp"
    mkdir -p "$TOOLS_BIN"
    cp "$tmp/${os}-${arch}/helm" "$TOOLS_BIN/helm"
    chmod 0755 "$TOOLS_BIN/helm"
    rm -rf "$tmp"
}

install_mkcert_local() {
    [[ -x "$TOOLS_BIN/mkcert" ]] && return
    local os="$1" arch
    arch="$(platform_arch)"
    mkdir -p "$TOOLS_BIN"
    echo "Installing mkcert ${MKCERT_VERSION} into .tools/bin..."
    curl -fsSL "https://dl.filippo.io/mkcert/${MKCERT_VERSION}?for=${os}/${arch}" \
        -o "$TOOLS_BIN/mkcert"
    chmod 0755 "$TOOLS_BIN/mkcert"
}

write_microk8s_wrappers() {
    local real_microk8s="$1"
    mkdir -p "$TOOLS_BIN"
    cat > "$TOOLS_BIN/microk8s" <<EOF_WRAPPER
#!/usr/bin/env bash
set -euo pipefail
if "$real_microk8s" status >/dev/null 2>&1; then
    exec "$real_microk8s" "\$@"
fi
exec sudo "$real_microk8s" "\$@"
EOF_WRAPPER
    chmod 0755 "$TOOLS_BIN/microk8s"

    cat > "$TOOLS_BIN/kubectl" <<'EOF_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
exec microk8s kubectl "$@"
EOF_KUBECTL
    chmod 0755 "$TOOLS_BIN/kubectl"
}

install_linux() {
    if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        echo "ERROR: WSL is detected. The dependency bootstrap can run there, but" >&2
        echo "       this reference's TLS/host-network/purge guarantees are for native Linux." >&2
        echo "       Use native Ubuntu for the golden path." >&2
        exit 2
    fi

    command -v apt-get >/dev/null 2>&1 || {
        echo "ERROR: automatic Linux bootstrap currently supports Debian/Ubuntu (apt) only." >&2
        echo "       Other Linux distributions may use the same repo-local Helm/mkcert setup," >&2
        echo "       but host package installation is not automated yet." >&2
        exit 2
    }

    local sudo_cmd
    sudo_cmd="$(sudo_prefix)"
    local packages=(curl git make openssl ca-certificates tar gzip libnss3-tools)
    command -v snap >/dev/null 2>&1 || packages+=(snapd)
    local missing=() pkg
    for pkg in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' || missing+=("$pkg")
    done

    local need_microk8s=false
    [[ -x /snap/bin/microk8s ]] || need_microk8s=true

    echo "Prerequisite bootstrap will:"
    ((${#missing[@]})) && echo "  - install apt packages: ${missing[*]}"
    [[ "$need_microk8s" == "true" ]] && echo "  - install MicroK8s from channel ${MICROK8S_CHANNEL}"
    echo "  - install pinned Helm and mkcert binaries under .tools/bin"
    echo "  - use MicroK8s' bundled kubectl (no global kubectl install)"
    if ! confirm "Continue?"; then
        echo "Aborted."
        exit 1
    fi

    if ((${#missing[@]})); then
        $sudo_cmd apt-get update
        $sudo_cmd apt-get install -y "${missing[@]}"
        bootstrap_add_words apt_packages_installed_by_us "${missing[@]}"
    fi

    if [[ "$need_microk8s" == "true" ]]; then
        $sudo_cmd snap install microk8s --classic --channel="$MICROK8S_CHANNEL"
        bootstrap_set microk8s_installed_by_us true
    elif [[ "$(bootstrap_get microk8s_installed_by_us __unset__)" == "__unset__" ]]; then
        bootstrap_set microk8s_installed_by_us false
    fi

    [[ -x /snap/bin/microk8s ]] || {
        echo "ERROR: MicroK8s was not found at /snap/bin/microk8s after installation." >&2
        exit 1
    }
    write_microk8s_wrappers /snap/bin/microk8s
    microk8s start >/dev/null 2>&1 || true
    microk8s status --wait-ready >/dev/null

    install_helm_local linux
    install_mkcert_local linux
    bootstrap_set platform linux
    bootstrap_set completed true
}

install_macos() {
    echo "macOS dependency bootstrap is best-effort only; the deployment golden path"
    echo "remains native Linux because MicroK8s runs inside a VM on macOS."
    if ! command -v brew >/dev/null 2>&1; then
        confirm "Homebrew is required on macOS. Install Homebrew now?" || exit 1
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [[ -x /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -x /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi

    local brew_packages=() pkg
    for pkg in git openssl nss; do
        brew list "$pkg" >/dev/null 2>&1 || brew_packages+=("$pkg")
    done
    if ((${#brew_packages[@]})); then
        confirm "Install Homebrew packages: ${brew_packages[*]}?" || exit 1
        brew install "${brew_packages[@]}"
        bootstrap_add_words brew_packages_installed_by_us "${brew_packages[@]}"
    fi

    if ! command -v microk8s >/dev/null 2>&1; then
        confirm "Install the Canonical MicroK8s macOS launcher?" || exit 1
        brew install ubuntu/microk8s/microk8s
        bootstrap_set microk8s_installed_by_us true
    elif [[ "$(bootstrap_get microk8s_installed_by_us __unset__)" == "__unset__" ]]; then
        bootstrap_set microk8s_installed_by_us false
    fi

    if ! microk8s status >/dev/null 2>&1; then
        echo "Creating the MicroK8s VM..."
        microk8s install
    fi
    local real_microk8s
    real_microk8s="$(command -v microk8s)"
    write_microk8s_wrappers "$real_microk8s"
    install_helm_local darwin
    install_mkcert_local darwin
    bootstrap_set platform darwin
    bootstrap_set completed true
}

install_windows_guidance() {
    echo "Native Windows detected." >&2
    echo "This repository is a Bash/Make reference and its current zero-leftover purge" >&2
    echo "assumes Linux hostpath storage. Canonical's Windows MicroK8s installer runs" >&2
    echo "MicroK8s in a VM, so silently installing CLI packages would not make the" >&2
    echo "deployment safe or equivalent." >&2
    echo "" >&2
    echo "Use a native Ubuntu host for the current golden path. Windows/macOS VM-aware" >&2
    echo "networking and cleanup should be added as a separate supported topology." >&2
    exit 2
}

if [[ "$CHECK_ONLY" == "true" ]]; then
    check_all
    exit
fi

case "$(uname -s)" in
    Linux) install_linux ;;
    Darwin) install_macos ;;
    MINGW*|MSYS*|CYGWIN*) install_windows_guidance ;;
    *) echo "ERROR: unsupported OS: $(uname -s)" >&2; exit 2 ;;
esac

check_all

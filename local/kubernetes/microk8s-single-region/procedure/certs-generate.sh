#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd mkcert
cd "$ROOT_DIR"

CAROOT="$(mkcert -CAROOT 2>/dev/null)"
if [[ "$(state_get mkcert_ca_preexisting __unset__)" == "__unset__" ]]; then
    state_set mkcert_caroot "$CAROOT"
    if [[ -d "$CAROOT" ]]; then
        state_set mkcert_caroot_dir_preexisting true
    else
        state_set mkcert_caroot_dir_preexisting false
    fi
    if [[ -f "$CAROOT/rootCA.pem" ]]; then
        state_set mkcert_ca_preexisting true
    else
        state_set mkcert_ca_preexisting false
    fi
fi

mkcert -install
state_set mkcert_touched true

mkdir -p .certs
mkcert \
    -cert-file .certs/tls.crt \
    -key-file .certs/tls.key \
    "camunda.example.com" "*.camunda.example.com" "zeebe-camunda.example.com"

echo "Certificates generated in $ROOT_DIR/.certs/"

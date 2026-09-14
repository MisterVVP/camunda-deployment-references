#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

KIND_DIR="$(cd "$ROOT_DIR/../kind-single-region" && pwd)"

HELPER="${1:-}"
shift || true
[[ -n "$HELPER" && -x "$KIND_DIR/procedure/$HELPER" ]] || {
    echo "ERROR: unknown shared helper '$HELPER'." >&2
    exit 2
}

cd "$KIND_DIR"
exec "./procedure/$HELPER" "$@"

#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_kubeconfig
require_cmd kubectl
require_cmd python3

ACTION="${1:-add}"
BEGIN_MARKER="# BEGIN camunda-microk8s-reference"
END_MARKER="# END camunda-microk8s-reference"
CURRENT="$STATE_DIR/coredns-current.corefile"
UPDATED="$STATE_DIR/coredns-updated.corefile"

kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' > "$CURRENT"

if [[ "$ACTION" == "add" ]] && grep -Fq "$BEGIN_MARKER" "$CURRENT" && ! state_true coredns_modified_by_us; then
    echo "ERROR: the Camunda MicroK8s CoreDNS marker already exists but is not owned by this install state." >&2
    echo "Refusing to adopt it because purge must not remove pre-existing configuration." >&2
    exit 1
fi

python3 - "$ACTION" "$CURRENT" "$UPDATED" "$BEGIN_MARKER" "$END_MARKER" <<'PY'
from pathlib import Path
import re
import sys

action, current_path, updated_path, begin, end = sys.argv[1:]
text = Path(current_path).read_text()

block_re = re.compile(
    rf"(?ms)^[ \t]*{re.escape(begin)}\n.*?^[ \t]*{re.escape(end)}\n?"
)

if action == "remove":
    new = block_re.sub("", text)
elif action == "add":
    if begin in text:
        new = text
    else:
        lines = text.splitlines(keepends=True)
        idx = next(
            (i for i, line in enumerate(lines)
             if re.match(r"^\s*\.\s*:\s*53\s*\{\s*$", line.rstrip("\n"))),
            None,
        )
        if idx is None:
            raise SystemExit("ERROR: could not locate the '.:53 {' CoreDNS server block")
        indent = "    "
        block = (
            f"{indent}{begin}\n"
            f"{indent}rewrite name substring zeebe-camunda.example.com contour-envoy.projectcontour.svc.cluster.local answer auto\n"
            f"{indent}rewrite name substring camunda.example.com contour-envoy.projectcontour.svc.cluster.local answer auto\n"
            f"{indent}{end}\n"
        )
        lines.insert(idx + 1, block)
        new = "".join(lines)
else:
    raise SystemExit(f"ERROR: unsupported action: {action}")

Path(updated_path).write_text(new)
PY

patch="$(
    python3 - "$UPDATED" <<'PY'
import json
from pathlib import Path
import sys
print(json.dumps({"data": {"Corefile": Path(sys.argv[1]).read_text()}}))
PY
)"

kubectl patch configmap coredns -n kube-system --type merge -p "$patch" >/dev/null
kubectl rollout restart deployment/coredns -n kube-system >/dev/null
kubectl rollout status deployment/coredns -n kube-system --timeout=180s >/dev/null

if [[ "$ACTION" == "add" ]]; then
    state_set coredns_modified_by_us true
    echo "CoreDNS configured for camunda.example.com."
else
    state_set coredns_modified_by_us false
    echo "Camunda CoreDNS entries removed."
fi

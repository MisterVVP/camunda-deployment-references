#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_kubeconfig
require_cmd kubectl
require_cmd microk8s
require_cmd openssl
require_cmd sudo

CERT_PATH="/var/snap/microk8s/current/certs/kubelet.crt"
KEY_PATH="/var/snap/microk8s/current/certs/kubelet.key"
CA_PATH="/var/snap/microk8s/current/certs/ca.crt"
CA_KEY_PATH="/var/snap/microk8s/current/certs/ca.key"
REPAIR_MODE="${MICROK8S_CERT_REPAIR:-prompt}"

case "$REPAIR_MODE" in
    prompt|yes|no) ;;
    *)
        echo "ERROR: MICROK8S_CERT_REPAIR must be prompt, yes, or no (got '$REPAIR_MODE')." >&2
        exit 2
        ;;
esac

mapfile -t nodes < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if ((${#nodes[@]} != 1)); then
    echo "ERROR: this local reference can only auto-repair kubelet TLS on a single-node MicroK8s cluster." >&2
    echo "       Detected ${#nodes[@]} nodes. Repair kubelet certificates on the affected node(s) manually." >&2
    exit 1
fi
node="${nodes[0]}"

mapfile -t internal_ips < <(
    kubectl get node "$node" \
        -o jsonpath='{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}'
)
if ((${#internal_ips[@]} == 0)); then
    echo "ERROR: node '$node' has no InternalIP; cannot validate its kubelet serving certificate." >&2
    exit 1
fi

for path in "$CERT_PATH" "$KEY_PATH" "$CA_PATH" "$CA_KEY_PATH"; do
    if ! sudo test -e "$path"; then
        echo "ERROR: expected MicroK8s file is missing: $path" >&2
        exit 1
    fi
done

cert_sans="$(sudo openssl x509 -in "$CERT_PATH" -noout -ext subjectAltName 2>/dev/null || true)"
missing_ips=()
for ip in "${internal_ips[@]}"; do
    if ! grep -Fq "IP Address:$ip" <<<"$cert_sans"; then
        missing_ips+=("$ip")
    fi
done

chain_ok=true
sudo openssl verify -CAfile "$CA_PATH" "$CERT_PATH" >/dev/null 2>&1 || chain_ok=false
not_expired=true
sudo openssl x509 -checkend 0 -noout -in "$CERT_PATH" >/dev/null 2>&1 || not_expired=false

if ((${#missing_ips[@]} == 0)) && [[ "$chain_ok" == "true" && "$not_expired" == "true" ]]; then
    echo "MicroK8s kubelet certificate matches node InternalIP(s): ${internal_ips[*]}"
    exit 0
fi

echo "WARNING: MicroK8s kubelet serving certificate is stale or invalid." >&2
echo "  node:          $node" >&2
echo "  InternalIP(s): ${internal_ips[*]}" >&2
if ((${#missing_ips[@]})); then
    echo "  missing SANs:  ${missing_ips[*]}" >&2
fi
[[ "$chain_ok" == "true" ]] || echo "  CA verification: failed" >&2
[[ "$not_expired" == "true" ]] || echo "  expiration:      expired/not yet valid" >&2

echo >&2
echo "This breaks API-server -> kubelet TLS, including kubectl logs/exec." >&2
echo "The repair keeps the existing MicroK8s CA and kubelet private key, regenerates" >&2
echo "only kubelet.crt with the current node hostname/InternalIP SANs, and restarts kubelite." >&2

case "$REPAIR_MODE" in
    no)
        echo "ERROR: certificate repair was disabled (MICROK8S_CERT_REPAIR=no)." >&2
        exit 1
        ;;
    prompt)
        if [[ ! -t 0 ]]; then
            echo "ERROR: non-interactive install cannot ask permission to repair the kubelet certificate." >&2
            echo "       Rerun with ./install.sh --yes or MICROK8S_CERT_REPAIR=yes." >&2
            exit 1
        fi
        read -r -p "Repair the stale MicroK8s kubelet certificate now? [Y/n] " reply
        case "$reply" in
            ""|y|Y|yes|YES|Yes) ;;
            *) echo "ERROR: kubelet certificate repair declined." >&2; exit 1 ;;
        esac
        ;;
    yes) ;;
esac

mkdir -p "$STATE_DIR"
new_cert="$STATE_DIR/kubelet.crt.new"
backup_cert="$STATE_DIR/kubelet.crt.before-camunda"
rm -f "$new_cert"
sudo rm -f "$backup_cert"

# Keep a temporary public-certificate backup only for rollback during this repair.
# The private key and cluster CA are never copied or changed.
sudo cp -a "$CERT_PATH" "$backup_cert"

# Build the replacement certificate directly with OpenSSL. Do not source
# MicroK8s private shell helpers: those helpers assume they were launched by
# snapd and depend on a large Snap runtime environment. The certificate itself
# is simple: preserve the existing kubelet key and cluster CA, use the same
# system:node identity, and include the current node hostname/InternalIP SANs.
hostname="$(hostname | tr '[:upper:]' '[:lower:]')"
san_entries=("DNS:${hostname}")
for ip in "${internal_ips[@]}"; do
    san_entries+=("IP:${ip}")
done
san_csv="$(IFS=', '; echo "${san_entries[*]}")"

csr="$STATE_DIR/kubelet.csr.new"
extfile="$STATE_DIR/kubelet.ext.new"
rm -f "$csr" "$extfile"
printf 'subjectAltName = %s\n' "$san_csv" > "$extfile"

# The private kubelet key and CA key remain in place and are only read via sudo.
# Redirect stdout as the invoking user so no root-owned temporary files are left
# in .state/. Use an explicit random serial so signing does not create/modify a
# ca.srl file next to the MicroK8s CA.
sudo openssl req -new -sha256 \
    -subj "/CN=system:node:${hostname}/O=system:nodes" \
    -key "$KEY_PATH" \
    -addext "subjectAltName = ${san_csv}" > "$csr"

serial_hex="$(openssl rand -hex 16)"
sudo openssl x509 -req -sha256 \
    -in "$csr" \
    -CA "$CA_PATH" \
    -CAkey "$CA_KEY_PATH" \
    -set_serial "0x${serial_hex}" \
    -days 3650 \
    -extfile "$extfile" > "$new_cert"
chmod 600 "$new_cert"
rm -f "$csr" "$extfile"

new_sans="$(openssl x509 -in "$new_cert" -noout -ext subjectAltName 2>/dev/null || true)"
for ip in "${internal_ips[@]}"; do
    if ! grep -Fq "IP Address:$ip" <<<"$new_sans"; then
        sudo rm -f "$backup_cert"
        rm -f "$new_cert"
        echo "ERROR: MicroK8s generated a kubelet certificate that still lacks InternalIP $ip." >&2
        echo "       Refusing to install it. Check hostname/IP configuration before retrying." >&2
        exit 1
    fi
done

rollback() {
    echo "ERROR: repaired kubelet certificate did not become usable; restoring the previous certificate." >&2
    sudo install -o root -g root -m 600 "$backup_cert" "$CERT_PATH"
    sudo snap restart microk8s.daemon-kubelite >/dev/null || true
    microk8s status --wait-ready >/dev/null || true
    sudo rm -f "$backup_cert"
    rm -f "$new_cert"
}

sudo install -o root -g root -m 600 "$new_cert" "$CERT_PATH"
echo "Restarting MicroK8s kubelite to load the repaired kubelet certificate..."
sudo snap restart microk8s.daemon-kubelite >/dev/null
microk8s status --wait-ready >/dev/null

# Confirm the node is Ready again before testing the apiserver -> kubelet proxy.
ready=false
for _ in $(seq 1 60); do
    if [[ "$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]]; then
        ready=true
        break
    fi
    sleep 2
done
if [[ "$ready" != "true" ]]; then
    rollback
    exit 1
fi

# This request traverses the same API-server -> kubelet TLS path used by
# `kubectl logs` and `kubectl exec`, without depending on a particular workload.
proxy_ok=false
for _ in $(seq 1 30); do
    if kubectl get --raw "/api/v1/nodes/${node}/proxy/healthz" >/dev/null 2>&1; then
        proxy_ok=true
        break
    fi
    sleep 2
done
if [[ "$proxy_ok" != "true" ]]; then
    rollback
    exit 1
fi

old_fp="$(sudo openssl x509 -in "$backup_cert" -noout -fingerprint -sha256 | cut -d= -f2)"
new_fp="$(openssl x509 -in "$new_cert" -noout -fingerprint -sha256 | cut -d= -f2)"
state_set kubelet_cert_repaired true
state_set kubelet_cert_old_fingerprint "$old_fp"
state_set kubelet_cert_new_fingerprint "$new_fp"

sudo rm -f "$backup_cert"
rm -f "$new_cert"
echo "✓ MicroK8s kubelet certificate repaired and API-server -> kubelet TLS verified."

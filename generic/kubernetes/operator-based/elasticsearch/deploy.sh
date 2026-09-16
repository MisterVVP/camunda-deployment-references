#!/bin/bash
# elasticsearch/deploy.sh - Deploy Elasticsearch via ECK operator

set -euo pipefail

# Variables
CAMUNDA_NAMESPACE=${CAMUNDA_NAMESPACE:-camunda}
OPERATOR_NAMESPACE=${1:-elastic-system}
ELASTICSEARCH_CLUSTER_FILE=${ELASTICSEARCH_CLUSTER_FILE:-elasticsearch-cluster.yml}
ELASTICSEARCH_READY_TIMEOUT_SECONDS=${ELASTICSEARCH_READY_TIMEOUT_SECONDS:-600}

# renovate: datasource=github-releases depName=elastic/cloud-on-k8s
ECK_VERSION="3.4.1"

# Install ECK operator CRDs
kubectl apply --server-side -f \
  "https://download.elastic.co/downloads/eck/${ECK_VERSION}/crds.yaml"

# Create operator namespace if needed
kubectl create namespace "$OPERATOR_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Install ECK operator
kubectl apply -n "$OPERATOR_NAMESPACE" --server-side  -f \
  "https://download.elastic.co/downloads/eck/${ECK_VERSION}/operator.yaml"
echo "ECK operator deployed in namespace: $OPERATOR_NAMESPACE"

# Wait for operator to be ready
kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 --timeout=300s statefulset/elastic-operator -n "$OPERATOR_NAMESPACE"

# Deploy Elasticsearch cluster
kubectl apply -f "$ELASTICSEARCH_CLUSTER_FILE" -n "$CAMUNDA_NAMESPACE"

# Wait for Elasticsearch reconciliation with visible progress. A Running pod is
# not sufficient: ECK can still be applying configuration or waiting for the
# cluster to become ready.
echo "Waiting for Elasticsearch to become Ready..."
deadline=$((SECONDS + ELASTICSEARCH_READY_TIMEOUT_SECONDS))
last_status=""

dump_elasticsearch_diagnostics() {
  echo >&2
  echo "=== Elasticsearch resources ===" >&2
  kubectl get elasticsearch -n "$CAMUNDA_NAMESPACE" -o wide >&2 || true
  echo >&2
  echo "=== Elasticsearch pods ===" >&2
  kubectl get pods -n "$CAMUNDA_NAMESPACE" \
    -l elasticsearch.k8s.elastic.co/cluster-name \
    -o wide >&2 || true
  echo >&2
  echo "=== Recent Camunda namespace events ===" >&2
  kubectl get events -n "$CAMUNDA_NAMESPACE" \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -n 40 >&2 || true
  echo >&2
  echo "=== ECK operator logs (last 100 lines) ===" >&2
  kubectl logs -n "$OPERATOR_NAMESPACE" \
    statefulset/elastic-operator --tail=100 >&2 || true
}

while true; do
  raw_status="$(
    kubectl get elasticsearch -n "$CAMUNDA_NAMESPACE" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.status.health}{"|"}{.status.availableNodes}{"\n"}{end}' \
      2>/dev/null || true
  )"

  resource_count=0
  all_ready=true
  any_invalid=false
  display_status=""

  while IFS='|' read -r name phase health nodes; do
    [[ -n "$name" ]] || continue
    ((resource_count += 1))
    [[ "$phase" == "Ready" ]] || all_ready=false
    [[ "$phase" == "Invalid" ]] && any_invalid=true
    display_status+="${name} phase=${phase:-<pending>} health=${health:-<pending>} nodes=${nodes:-0}"$'\n'
  done <<<"$raw_status"

  if [[ "$display_status" != "$last_status" ]]; then
    if [[ -n "$display_status" ]]; then
      printf '%s' "$display_status"
    else
      echo "Elasticsearch status not reported by ECK yet..."
    fi
    last_status="$display_status"
  fi

  if (( resource_count > 0 )) && [[ "$all_ready" == "true" ]]; then
    break
  fi

  if [[ "$any_invalid" == "true" ]]; then
    echo "ERROR: ECK marked an Elasticsearch resource Invalid." >&2
    dump_elasticsearch_diagnostics
    exit 1
  fi

  if (( SECONDS >= deadline )); then
    echo "ERROR: Elasticsearch did not reach ECK phase Ready within ${ELASTICSEARCH_READY_TIMEOUT_SECONDS}s." >&2
    dump_elasticsearch_diagnostics
    exit 1
  fi

  sleep 5
done

echo "Elasticsearch deployment completed in namespace: $CAMUNDA_NAMESPACE"

#!/usr/bin/env bash
# Install the self-contained demo:
#   1. Vault -dev + status-api (local demo chart)
#   2. Datadog Agent (official datadog/datadog chart)
#   3. verification
set -euo pipefail

cd "$(dirname "$0")/.."

NAMESPACE="${NAMESPACE:-dd-vault-test}"
RELEASE="${RELEASE:-dd}"
CHART_VERSION="${DATADOG_CHART_VERSION:-3.264.0}"

helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
helm repo update datadog >/dev/null

echo "1. Installing the Vault/status-api demo chart..."
helm upgrade --install dd-vault-demo ./demo -n "$NAMESPACE" --create-namespace

echo "2. Waiting for Vault, the seed Job, and status-api..."
kubectl -n "$NAMESPACE" rollout status deploy/vault --timeout=180s
kubectl -n "$NAMESPACE" wait --for=condition=complete job/vault-seed --timeout=180s
kubectl -n "$NAMESPACE" rollout status deploy/status-api --timeout=180s

echo "3. Installing the official Datadog chart..."
helm upgrade --install "$RELEASE" datadog/datadog \
  --version "$CHART_VERSION" \
  -n "$NAMESPACE" \
  -f examples/values-dev.yaml

echo "4. Waiting for the Datadog Agent DaemonSet..."
kubectl -n "$NAMESPACE" rollout status ds/dd-agent --timeout=300s

echo "5. Verifying..."
./scripts/verify.sh "$RELEASE" "$NAMESPACE"

echo
echo "Demo installed in namespace ${NAMESPACE}."
echo "Official chart release: ${RELEASE}"
echo "Cleanup:"
echo "  helm uninstall ${RELEASE} -n ${NAMESPACE}"
echo "  helm uninstall dd-vault-demo -n ${NAMESPACE}"
echo "  kubectl delete namespace ${NAMESPACE}"

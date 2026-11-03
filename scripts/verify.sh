#!/usr/bin/env bash
# Verify the chart's Agent, Vault resolution, and status-api check.
#
# Usage: scripts/verify.sh [release] [namespace]
set -euo pipefail

cd "$(dirname "$0")/.."

RELEASE="${1:-ddv}"
NAMESPACE="${2:-dd-vault-test}"
STATUS_USER="${STATUS_USER:-testuser}"
STATUS_PASS="${STATUS_PASS:-testpass}"

common=(-n "$NAMESPACE")
agent_selector="app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=agent"

echo "=== Pods ==="
kubectl "${common[@]}" get pods

AGENT_DEPLOY=$(kubectl "${common[@]}" get deploy -l "$agent_selector" \
  -o jsonpath='{.items[0].metadata.name}')
if [ -z "$AGENT_DEPLOY" ]; then
  echo "ERROR: Agent deployment not found" >&2
  exit 1
fi

echo
echo "=== Agent rollout ==="
kubectl "${common[@]}" rollout status deploy/"$AGENT_DEPLOY" --timeout=300s

AGENT_POD=$(kubectl "${common[@]}" get pod -l "$agent_selector" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

echo
echo "=== Waiting for the Agent API ==="
for _ in $(seq 1 60); do
  if kubectl "${common[@]}" exec "$AGENT_POD" -c datadog-agent -- agent status >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo
echo "=== Resolved secrets ==="
kubectl "${common[@]}" exec "$AGENT_POD" -c datadog-agent -- agent secret | tail -30

echo
echo "=== http_check configuration ==="
kubectl "${common[@]}" exec "$AGENT_POD" -c datadog-agent -- \
  sh -c 'grep -E "^[[:space:]]*url:" /etc/datadog-agent/conf.d/http_check.yaml || true'

URL=$(kubectl "${common[@]}" exec "$AGENT_POD" -c datadog-agent -- \
  sh -c 'awk "/^[[:space:]]*url:/ {print \$2; exit}" /etc/datadog-agent/conf.d/http_check.yaml')

if [ -n "$URL" ]; then
  echo
  echo "=== status-api without credentials ==="
  code=$(kubectl "${common[@]}" exec "$AGENT_POD" -c datadog-agent -- \
    curl -s -o /dev/null -w '%{http_code}' "$URL")
  echo "$URL -> $code"
  if [ "$code" != "401" ]; then
    echo "WARNING: expected 401 without credentials" >&2
  fi

  echo
  echo "=== status-api with credentials ==="
  code=$(kubectl "${common[@]}" exec "$AGENT_POD" -c datadog-agent -- \
    curl -s -o /dev/null -w '%{http_code}' -u "$STATUS_USER:$STATUS_PASS" "$URL")
  echo "$URL -> $code"
  if [ "$code" != "200" ]; then
    echo "WARNING: expected 200 with credentials" >&2
  fi
fi

echo
echo "=== Agent request log ==="
if kubectl "${common[@]}" logs "$AGENT_POD" --tail=500 2>&1 \
    | grep 'GET /api/detail HTTP/1.1" 200' >/dev/null; then
  echo "[OK] Agent reached status-api with 200"
else
  echo "No 200 request line found. Set datadog.logLevel=DEBUG and retry." >&2
fi

echo
echo "=== Agent status: status-api check ==="
kubectl "${common[@]}" exec "$AGENT_POD" -c datadog-agent -- agent status 2>&1 \
  | grep -A 6 'status-api detail' | head -8 || true

echo
echo "Verification complete."

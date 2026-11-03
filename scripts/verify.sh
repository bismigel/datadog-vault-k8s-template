#!/usr/bin/env bash
# Verify the official Datadog chart + Vault/status-api demo.
#
# Usage: scripts/verify.sh [release] [namespace]
set -euo pipefail

cd "$(dirname "$0")/.."

RELEASE="${1:-dd}"
NAMESPACE="${2:-dd-vault-test}"
STATUS_USER="${STATUS_USER:-testuser}"
STATUS_PASS="${STATUS_PASS:-testpass}"

common=(-n "$NAMESPACE")

echo "=== Pods ==="
kubectl "${common[@]}" get pods

echo
echo "=== Agent DaemonSet ==="
AGENT_DS=$(kubectl "${common[@]}" get ds -l app.kubernetes.io/component=agent \
  -o jsonpath='{.items[0].metadata.name}')
if [ -z "$AGENT_DS" ]; then
  echo "ERROR: Agent DaemonSet with label app=dd-agent not found" >&2
  exit 1
fi
kubectl "${common[@]}" rollout status ds/"$AGENT_DS" --timeout=300s

AGENT_POD=$(kubectl "${common[@]}" get pod -l app=dd-agent \
  -o jsonpath='{.items[0].metadata.name}')
if [ -z "$AGENT_POD" ]; then
  echo "ERROR: Agent pod not found" >&2
  exit 1
fi
echo "Agent pod: $AGENT_POD"

echo
echo "=== Waiting for the Agent API ==="
for _ in $(seq 1 60); do
  if kubectl "${common[@]}" exec "$AGENT_POD" -c agent -- agent status >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo
echo "=== Resolved secrets ==="
kubectl "${common[@]}" exec "$AGENT_POD" -c agent -- agent secret | tail -30

echo
echo "=== http_check configuration ==="
kubectl "${common[@]}" exec "$AGENT_POD" -c agent -- \
  sh -c 'grep -E "^[[:space:]]*url:" /etc/datadog-agent/conf.d/http_check.yaml || true'

URL=$(kubectl "${common[@]}" exec "$AGENT_POD" -c agent -- \
  sh -c 'awk "/^[[:space:]]*url:/ {print \$2; exit}" /etc/datadog-agent/conf.d/http_check.yaml')

if [ -n "$URL" ]; then
  echo
  echo "=== status-api without credentials ==="
  code=$(kubectl "${common[@]}" exec "$AGENT_POD" -c agent -- \
    curl -s -o /dev/null -w '%{http_code}' "$URL")
  echo "$URL -> $code"
  if [ "$code" != "401" ]; then
    echo "WARNING: expected 401 without credentials" >&2
  fi

  echo
  echo "=== status-api with credentials ==="
  code=$(kubectl "${common[@]}" exec "$AGENT_POD" -c agent -- \
    curl -s -o /dev/null -w '%{http_code}' -u "$STATUS_USER:$STATUS_PASS" "$URL")
  echo "$URL -> $code"
  if [ "$code" != "200" ]; then
    echo "WARNING: expected 200 with credentials" >&2
  fi
fi

echo
echo "=== Agent request log ==="
if kubectl "${common[@]}" logs "$AGENT_POD" -c agent --since=10m 2>&1 \
    | grep 'GET /api/detail HTTP/1.1" 200' >/dev/null; then
  echo "[OK] Agent reached status-api with 200"
else
  echo "No 200 request line found. Set datadog.logLevel=DEBUG and retry." >&2
fi

echo
echo "=== Agent status: status-api check ==="
kubectl "${common[@]}" exec "$AGENT_POD" -c agent -- agent status 2>&1 \
  | grep -A 6 'status-api detail' | head -8 || true

echo
echo "Verification complete."

# Learnings: Datadog Agent + Vault on Kubernetes

What was verified while switching this template to the **official
`datadog/datadog` Helm chart**.

## Test environment

| Component | Version |
| --- | --- |
| `datadog/datadog` chart | 3.264.0 |
| Datadog Agent | 7.84.6 (chart default) |
| HashiCorp Vault | 1.21.2 (`-dev`) |
| Kubernetes | 1.36 (k3s) |
| status-api | `ghcr.io/bismigel/status-api:latest` |

## 1. The official chart supports the native Vault backend

Use the chart's `datadog.secretBackend` values:

```yaml
datadog:
  secretBackend:
    type: "hashicorp.vault"
    config:
      vault_address: "http://vault:8200"
      vault_session:
        vault_auth_type: kubernetes
        vault_kubernetes_role: datadog-agent
        vault_kubernetes_mount_path: auth/kubernetes/login
    refreshInterval: 60
```

The chart renders these as Agent environment variables:

```text
DD_SECRET_BACKEND_TYPE=hashicorp.vault
DD_SECRET_BACKEND_CONFIG={"vault_address":"http://vault:8200","vault_session":{...}}
DD_SECRET_REFRESH_INTERVAL=60
```

No custom Agent Deployment or custom secret-backend script is needed.

## 2. `fullnameOverride` fixes the Agent ServiceAccount name

The demo Vault role must bind the official chart's Agent ServiceAccount. The
name depends on the chart's fullname. The demo values set:

```yaml
fullnameOverride: dd-agent
```

Result:

- ServiceAccount: `dd-agent`
- DaemonSet: `dd-agent`
- Agent pods label: `app=dd-agent`
- Agent container: `agent`

The demo seed Job creates:

```sh
vault write auth/kubernetes/role/datadog-agent \
  bound_service_account_names=dd-agent \
  bound_service_account_namespaces=<namespace> \
  policies=datadog-agent
```

If you change `fullnameOverride`, update the demo chart's
`agentServiceAccount` and the Vault role.

## 3. Disable operator, KSM, and Cluster Agent for the demo

The official chart is large by default. For this minimal demo:

```yaml
datadog:
  operator:
    enabled: false
  kubeStateMetricsEnabled: false

clusterAgent:
  enabled: false
```

- `datadog.operator.enabled` controls the `datadog-operator` subchart.
- `datadog.kubeStateMetricsEnabled` controls the `kube-state-metrics`
  subchart.
- `clusterAgent.enabled: false` avoids the Cluster Agent RBAC and warnings for
  a single-node-style demo.

The rendered demo then contains one `dd-agent` DaemonSet instead of the
operator, CRDs, and Cluster Agent.

## 4. The Agent container still needs DD_API_KEY

The official chart stores `datadog.apiKey` in the `dd-agent` Secret and passes
it as `DD_API_KEY`:

```yaml
datadog:
  apiKey: "ENC[/secret/datadog;api_key]"
```

The container entrypoint sees a non-empty value, and the Agent resolves the
`ENC[...]` handle through Vault. This was verified in cluster:

```text
Number of secrets resolved: 3
'/secret/datadog;api_key'
'/secret/http_check;password'
'/secret/http_check;username'
```

## 5. Dummy API keys break the `/ready` readiness probe

The official chart's Agent readiness probe uses `/ready` on the health port.
With a dummy API key, the forwarder is unhealthy, so `/ready` returns 500:

```text
Readiness probe failed: HTTP probe failed with statuscode: 500
```

The Agent's `/live` endpoint still returns 200, and the `http_check` itself
works. For the demo, `examples/values-dev.yaml` overrides the readiness probe:

```yaml
agents:
  containers:
    agent:
      readinessProbe:
        httpGet:
          path: /live
          port: 5555
          scheme: HTTP
```

Remove this override when using a real Datadog API key; the default `/ready`
probe then reflects the forwarder health correctly.

## 6. The demo chart must be installed first

The official chart starts the Agent immediately. If Vault and the Vault role do
not exist yet, the Agent cannot resolve secrets and will restart.

`scripts/install-dev.sh` orders the install:

1. `demo` chart: Vault, seed Job, status-api
2. wait for Vault and the seed Job
3. official `datadog/datadog` chart
4. wait for the `dd-agent` DaemonSet

## 7. Vault Kubernetes auth needs TokenReview permissions

Vault validates the Agent's ServiceAccount token by calling the Kubernetes
`TokenReview` API. The Vault ServiceAccount needs `system:auth-delegator`.

The demo chart creates:

```yaml
kind: ClusterRoleBinding
roleRef:
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault
    namespace: <namespace>
```

The seed Job configures Vault with its own ServiceAccount token and CA:

```sh
TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  token_reviewer_jwt="$TOKEN" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

## 8. KV v2 needs sys/mounts read

Policy:

```hcl
path "secret/data/*" {
  capabilities = ["read"]
}

path "sys/mounts" {
  capabilities = ["read"]
}
```

Without `sys/mounts`, the Agent assumes KV v1 and a KV v2 path fails with
`Invalid path for a versioned K/V secrets engine`.

## 9. Do not mount a ConfigMap at /vault

The official Vault image declares a volume at `/vault/file`. Mounting the seed
policy ConfigMap at `/vault` caused:

```text
error mounting ... to rootfs at "/vault/file": ... read-only file system
```

The demo chart mounts the policy at `/vault-policy` and uses
`/vault-policy/policy.hcl`.

## 10. Test evidence

Secret resolution:

```text
=== Secrets stats ===
Number of secrets resolved: 3
'/secret/datadog;api_key'
'/secret/http_check;password'
'/secret/http_check;username'
'secret_refresh_interval' is enabled: the first refresh will happen 7.83s after startup and then every 1m0s
```

The check:

```text
http://status-api:8080 "GET /api/detail HTTP/1.1" 200 226
http://status-api:8080/api/detail is UP
```

Rotation with `secret_refresh_interval`:

```text
401 after rotation: 1
200 after restore: 1
PASS: official chart rotation test
```

Agent DaemonSet:

```text
dd-agent-gv8hh   3/3   Running
dd-agent-l65f4   3/3   Running
dd-agent-nmtw9   3/3   Running
```

## 11. Production notes

- Do not deploy the `demo` chart in production.
- Use a real Vault with TLS, persistent storage, and Kubernetes auth or
  AppRole.
- Keep `enableGlobalPermissions: false` and use a least-privilege Vault policy.
- The Vault role must bind the Agent ServiceAccount (`dd-agent` with the
  provided fullnameOverride) and the release namespace.
- The official chart's default Agent image is 7.84.6; pin `agents.image.tag`
  if you need a different version.
- `datadog.secretBackend.refreshInterval` maps to the Agent's
  `secret_refresh_interval`; keep it set for rotation.

## 12. General gotchas from the earlier native-backend tests

These still apply:

- `vault_token` is a literal static token, not a file path.
- `implicit_auth` must be nested under `vault_session` and quoted as `"true"`
  on Agent 7.85.0.
- A handle embedded in a longer header value (`Bearer ENC[...]`) was not
  substituted on 7.85.0; store the full header value and use `ENC[...]` as the
  whole value.
- The Agent image's `/etc/datadog-agent/auth_token` is its IPC token, not the
  Vault token.
- For polling logs under `set -o pipefail`, use `grep >/dev/null` instead of
  `grep -q` to avoid SIGPIPE false negatives.

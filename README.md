# Datadog Agent + HashiCorp Vault on Kubernetes

This repo uses the **official `datadog/datadog` Helm chart** for the Agent and a
small local demo chart for Vault and status-api.

The Agent's native `hashicorp.vault` secret backend is configured through the
official chart's `datadog.secretBackend` values. The Vault role is bound to the
official chart's Agent ServiceAccount.

Verified with:

| Component | Version |
| --- | --- |
| `datadog/datadog` chart | 3.264.0 |
| Datadog Agent | 7.84.6 (chart default) |
| HashiCorp Vault | 1.21.2 (`-dev`) |
| Kubernetes | 1.36 (k3s) |

## Layout

```text
.
├── demo/                         # local chart: Vault -dev + status-api
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
├── examples/
│   ├── values-dev.yaml           # official datadog chart, demo values
│   └── values-production.yaml    # official datadog chart, production example
├── scripts/
│   ├── install-dev.sh            # installs demo, then official chart
│   └── verify.sh
├── README.md
└── learnings.md
```

The Agent is **not** deployed by `demo/`. It is deployed by the official chart.

## Quick start: self-contained demo

```bash
./scripts/install-dev.sh
```

The script:

1. Installs the demo chart: Vault `-dev`, Vault seed Job, status-api.
2. Waits for Vault, the seed Job, and status-api.
3. Installs the official `datadog/datadog` chart with
   `examples/values-dev.yaml`.
4. Waits for the `dd-agent` DaemonSet.
5. Runs `scripts/verify.sh`.

Manual equivalent:

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update datadog

helm install dd-vault-demo ./demo \
  -n dd-vault-test --create-namespace

kubectl -n dd-vault-test rollout status deploy/vault
kubectl -n dd-vault-test wait --for=condition=complete job/vault-seed
kubectl -n dd-vault-test rollout status deploy/status-api

helm install dd datadog/datadog \
  --version 3.264.0 \
  -n dd-vault-test \
  -f examples/values-dev.yaml

kubectl -n dd-vault-test rollout status ds/dd-agent

./scripts/verify.sh dd dd-vault-test
```

## What the official chart values do

`examples/values-dev.yaml`:

```yaml
fullnameOverride: dd-agent

datadog:
  apiKey: "ENC[/secret/datadog;api_key]"
  site: us5.datadoghq.com
  logLevel: DEBUG

  operator:
    enabled: false
  kubeStateMetricsEnabled: false

  secretBackend:
    type: "hashicorp.vault"
    config:
      vault_address: "http://vault:8200"
      vault_session:
        vault_auth_type: kubernetes
        vault_kubernetes_role: datadog-agent
        vault_kubernetes_mount_path: auth/kubernetes/login
    refreshInterval: 60
    enableGlobalPermissions: true

  confd:
    http_check.yaml: |-
      instances:
        - name: status-api detail (Vault basic auth)
          url: http://status-api:8080/api/detail
          timeout: 10
          username: ENC[/secret/http_check;username]
          password: ENC[/secret/http_check;password]

clusterAgent:
  enabled: false
```

Key points:

- `fullnameOverride: dd-agent` makes the official chart's Agent ServiceAccount
  and DaemonSet `dd-agent`. The demo seed Job binds the Vault role to that
  ServiceAccount.
- `datadog.apiKey` is the Vault handle. The official chart stores it in the
  `dd-agent` Secret and passes it as `DD_API_KEY`; the Agent resolves it through
  Vault.
- `datadog.secretBackend` renders `DD_SECRET_BACKEND_TYPE`,
  `DD_SECRET_BACKEND_CONFIG`, and `DD_SECRET_REFRESH_INTERVAL`.
- `datadog.confd` writes the `http_check` config into the Agent.
- The demo disables the operator, kube-state-metrics, and Cluster Agent.

## Demo chart

`demo/` deploys only the local test dependencies:

- Vault `-dev` (in-memory, root token)
- Vault Kubernetes auth setup and seed Job
- Vault policy:
  - `secret/data/*` read
  - `sys/mounts` read (required for KV v2 version detection)
- Vault role `datadog-agent`, bound to `dd-agent` in the release namespace
- status-api with `/api/detail` basic auth
- `status-api-checks` self-check config

Fixed Service names are used so the official chart values can reference them:

```text
vault:8200
status-api:8080
```

The seed Job writes:

```text
secret/datadog     api_key
secret/http_check  username, password
```

The demo chart is for development only. Do not use the Vault `-dev` server or
its root token in production.

## Production

Use the official chart with an existing Vault. Do not deploy `demo/`.

```bash
helm install dd datadog/datadog \
  --version 3.264.0 \
  -n datadog \
  -f examples/values-production.yaml
```

`examples/values-production.yaml` assumes:

- Vault is reachable at `https://vault.example.com:8200`
- Vault Kubernetes auth is enabled
- the role is bound to ServiceAccount `dd-agent` in the release namespace
- `secret/datadog` contains the real Datadog API key
- `secret/http_check` contains the credentials for the target service

Vault policy:

```hcl
path "secret/data/*" {
  capabilities = ["read"]
}

path "sys/mounts" {
  capabilities = ["read"]
}
```

Role:

```bash
vault write auth/kubernetes/role/datadog-agent \
  bound_service_account_names=dd-agent \
  bound_service_account_namespaces=<release-namespace> \
  policies=datadog-agent \
  ttl=1h
```

The official chart's Vault secret backend does not need Kubernetes Secret RBAC;
production values keep `enableGlobalPermissions: false`.

## Verification

```bash
./scripts/verify.sh dd dd-vault-test
```

The script checks:

- Agent DaemonSet rollout
- `agent secret` resolved handles
- the `http_check` URL
- status-api `401` without credentials
- status-api `200` with credentials
- the Agent request log line
- the loaded `http_check` instance

## Verified log entries

Secret resolution from the official chart:

```text
=== Checking executable permissions ===
Secret backend type: hashicorp.vault
Using embedded executable: /opt/datadog-agent/embedded/bin/secret-generic-connector
Executable version: secret-generic-connector 7.84.6

=== Secrets stats ===
Number of secrets resolved: 3
Secrets handle resolved:

- '/secret/datadog;api_key':
  - used in 'datadog.yaml' configuration in entry 'api_key'
- '/secret/http_check;password':
  - used in '1974cfd07f7f30c0' configuration in entry 'password'
- '/secret/http_check;username':
  - used in '1974cfd07f7f30c0' configuration in entry 'username'

'secret_refresh_interval' is enabled: the first refresh will happen 7.83s after startup and then every 1m0s
```

The `http_check`:

```text
http_check:status-api detail (Vault basic auth):2d715e947444ddc2 | (http_check.py:130) | Connecting to http://status-api:8080/api/detail
- | (connectionpool.py:550) | http://status-api:8080 "GET /api/detail HTTP/1.1" 200 226
http_check:status-api detail (Vault basic auth):2d715e947444ddc2 | (http_check.py:109) | http://status-api:8080/api/detail is UP
```

Agent status:

```text
Instance ID: http_check:status-api detail (Vault basic auth):2d715e947444ddc2 [OK]
Configuration Source: file:/etc/datadog-agent/conf.d/http_check.yaml[0]
Total Runs: 4
Metric Samples: Last Run: 3, Total: 12
Service Checks: Last Run: 1, Total: 4
```

Endpoint checks from an Agent pod:

```text
http://status-api:8080/api/detail -> 401
http://status-api:8080/api/detail -> 200
```

Rotation:

```text
401 after rotation: 1
200 after restore: 1
PASS: official chart rotation test
```

Agent DaemonSet:

```text
NAME             READY   STATUS    RESTARTS   AGE
dd-agent-gv8hh   3/3     Running   0          47s
dd-agent-l65f4   3/3     Running   0   	46s
dd-agent-nmtw9   3/3     Running   0          47s
```

## Gotchas

- The official chart's Agent container is named `agent`, not `datadog-agent`.
- The demo uses a dummy Datadog API key, so the Agent's `/ready` endpoint
  returns 500 (forwarder unhealthy). `examples/values-dev.yaml` overrides the
  readiness probe to `/live` for the demo. Remove that override when using a
  real API key.
- The official chart's Agent DaemonSet is `dd-agent` because of
  `fullnameOverride: dd-agent`.
- The demo chart must be installed before the official chart. The official
  chart has no wait-for-Vault; the install script handles ordering.
- The Vault policy needs `sys/mounts` read for KV v2.
- The Vault role must bind the `dd-agent` ServiceAccount and the release
  namespace.
- The official chart's default Agent image is 7.84.6. Pin `agents.image.tag` if
  you need a different version.
- `enableGlobalPermissions: true` is for the demo; production should use the
  least-privilege Vault policy and keep it false.

## References

- [Official Datadog Helm chart](https://github.com/DataDog/helm-charts/tree/main/charts/datadog)
- [Datadog Secrets Management](https://docs.datadoghq.com/agent/configuration/secrets-management/)
- [HashiCorp Vault documentation](https://developer.hashicorp.com/vault/docs)
- [learnings.md](learnings.md)

# Datadog Agent + HashiCorp Vault on Kubernetes

A Helm chart for the Datadog Agent's **native** `hashicorp.vault` secret
backend on Kubernetes.

Vault holds the credentials. The Agent resolves `ENC[...]` handles through
Vault's Kubernetes auth method, and an `http_check` calls the status-api
basic-auth endpoint. The chart includes an optional Vault `-dev` server and
status-api for a self-contained demo.

Verified with:

- Datadog Agent `7.85.0`
- HashiCorp Vault `1.21.2`
- Kubernetes `1.36` (k3s)
- Vault Kubernetes auth, not a static root token

> The optional Vault server is for development/demo only. For production, use
> an existing Vault with the Kubernetes auth method and a least-privilege
> policy.

## Layout

```text
.
├── Chart.yaml
├── values.yaml
├── examples/
│   ├── values-dev.yaml
│   └── values-production.yaml
├── scripts/
│   └── verify.sh
└── templates/
    ├── _helpers.tpl
    ├── serviceaccount-agent.yaml
    ├── configmap-agent.yaml
    ├── deployment-agent.yaml
    ├── configmap-status-api-checks.yaml
    ├── secret-status-api.yaml
    ├── deployment-status-api.yaml
    ├── service-status-api.yaml
    ├── serviceaccount-vault.yaml
    ├── rbac-vault-tokenreview.yaml
    ├── configmap-vault-policy.yaml
    ├── deployment-vault.yaml
    ├── service-vault.yaml
    └── job-vault-seed.yaml
```

## Quick start: self-contained demo

This deploys Vault `-dev`, a seed Job, status-api, and the Agent:

```bash
helm install ddv . \
  -n dd-vault-test --create-namespace \
  -f examples/values-dev.yaml

./scripts/verify.sh ddv dd-vault-test
```

The seed Job:

- enables Vault's Kubernetes auth method
- configures it with the Vault ServiceAccount's token and CA
- creates the `datadog-agent` policy and role
- seeds `secret/datadog` and `secret/http_check`

The Agent then authenticates with its own ServiceAccount token. No static Vault
token is used by the Agent in this path.

Clean up:

```bash
helm uninstall ddv -n dd-vault-test
kubectl delete namespace dd-vault-test
```

If your cluster protects namespaces with an admission policy, add its required
delete annotation before deleting the namespace.

## Production: existing Vault

Set `devVault.enabled=false` and point the chart at your Vault:

```yaml
devVault:
  enabled: false

datadog:
  vault:
    address: https://vault.example.com:8200
    authType: kubernetes
    kubernetesRole: datadog-agent
    kubernetesMountPath: auth/kubernetes/login

statusApi:
  enabled: false

httpCheck:
  enabled: true
  url: https://status.example.com/api/detail
```

Create the Vault policy and role:

```hcl
# datadog-agent.hcl
path "secret/data/*" {
  capabilities = ["read"]
}

# Required for KV v2 version detection. Without it the Agent assumes KV v1.
path "sys/mounts" {
  capabilities = ["read"]
}
```

```bash
vault policy write datadog-agent datadog-agent.hcl

vault write auth/kubernetes/role/datadog-agent \
  bound_service_account_names=<agent-service-account> \
  bound_service_account_namespaces=<agent-namespace> \
  policies=datadog-agent \
  ttl=1h
```

The role's ServiceAccount name is the chart's Agent ServiceAccount:

```text
<release>-datadog-vault-k8s-agent
```

or the value of `datadog.serviceAccount.name`.

The Vault secret handles used by the chart are:

```text
/secret/datadog;api_key
/secret/http_check;username
/secret/http_check;password
```

Seed `secret/datadog` with your real Datadog API key and `secret/http_check`
with the credentials the target service expects.

### Official Datadog chart

If you already use the official `datadog` Helm chart, you do not need this
chart's Agent deployment. The official chart supports the native backend:

```yaml
datadog:
  apiKey: "ENC[/secret/datadog;api_key]"
  site: us5.datadoghq.com
  secretBackend:
    type: "hashicorp.vault"
    config:
      vault_address: "https://vault.example.com:8200"
      vault_session:
        vault_auth_type: kubernetes
        vault_kubernetes_role: datadog-agent
        vault_kubernetes_mount_path: auth/kubernetes/login
    enableGlobalPermissions: true
  confd:
    http_check.yaml: |-
      instances:
        - name: status-api detail
          url: https://status.example.com/api/detail
          username: ENC[/secret/http_check;username]
          password: ENC[/secret/http_check;password]
```

Use this chart only for the self-contained demo or if you want the custom
status-api/Vault test harness.

## Important values

| Value | Default | Purpose |
| --- | --- | --- |
| `datadog.image` | `datadog/agent:7.85.0` | Agent image |
| `datadog.site` | `us5.datadoghq.com` | Datadog region/site |
| `datadog.apiKey` | `ENC[/secret/datadog;api_key]` | Vault handle; also passed as `DD_API_KEY` |
| `datadog.vault.address` | empty | External Vault URL; not used when `devVault.enabled=true` |
| `datadog.vault.authType` | `kubernetes` | `kubernetes` or `token` |
| `datadog.vault.kubernetesRole` | `datadog-agent` | Vault role bound to the Agent SA |
| `datadog.secretRefreshInterval` | `60` | Runtime secret refresh in seconds |
| `statusApi.enabled` | `true` | Deploy the demo basic-auth target |
| `statusApi.auth.existingSecret` | empty | Existing Secret for status-api auth |
| `httpCheck.enabled` | `true` | Render the status-api http_check |
| `httpCheck.url` | empty | Use the in-chart status-api when empty |
| `devVault.enabled` | `false` | Deploy the Vault `-dev` server and seed Job |
| `devVault.tokenReview.createClusterRoleBinding` | `true` | Bind Vault SA to `system:auth-delegator` |

## Ordering and readiness

The Agent Deployment has an init container, `wait-for-vault`. It waits for:

1. Vault's `/v1/sys/health` endpoint
2. a successful `auth/kubernetes/login` using the Agent ServiceAccount

The Agent starts only after both succeed. This avoids the race where the Agent
starts before the Vault seed Job has created the role and policy.

The demo does not use `agent health` as a readiness probe. With a dummy Datadog
API key, the forwarder is unhealthy and `agent health` returns non-zero, which
would keep the pod NotReady forever. The `verify.sh` script waits for
`agent status` instead. With a real API key, you can add an `agent health`
readiness probe if you want one.

## Verification

```bash
./scripts/verify.sh ddv dd-vault-test
```

The script checks:

- Agent rollout
- `agent secret` resolved handles
- the http_check URL
- status-api 401 without credentials
- status-api 200 with credentials
- the Agent request log line
- the loaded `http_check` instance

For the rotation test, keep `datadog.logLevel=DEBUG`, then:

```bash
VAULT_DEPLOY=$(kubectl -n dd-vault-test get deploy -l app.kubernetes.io/component=vault -o jsonpath='{.items[0].metadata.name}')

kubectl -n dd-vault-test exec deploy/"$VAULT_DEPLOY" -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault kv put secret/http_check username=testuser password=wrongpass

sleep 75
kubectl -n dd-vault-test logs deploy/"$AGENT_DEPLOY" -c datadog-agent | grep 'GET /api/detail HTTP/1.1" 401'

kubectl -n dd-vault-test exec deploy/"$VAULT_DEPLOY" -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault kv put secret/http_check username=testuser password=testpass

sleep 75
kubectl -n dd-vault-test logs deploy/"$AGENT_DEPLOY" -c datadog-agent | grep 'GET /api/detail HTTP/1.1" 200'
```

## Gotchas

- The upstream Agent container requires `DD_API_KEY` in the environment even
  when `api_key` is an `ENC[...]` handle. The chart sets it to the same handle;
  the Agent resolves it through Vault.
- The Vault policy must include `read` on `sys/mounts` for KV v2.
- The Vault Kubernetes role must bind the exact Agent ServiceAccount name and
  namespace.
- The Vault ServiceAccount needs `system:auth-delegator` so Vault can call
  `TokenReview`. The chart creates the binding only for the dev Vault; for
  production, ensure your Vault server has an equivalent identity.
- The status-api Secret and the Vault `secret/http_check` must contain the same
  credentials. In production, source both from your secret manager.
- `secret_refresh_interval` is required for rotation without restarting the
  Agent.
- `status-api:8080` is the in-cluster Service name and port, not the public
  ingress.

## Learnings

See [learnings.md](learnings.md) for the tested behavior, version differences,
and the Vault Kubernetes auth flow.

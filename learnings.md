# Learnings: Datadog Agent + Vault on Kubernetes

What was verified while building this chart.

## Test environment

| Component | Version |
| --- | --- |
| Datadog Agent | `datadog/agent:7.85.0` |
| HashiCorp Vault | `hashicorp/vault:1.21.2` (`-dev`) |
| Kubernetes | 1.36 (k3s) |
| status-api | `ghcr.io/bismigel/status-api:latest` |

## 1. Vault Kubernetes auth flow

The Agent's native backend authenticates with its pod ServiceAccount token:

```yaml
secret_backend_type: hashicorp.vault
secret_backend_config:
  vault_address: http://vault:8200
  vault_session:
    vault_auth_type: kubernetes
    vault_kubernetes_role: datadog-agent
    vault_kubernetes_mount_path: auth/kubernetes/login
```

Vault validates that token by calling the Kubernetes `TokenReview` API. The
identity Vault uses for that call needs `system:auth-delegator`. In this chart's
dev setup, the seed Job and the Vault server share the `vault` ServiceAccount,
and the chart creates:

```yaml
kind: ClusterRoleBinding
roleRef:
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: <release>-datadog-vault-k8s-vault
    namespace: <release-namespace>
```

The seed Job configures Vault with its own ServiceAccount token and CA:

```sh
TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  token_reviewer_jwt="$TOKEN" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

The Vault role must bind the Agent's ServiceAccount name and namespace:

```sh
vault write auth/kubernetes/role/datadog-agent \
  bound_service_account_names=<release>-datadog-vault-k8s-agent \
  bound_service_account_namespaces=<release-namespace> \
  policies=datadog-agent \
  ttl=1h
```

## 2. The Agent container still needs DD_API_KEY

The upstream `datadog/agent` container's s6 entrypoint checks for `DD_API_KEY`
before the Agent starts. With only `api_key: ENC[...]` in `datadog.yaml`, the
container exits with:

```text
You must set either a DD_API_KEY or DD_DELEGATED_AUTH_ORG_UUID environment
variable to run the Datadog Agent container.
```

Set the environment variable to the same handle:

```yaml
env:
  - name: DD_API_KEY
    value: "ENC[/secret/datadog;api_key]"
```

The entrypoint passes, and the Agent resolves the handle through Vault. This
was verified in-cluster.

## 3. KV v2 needs sys/mounts read

Policy:

```hcl
path "secret/data/*" {
  capabilities = ["read"]
}

path "sys/mounts" {
  capabilities = ["read"]
}
```

Without `sys/mounts`, the Agent assumes KV v1. A KV v2 path then fails with
`Invalid path for a versioned K/V secrets engine`. Reproduced with a token that
had only `secret/data/*` read; adding `sys/mounts` fixed it.

## 4. Rotation works with secret_refresh_interval

With `secret_refresh_interval: 15` and Agent 7.85.0:

- rotating `secret/http_check` to a wrong password produced `401`
- restoring the password produced `200`

The check refresh for file-based checks is available in Agent 7.76+.

## 5. Dev Vault is not production

The chart's `devVault`:

- runs `vault server -dev`
- uses an in-memory store
- uses a root token
- seeds dummy secrets
- is deleted with the Helm release/namespace

For production, use an existing Vault with TLS, a real storage backend, and
Kubernetes auth or AppRole. Do not use the root token.

## 6. Helm chart ordering

The Agent must resolve secrets at startup. If it starts before the Vault seed
Job has created the policy/role/secrets, it exits and the Agent process
restarts.

The chart avoids this with an init container, `wait-for-vault`, which waits for:

1. Vault's `/v1/sys/health` endpoint
2. a successful `auth/kubernetes/login` using the Agent ServiceAccount

The Agent container starts only after both succeed. This was verified in
cluster: the init container logs `Vault is ready for the Agent` before the
Agent starts.

## 6b. Do not use agent health as a readiness probe with a dummy key

With a dummy Datadog API key, the forwarder is unhealthy. `agent health` then
returns non-zero, so a readiness probe using it keeps the pod NotReady and
blocks the rollout. Use `agent status` in the verify script, or add
`agent health` only when a real API key is configured.

## 6c. Do not mount a ConfigMap at /vault in the Vault image

The official Vault image declares a volume at `/vault/file`. Mounting a
ConfigMap at `/vault` caused:

```text
error mounting ... to rootfs at "/vault/file": ... read-only file system
```

Mount the seed policy at a different path, such as `/vault-policy`, and pass
`/vault-policy/policy.hcl` to `vault policy write`.

## 7. Cluster-scoped RBAC

The `system:auth-delegator` binding is cluster-scoped. Helm uninstall removes
it because the chart created it, but if you set
`devVault.tokenReview.createClusterRoleBinding=false`, you must create and
manage that binding yourself.

## 8. status-api is an internal Service

The Agent uses:

```text
http://<release>-datadog-vault-k8s-status-api:8080/api/detail
```

This is the in-cluster Service DNS name and port. It is not the public ingress
(`status.bismigel.dev`). The public hostname goes through Cloudflare and
ingress-nginx on port 443.

## 9. `agent status` does not prove the URL status

The `[OK]` next to a check instance in `agent status` is the check runner
status, not the monitored URL's status. Use one of:

- the DEBUG log line with the HTTP status code
- `agent check http_check` plus the service check in Datadog
- the status-api endpoint directly with the same credentials

The chart's dev values set `logLevel: DEBUG` so the request lines are visible.

## 10. Test harness gotcha: pipefail and grep -q

When polling `kubectl logs | grep -q` under `set -o pipefail`, `grep -q` can
exit early, the log producer gets `SIGPIPE`, and the pipeline returns non-zero
even though the pattern matched. Use:

```bash
kubectl logs ... | grep -- "$pattern" >/dev/null
```

## Open items

- The chart was tested with a Vault `-dev` server. Re-test against your
  production Vault with TLS and the real policy/role.
- The chart's dev seed uses `statusApi.auth.username/password`. If you use
  `statusApi.auth.existingSecret`, seed `secret/http_check` separately.
- `implicit_auth` on Agent 7.85.0 requires the string `"true"`, not a YAML
  boolean. The chart uses Kubernetes auth by default, so this does not affect
  the default path.

{{- define "dd-vault.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "dd-vault.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "dd-vault.agentSA" -}}
{{- if .Values.datadog.serviceAccount.name -}}
{{- .Values.datadog.serviceAccount.name -}}
{{- else -}}
{{- printf "%s-agent" (include "dd-vault.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "dd-vault.vaultSA" -}}
{{- if .Values.devVault.serviceAccount.name -}}
{{- .Values.devVault.serviceAccount.name -}}
{{- else -}}
{{- printf "%s-vault" (include "dd-vault.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "dd-vault.vaultAddress" -}}
{{- if .Values.devVault.enabled -}}
{{- printf "http://%s-vault:8200" (include "dd-vault.fullname" .) -}}
{{- else if .Values.datadog.vault.address -}}
{{- .Values.datadog.vault.address -}}
{{- else -}}
{{- fail "set datadog.vault.address or enable devVault" -}}
{{- end -}}
{{- end -}}

{{- define "dd-vault.secretBackendConfig" -}}
{{- $cfg := dict "vault_address" (include "dd-vault.vaultAddress" .) -}}
{{- if eq .Values.datadog.vault.authType "kubernetes" -}}
{{- $_ := set $cfg "vault_session" (dict "vault_auth_type" "kubernetes" "vault_kubernetes_role" .Values.datadog.vault.kubernetesRole "vault_kubernetes_mount_path" .Values.datadog.vault.kubernetesMountPath) -}}
{{- else -}}
{{- $_ := set $cfg "vault_token" .Values.datadog.vault.token -}}
{{- end -}}
{{- toYaml $cfg -}}
{{- end -}}

{{- define "dd-vault.httpCheckURL" -}}
{{- if .Values.httpCheck.url -}}
{{- .Values.httpCheck.url -}}
{{- else if .Values.statusApi.enabled -}}
{{- printf "http://%s-status-api:8080%s" (include "dd-vault.fullname" .) .Values.httpCheck.path -}}
{{- else -}}
{{- fail "set httpCheck.url or enable statusApi" -}}
{{- end -}}
{{- end -}}

{{- define "dd-vault.statusApiSecretName" -}}
{{- default (printf "%s-status-api-auth" (include "dd-vault.fullname" .)) .Values.statusApi.auth.existingSecret -}}
{{- end -}}

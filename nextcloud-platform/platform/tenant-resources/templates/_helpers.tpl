{{/*
Expand the name of the chart.
*/}}
{{- define "tenant-resources.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "tenant-resources.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Values.tenant.name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "tenant-resources.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "tenant-resources.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: nextcloud-platform
nextcloud.platform/tenant: {{ .Values.tenant.name }}
nextcloud.platform/environment: {{ .Values.tenant.environment }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "tenant-resources.selectorLabels" -}}
app.kubernetes.io/name: nextcloud
app.kubernetes.io/instance: {{ .Values.tenant.name }}
{{- end }}

{{/*
Vault path for tenant secrets
*/}}
{{- define "tenant-resources.vaultPath" -}}
nextcloud/{{ .Values.tenant.environment }}/{{ .Values.tenant.name }}
{{- end }}


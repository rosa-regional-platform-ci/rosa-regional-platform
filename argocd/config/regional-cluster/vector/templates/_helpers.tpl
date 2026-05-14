{{/*
Common labels
*/}}
{{- define "vector.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: vector
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: log-collector
{{- end }}

{{/*
Selector labels
*/}}
{{- define "vector.selectorLabels" -}}
app.kubernetes.io/name: vector
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Namespace
*/}}
{{- define "vector.namespace" -}}
{{- default "vector" .Values.namespace }}
{{- end }}

{{/*
Annotations
*/}}
{{- define "vector.annotations" -}}
meta.helm.sh/release-name: {{ .Release.Name }}
meta.helm.sh/release-namespace: {{ .Release.Namespace }}
{{- end }}

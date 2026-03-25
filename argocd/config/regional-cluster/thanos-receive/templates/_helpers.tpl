{{- define "thanos-receive.name" -}}
thanos-receive
{{- end -}}

{{- define "thanos-receive.labels" -}}
app: {{ include "thanos-receive.name" . }}
app.kubernetes.io/name: {{ include "thanos-receive.name" . }}
app.kubernetes.io/component: receive
{{- end -}}

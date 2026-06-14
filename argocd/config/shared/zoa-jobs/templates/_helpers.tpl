{{- define "zoa-jobs.labels" -}}
app.kubernetes.io/managed-by: {{ index .Values.labels "managed-by" }}
app.kubernetes.io/part-of: {{ index .Values.labels "part-of" }}
{{- end }}

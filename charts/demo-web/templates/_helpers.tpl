{{- define "demo-web.labels" -}}
app.kubernetes.io/name: demo-web
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

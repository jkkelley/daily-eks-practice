{{- define "practice-app.name" -}}
{{ .Chart.Name }}
{{- end }}

{{- define "practice-app.labels" -}}
app.kubernetes.io/name: {{ include "practice-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "practice-app.frontend.selector" -}}
app.kubernetes.io/name: {{ include "practice-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: frontend
{{- end }}

{{- define "practice-app.backend.selector" -}}
app.kubernetes.io/name: {{ include "practice-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: backend
{{- end }}

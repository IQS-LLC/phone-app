{{/*
Common helpers for the Lugh Helm chart.
*/}}

{{/* Expand the name of the chart. */}}
{{- define "lugh.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Full image reference: registry/owner/repository:tag */}}
{{- define "lugh.image" -}}
{{- $reg  := .Values.global.imageRegistry -}}
{{- $own  := .Values.global.imageOwner -}}
{{- $repo := .repository -}}
{{- $tag  := .tag | default $.Values.global.imageTag -}}
{{- if and $reg $own -}}
{{ $reg }}/{{ $own }}/{{ $repo }}:{{ $tag }}
{{- else -}}
{{ $repo }}:{{ $tag }}
{{- end -}}
{{- end }}

{{/* Common labels */}}
{{- define "lugh.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "lugh.name" . }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* Selector labels */}}
{{- define "lugh.selectorLabels" -}}
app.kubernetes.io/name: {{ include "lugh.name" . }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

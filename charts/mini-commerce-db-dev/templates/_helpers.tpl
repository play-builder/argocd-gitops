{{- define "mini-commerce.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{- define "mini-commerce.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}


{{- define "mini-commerce.namespace" -}}
{{- required "namespace.name is required" .Values.namespace.name -}}
{{- end -}}


{{- define "mini-commerce.labels" -}}
app.kubernetes.io/name: {{ include "mini-commerce.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mini-commerce
app.kubernetes.io/environment: {{ .Values.environment | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}


{{- define "mini-commerce.databaseFullname" -}}
{{- printf "%s-postgresql" (include "mini-commerce.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{- define "mini-commerce.databaseSecretName" -}}
{{- required "externalSecrets.database.targetSecretName is required when database is enabled" .Values.externalSecrets.database.targetSecretName -}}
{{- end -}}


{{- define "mini-commerce.databaseImage" -}}
{{- $repository := required "database.image.repository is required" .Values.database.image.repository -}}
{{- $digest := required "database.image.digest is required; mutable tags are not accepted" .Values.database.image.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) -}}
{{- fail "database.image.digest must be sha256 followed by 64 lowercase hexadecimal characters" -}}
{{- end -}}
{{- printf "%s@%s" $repository $digest -}}
{{- end -}}

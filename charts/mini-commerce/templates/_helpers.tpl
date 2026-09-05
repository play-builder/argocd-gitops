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

{{- define "mini-commerce.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mini-commerce.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: application
{{- end -}}

{{- define "mini-commerce.image" -}}
{{- $repository := required "image.repository is required" .Values.image.repository -}}
{{- $digest := required "image.digest is required; mutable tags are not accepted" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) -}}
{{- fail "image.digest must be sha256 followed by 64 lowercase hexadecimal characters" -}}
{{- end -}}
{{- printf "%s@%s" $repository $digest -}}
{{- end -}}

{{- define "mini-commerce.version" -}}
{{- .Chart.AppVersion -}}
{{- end -}}

{{- define "mini-commerce.databaseFullname" -}}
{{- printf "%s-postgresql" (include "mini-commerce.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mini-commerce.runtimeSecretName" -}}
{{- required "externalSecrets.runtime.targetSecretName is required when External Secrets is enabled" .Values.externalSecrets.runtime.targetSecretName -}}
{{- end -}}

{{- define "mini-commerce.databaseSecretName" -}}
{{- required "externalSecrets.database.targetSecretName is required when database is enabled" .Values.externalSecrets.database.targetSecretName -}}
{{- end -}}

{{- define "mini-commerce.recoveryDatabaseSecretName" -}}
{{- printf "%s-db-recovery" (include "mini-commerce.fullname" .) -}}
{{- end -}}

{{- define "mini-commerce.telemetryConfigName" -}}
{{- printf "%s-telemetry" (include "mini-commerce.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mini-commerce.validateNetworkPolicy" -}}
{{- if .Values.networkPolicy.enabled -}}
{{- if eq (len .Values.networkPolicy.gateway.sourceCidrs) 0 -}}
{{- fail "networkPolicy.gateway.sourceCidrs must contain platform-validated CIDRs when NetworkPolicy is enabled" -}}
{{- end -}}
{{- range $cidr := .Values.networkPolicy.gateway.sourceCidrs -}}
{{- if or (eq $cidr "0.0.0.0/0") (eq $cidr "::/0") (not (regexMatch "^[0-9A-Fa-f:.]+/[0-9]{1,3}$" $cidr)) -}}
{{- fail "networkPolicy.gateway.sourceCidrs must contain bounded CIDRs and must not contain a wildcard" -}}
{{- end -}}
{{- end -}}
{{- if eq (len .Values.networkPolicy.gateway.healthCheckSourceCidrs) 0 -}}
{{- fail "networkPolicy.gateway.healthCheckSourceCidrs must contain private ALB health-check CIDRs when NetworkPolicy is enabled" -}}
{{- end -}}
{{- range $cidr := .Values.networkPolicy.gateway.healthCheckSourceCidrs -}}
{{- if or (eq $cidr "0.0.0.0/0") (eq $cidr "::/0") (not (regexMatch "^(10\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}|192\\.168\\.[0-9]{1,3}\\.[0-9]{1,3}|172\\.(1[6-9]|2[0-9]|3[0-1])\\.[0-9]{1,3}\\.[0-9]{1,3})/[0-9]{1,2}$" $cidr)) -}}
{{- fail "networkPolicy.gateway.healthCheckSourceCidrs must contain bounded private CIDRs and must not contain a wildcard" -}}
{{- end -}}
{{- end -}}
{{- if eq (len .Values.networkPolicy.telemetry.namespaceLabels) 0 -}}
{{- fail "networkPolicy.telemetry.namespaceLabels must select the platform collector" -}}
{{- end -}}
{{- if eq (len .Values.networkPolicy.telemetry.podLabels) 0 -}}
{{- fail "networkPolicy.telemetry.podLabels must select the platform collector" -}}
{{- end -}}
{{- $telemetryPort := int .Values.networkPolicy.telemetry.port -}}
{{- if or (lt $telemetryPort 1) (gt $telemetryPort 65535) -}}
{{- fail "networkPolicy.telemetry.port must be between 1 and 65535" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mini-commerce.databaseImage" -}}
{{- $repository := required "database.image.repository is required" .Values.database.image.repository -}}
{{- $digest := required "database.image.digest is required; mutable tags are not accepted" .Values.database.image.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) -}}
{{- fail "database.image.digest must be sha256 followed by 64 lowercase hexadecimal characters" -}}
{{- end -}}
{{- printf "%s@%s" $repository $digest -}}
{{- end -}}

{{- define "mini-commerce.migrationImage" -}}
{{- $repository := required "database.migrationImage.repository is required" .Values.database.migrationImage.repository -}}
{{- $digest := required "database.migrationImage.digest is required; mutable tags are not accepted" .Values.database.migrationImage.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) -}}
{{- fail "database.migrationImage.digest must be sha256 followed by 64 lowercase hexadecimal characters" -}}
{{- end -}}
{{- printf "%s@%s" $repository $digest -}}
{{- end -}}

{{- define "mini-commerce.validateKind" -}}
{{- if not (or (eq .Values.workload.kind "Deployment") (eq .Values.workload.kind "Rollout")) -}}
{{- fail "workload.kind must be Deployment or Rollout" -}}
{{- end -}}
{{- end -}}

{{- define "mini-commerce.podTemplate" -}}
metadata:
  labels:
    {{- include "mini-commerce.selectorLabels" . | nindent 4 }}
  annotations:
    {{- if .Values.telemetry.enabled }}
    prometheus.io/scrape: "true"
    prometheus.io/path: /metrics
    prometheus.io/port: {{ .Values.service.managementPort | quote }}
    {{- end }}
spec:
  serviceAccountName: {{ .Values.serviceAccount.name }}
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  {{- if .Values.topologySpread.enabled }}
  topologySpreadConstraints:
    - maxSkew: {{ .Values.topologySpread.maxSkew }}
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: {{ .Values.topologySpread.whenUnsatisfiable }}
      labelSelector:
        matchLabels:
          {{- include "mini-commerce.selectorLabels" . | nindent 10 }}
  {{- end }}
  containers:
    - name: mini-commerce
      image: {{ include "mini-commerce.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      ports:
        - name: public
          containerPort: {{ .Values.service.publicPort }}
          protocol: TCP
        - name: management
          containerPort: {{ .Values.service.managementPort }}
          protocol: TCP
      env:
        - name: PORT
          value: {{ .Values.service.publicPort | quote }}
        - name: MANAGEMENT_PORT
          value: {{ .Values.service.managementPort | quote }}
        - name: APP_VERSION
          value: {{ include "mini-commerce.version" . | quote }}
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: FAILURE_RATE
          value: {{ .Values.app.failureRate | quote }}
        - name: LATENCY_MS
          value: {{ .Values.app.latencyMs | quote }}
        - name: READY_DELAY_MS
          value: {{ .Values.app.readyDelayMs | quote }}
        - name: SHUTDOWN_DELAY_MS
          value: {{ .Values.app.shutdownDelayMs | quote }}
        - name: SECRET_KEYS
          value: {{ .Values.app.secretKeys | quote }}
        - name: DATABASE_ENABLED
          value: {{ ternary "true" "false" .Values.database.enabled | quote }}
        {{- if .Values.telemetry.enabled }}
        - name: OTEL_SERVICE_NAME
          valueFrom:
            configMapKeyRef:
              name: {{ include "mini-commerce.telemetryConfigName" . }}
              key: OTEL_SERVICE_NAME
        - name: OTEL_RESOURCE_ATTRIBUTES
          valueFrom:
            configMapKeyRef:
              name: {{ include "mini-commerce.telemetryConfigName" . }}
              key: OTEL_RESOURCE_ATTRIBUTES
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          valueFrom:
            configMapKeyRef:
              name: {{ include "mini-commerce.telemetryConfigName" . }}
              key: OTEL_EXPORTER_OTLP_ENDPOINT
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          valueFrom:
            configMapKeyRef:
              name: {{ include "mini-commerce.telemetryConfigName" . }}
              key: OTEL_EXPORTER_OTLP_PROTOCOL
        {{- end }}
        {{- if .Values.database.enabled }}
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: {{ include "mini-commerce.databaseSecretName" . }}
              key: DB_HOST
        - name: DB_PORT
          valueFrom:
            secretKeyRef:
              name: {{ include "mini-commerce.databaseSecretName" . }}
              key: DB_PORT
        - name: DB_NAME
          valueFrom:
            secretKeyRef:
              name: {{ include "mini-commerce.databaseSecretName" . }}
              key: DB_NAME
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: {{ include "mini-commerce.databaseSecretName" . }}
              key: DB_USER
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ include "mini-commerce.databaseSecretName" . }}
              key: DB_PASSWORD
        - name: DB_SSL
          value: "false"
        {{- end }}
      {{- if .Values.externalSecrets.enabled }}
      envFrom:
        - secretRef:
            name: {{ include "mini-commerce.runtimeSecretName" . }}
      {{- end }}
      livenessProbe:
        httpGet:
          path: {{ .Values.probes.liveness.path }}
          port: management
        initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
        periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
        failureThreshold: {{ .Values.probes.liveness.failureThreshold }}
      readinessProbe:
        httpGet:
          path: {{ .Values.probes.readiness.path }}
          port: management
        initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds }}
        periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
        failureThreshold: {{ .Values.probes.readiness.failureThreshold }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
{{- end -}}

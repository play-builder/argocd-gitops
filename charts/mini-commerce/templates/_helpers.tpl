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

{{- define "mini-commerce.validateCIDR" -}}
{{- $cidr := .cidr -}}
{{- $error := printf "%s must contain bounded CIDRs in canonical IPv4 network notation" .field -}}
{{- if not (regexMatch "^((0|[1-9][0-9]{0,2})\\.){3}(0|[1-9][0-9]{0,2})/([1-9]|[12][0-9]|3[0-2])$" $cidr) -}}
{{- fail $error -}}
{{- end -}}
{{- $parts := splitList "/" $cidr -}}
{{- $octets := splitList "." (index $parts 0) -}}
{{- $prefix := int (index $parts 1) -}}
{{- $first := int (index $octets 0) -}}
{{- $second := int (index $octets 1) -}}
{{- $third := int (index $octets 2) -}}
{{- $fourth := int (index $octets 3) -}}
{{- if or (gt $first 255) (gt $second 255) (gt $third 255) (gt $fourth 255) -}}
{{- fail $error -}}
{{- end -}}
{{- if .privateOnly -}}
{{- $inTen := and (eq $first 10) (ge $prefix 8) -}}
{{- $inOneSevenTwo := and (eq $first 172) (ge $second 16) (le $second 31) (ge $prefix 12) -}}
{{- $inOneNineTwo := and (eq $first 192) (eq $second 168) (ge $prefix 16) -}}
{{- if not (or $inTen $inOneSevenTwo $inOneNineTwo) -}}
{{- fail $error -}}
{{- end -}}
{{- end -}}
{{/* The host portion must be zero; checking the address text alone permits
     broad prefixes and noncanonical networks interpreted differently by CNI. */}}
{{- $address := add (mul $first 16777216) (mul $second 65536) (mul $third 256) $fourth -}}
{{- $blockSize := int64 1 -}}
{{- range until (int (sub 32 $prefix)) -}}
{{- $blockSize = mul $blockSize 2 -}}
{{- end -}}
{{- if ne (mod $address $blockSize) 0 -}}
{{- fail $error -}}
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
    app.kubernetes.io/part-of: mini-commerce
    service.istio.io/canonical-name: mini-commerce
  annotations:
    prometheus.istio.io/merge-metrics: "false"
    sidecar.istio.io/rewriteAppHTTPProbers: "true"
    sidecar.istio.io/proxyCPU: "100m"
    sidecar.istio.io/proxyCPULimit: "500m"
    sidecar.istio.io/proxyMemory: "128Mi"
    sidecar.istio.io/proxyMemoryLimit: "256Mi"
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
    - maxSkew: {{ .Values.topologySpread.maxSkew }}
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: {{ .Values.topologySpread.whenUnsatisfiable }}
      labelSelector:
        matchLabels:
          {{- include "mini-commerce.selectorLabels" . | nindent 10 }}
  {{- end }}
  {{- if and .Values.database.enabled (eq .Values.environment "prod") }}
  volumes:
    - name: rds-ca
      configMap:
        name: mini-commerce-rds-ca
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
        - name: APP_ENV
          value: {{ ternary "production" "development" (eq .Values.environment "prod") | quote }}
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
          value: {{ ternary "true" "false" (eq .Values.environment "prod") | quote }}
        {{- if eq .Values.environment "prod" }}
        - name: NODE_EXTRA_CA_CERTS
          value: /etc/rds-ca/global-bundle.pem
        {{- end }}
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
      {{- if and .Values.database.enabled (eq .Values.environment "prod") }}
      volumeMounts:
        - name: rds-ca
          mountPath: /etc/rds-ca
          readOnly: true
      {{- end }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
{{- end -}}

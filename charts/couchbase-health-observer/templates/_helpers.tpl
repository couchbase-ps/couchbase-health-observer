{{/* Chart name, overridable. */}}
{{- define "observer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified name. fullnameOverride wins, so an existing install can keep its object names. */}}
{{- define "observer.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "observer.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "observer.labels" -}}
helm.sh/chart: {{ include "observer.chart" . }}
{{ include "observer.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "observer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "observer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "observer.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "observer.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Image reference. Empty tag falls back to appVersion, never "latest". */}}
{{- define "observer.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{/* Actuator set as a list, from the comma-separated value. */}}
{{- define "observer.actuatorList" -}}
{{- $out := list -}}
{{- range (splitList "," (default "" .Values.actuators)) -}}
{{- $t := trim . -}}
{{- if $t -}}{{- $out = append $out $t -}}{{- end -}}
{{- end -}}
{{- $out | join "," -}}
{{- end -}}

{{- define "observer.hasK8sActuator" -}}
{{- if has "k8s" (splitList "," (include "observer.actuatorList" .)) -}}true{{- end -}}
{{- end -}}

{{- define "observer.hasWebhookActuator" -}}
{{- if has "webhook" (splitList "," (include "observer.actuatorList" .)) -}}true{{- end -}}
{{- end -}}

{{/*
Namespaces the Kubernetes actuator touches. Derived from the ConfigMap and
Deployment targets so RBAC can never disagree with the actuation targets, which
is a failure that only shows up during a live switch. rbac.namespaces overrides.
*/}}
{{- define "observer.targetNamespaces" -}}
{{- if .Values.rbac.namespaces -}}
{{- .Values.rbac.namespaces | sortAlpha | uniq | join "," -}}
{{- else -}}
{{- $ns := list -}}
{{- $default := .Values.targets.namespace | default .Release.Namespace -}}
{{- $entries := list -}}
{{- range (splitList "," (default "" .Values.targets.configmaps)) -}}
{{- $entries = append $entries . -}}
{{- end -}}
{{- range (splitList "," (default "" .Values.targets.deployments)) -}}
{{- $entries = append $entries . -}}
{{- end -}}
{{- range $entries -}}
{{- $e := trim . -}}
{{- if $e -}}
{{- if contains "/" $e -}}
{{- $ns = append $ns (first (splitList "/" $e)) -}}
{{- else -}}
{{- $ns = append $ns $default -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $ns | uniq | sortAlpha | join "," -}}
{{- end -}}
{{- end -}}

{{- define "observer.secretName" -}}
{{- default (printf "%s-credentials" (include "observer.fullname" .)) .Values.couchbase.existingSecret -}}
{{- end -}}

{{- define "observer.webhookSecretName" -}}
{{- default (printf "%s-credentials" (include "observer.fullname" .)) .Values.webhook.existingSecret -}}
{{- end -}}

{{/* The chart creates a Secret only for credentials given inline. */}}
{{- define "observer.createsSecret" -}}
{{- if not .Values.couchbase.existingSecret -}}true
{{- else if and (eq (include "observer.hasWebhookActuator" .) "true") (not .Values.webhook.existingSecret) (or .Values.webhook.username .Values.webhook.password) -}}true
{{- end -}}
{{- end -}}

{{/* Couchbase CA: an existing Secret wins, otherwise the chart holds the inline PEM. */}}
{{- define "observer.caSecretName" -}}
{{- if .Values.tls.existingCaSecret -}}{{ .Values.tls.existingCaSecret }}
{{- else if .Values.tls.caCert -}}{{ printf "%s-ca" (include "observer.fullname" .) }}
{{- end -}}
{{- end -}}

{{- define "observer.webhookCaSecretName" -}}
{{- if .Values.webhook.existingCaSecret -}}{{ .Values.webhook.existingCaSecret }}
{{- else if .Values.webhook.caCert -}}{{ printf "%s-webhook-ca" (include "observer.fullname" .) }}
{{- end -}}
{{- end -}}

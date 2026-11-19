{{- define "demo-api.labels" -}}
app.kubernetes.io/name: demo-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "demo-api.image" -}}
{{ required "image.repository is required" .Values.image.repository }}:{{ required "image.tag is required" .Values.image.tag }}
{{- end }}

{{- define "demo-api.isRollout" -}}
{{- if has .Values.strategy (list "canary" "blueGreen") }}true{{- end }}
{{- end }}

{{/* The pod template is identical for a Deployment and a Rollout. Only the release
     strategy around it differs. */}}
{{- define "demo-api.podTemplate" -}}
metadata:
  labels: {{- include "demo-api.labels" . | nindent 4 }}
spec:
  serviceAccountName: {{ .Values.serviceAccount.name }}
  securityContext: {{- toYaml .Values.podSecurityContext | nindent 4 }}
  {{- with .Values.nodeSelector }}
  nodeSelector: {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if .Values.topologySpread.enabled }}
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels: {{- include "demo-api.labels" . | nindent 10 }}
  {{- end }}
  # Time to finish requests in flight after the pod is told to stop.
  terminationGracePeriodSeconds: 30
  containers:
    - name: demo-api
      image: {{ include "demo-api.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: {{ .Values.containerPort }}
      env:
        - name: VERSION
          value: {{ .Values.image.tag | quote }}
        - name: REGION
          value: {{ .Values.region | quote }}
        - name: ENVIRONMENT
          value: {{ .Values.environment | quote }}
        - name: POD_NAME
          valueFrom:
            fieldRef: {fieldPath: metadata.name}
        - name: NODE_NAME
          valueFrom:
            fieldRef: {fieldPath: spec.nodeName}
      # readiness: may this pod receive traffic? liveness: should it be restarted?
      readinessProbe:
        httpGet: {path: /readyz, port: http}
        periodSeconds: 5
      livenessProbe:
        httpGet: {path: /healthz, port: http}
        initialDelaySeconds: 10
        periodSeconds: 10
      lifecycle:
        # Keep serving for a few seconds while the load balancer stops sending requests.
        preStop:
          sleep: {seconds: 5}
      resources: {{- toYaml .Values.resources | nindent 8 }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: secrets
          mountPath: /secrets
          readOnly: true
  volumes:
    # The Secret that External Secrets builds from Vault. Optional, so the pod still starts
    # if Vault is not configured yet; the files appear by themselves once it is.
    - name: secrets
      secret:
        secretName: {{ .Release.Name }}-vault
        optional: true
{{- end }}

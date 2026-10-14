{{/*
Weiger te renderen als de bevestiging niet klopt. Wordt aangeroepen vanuit elk
template, zodat er nooit een half gerenderde set ontstaat.
*/}}
{{- define "demo-reset.guard" -}}
{{- if not .Values.tenant.name -}}
{{- fail "tenant.name is leeg: de ApplicationSet hoort hem te zetten." -}}
{{- end -}}
{{- if not .Values.tenant.host -}}
{{- fail "tenant.host is leeg: de ApplicationSet hoort hem te zetten." -}}
{{- end -}}
{{- if ne .Values.demoReset.confirmWipe .Values.tenant.name -}}
{{- fail (printf "tenant.components.demoReset.confirmWipe moet letterlijk de tenantnaam zijn (%q), maar is %q. Deze component wist elke nacht de tenant; er wordt niets gerenderd." .Values.tenant.name .Values.demoReset.confirmWipe) -}}
{{- end -}}
{{- if not (has .Values.demoReset.exampleSetMode (list "install" "reinstall")) -}}
{{- fail (printf "demoReset.exampleSetMode %q is onbekend; verwacht install of reinstall." .Values.demoReset.exampleSetMode) -}}
{{- end -}}
{{- end -}}

{{- define "demo-reset.labels" -}}
app.kubernetes.io/name: tenant-demo-reset
app.kubernetes.io/part-of: nextcloud-platform
nextcloud.platform/tenant: {{ .Values.tenant.name | quote }}
{{- end -}}

{{/*
Pod-template voor beide CronJobs. Argument: dict "root" . "mode" "reset|golden".
De Job raakt zelf geen volume van de tenant aan; alles gaat via kubectl exec.
Daarom geen nodeSelector en geen affinity: hij mag overal draaien.
*/}}
{{- define "demo-reset.pod" -}}
{{- $root := .root -}}
metadata:
  labels:
    {{- include "demo-reset.labels" $root | nindent 4 }}
    nextcloud.platform/demo-reset-mode: {{ .mode }}
spec:
  serviceAccountName: demo-reset
  automountServiceAccountToken: true
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: demo-reset
      image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
      imagePullPolicy: {{ $root.Values.image.pullPolicy }}
      command: ["bash", "/scripts/demo-reset.sh", {{ .mode | quote }}]
      env:
        - name: HOME
          value: /tmp
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: TENANT_NAME
          value: {{ $root.Values.tenant.name | quote }}
        - name: TENANT_HOST
          value: {{ $root.Values.tenant.host | quote }}
        - name: CONFIRM_WIPE
          value: {{ $root.Values.demoReset.confirmWipe | quote }}
        - name: EXAMPLE_SETS
          value: {{ join " " $root.Values.demoReset.exampleSets | quote }}
        - name: EXAMPLE_SET_MODE
          value: {{ $root.Values.demoReset.exampleSetMode | quote }}
        {{- if $root.Values.demoReset.exampleSetPasswordSecret }}
        - name: PASSWORD_FILE
          value: /secrets/demo-password
        {{- end }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        {{- toYaml $root.Values.resources | nindent 8 }}
      volumeMounts:
        - name: script
          mountPath: /scripts
          readOnly: true
        - name: tmp
          mountPath: /tmp
        {{- if $root.Values.demoReset.exampleSetPasswordSecret }}
        - name: demo-password
          mountPath: /secrets
          readOnly: true
        {{- end }}
  volumes:
    - name: script
      configMap:
        name: demo-reset-script
        defaultMode: 0555
    - name: tmp
      emptyDir: {}
    {{- if $root.Values.demoReset.exampleSetPasswordSecret }}
    - name: demo-password
      secret:
        secretName: {{ $root.Values.demoReset.exampleSetPasswordSecret | quote }}
        items:
          - key: demo-password
            path: demo-password
    {{- end }}
{{- end -}}

# OPA/Conftest policies for Nextcloud Platform
# Run with: conftest test <manifest.yaml> --policy policy/

package main

import future.keywords.in

# Deny deployments without resource limits
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    not container.resources.limits
    msg := sprintf("Deployment '%s' container '%s' has no resource limits", [input.metadata.name, container.name])
}

# Deny deployments without resource requests
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    not container.resources.requests
    msg := sprintf("Deployment '%s' container '%s' has no resource requests", [input.metadata.name, container.name])
}

# Warn if using :latest tag
warn[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    endswith(container.image, ":latest")
    msg := sprintf("Container '%s' in Deployment '%s' uses :latest tag - pin to specific version", [container.name, input.metadata.name])
}

# Deny privileged containers
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    container.securityContext.privileged == true
    msg := sprintf("Container '%s' in Deployment '%s' is privileged - not allowed", [container.name, input.metadata.name])
}

# Deny containers running as root
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    container.securityContext.runAsUser == 0
    msg := sprintf("Container '%s' in Deployment '%s' runs as root (uid 0) - not allowed", [container.name, input.metadata.name])
}

# Warn if no readiness probe
warn[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    not container.readinessProbe
    msg := sprintf("Container '%s' in Deployment '%s' has no readiness probe", [container.name, input.metadata.name])
}

# Warn if no liveness probe
warn[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    not container.livenessProbe
    msg := sprintf("Container '%s' in Deployment '%s' has no liveness probe", [container.name, input.metadata.name])
}

# Deny hostNetwork
deny[msg] {
    input.kind == "Deployment"
    input.spec.template.spec.hostNetwork == true
    msg := sprintf("Deployment '%s' uses hostNetwork - not allowed", [input.metadata.name])
}

# Deny hostPID
deny[msg] {
    input.kind == "Deployment"
    input.spec.template.spec.hostPID == true
    msg := sprintf("Deployment '%s' uses hostPID - not allowed", [input.metadata.name])
}

# Warn if Service uses NodePort
warn[msg] {
    input.kind == "Service"
    input.spec.type == "NodePort"
    msg := sprintf("Service '%s' uses NodePort - prefer ClusterIP with Ingress", [input.metadata.name])
}

# Warn if Service uses LoadBalancer
warn[msg] {
    input.kind == "Service"
    input.spec.type == "LoadBalancer"
    msg := sprintf("Service '%s' uses LoadBalancer - prefer ClusterIP with Ingress", [input.metadata.name])
}

# Deny Ingress without TLS
deny[msg] {
    input.kind == "Ingress"
    not input.spec.tls
    msg := sprintf("Ingress '%s' has no TLS configuration - HTTPS required", [input.metadata.name])
}

# Warn if PVC uses RWX (potential NFS dependency)
warn[msg] {
    input.kind == "PersistentVolumeClaim"
    input.spec.accessModes[_] == "ReadWriteMany"
    msg := sprintf("PVC '%s' uses ReadWriteMany - ensure this is provider-managed CephFS, not in-cluster NFS", [input.metadata.name])
}

# Deny if namespace is default
deny[msg] {
    input.metadata.namespace == "default"
    msg := sprintf("%s '%s' is in the 'default' namespace - use dedicated namespace", [input.kind, input.metadata.name])
}

# Require specific labels on Deployments
deny[msg] {
    input.kind == "Deployment"
    not input.metadata.labels["app.kubernetes.io/name"]
    msg := sprintf("Deployment '%s' missing required label 'app.kubernetes.io/name'", [input.metadata.name])
}

# Warn if memory limit is too high (potential resource hog)
warn[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    memory_limit := container.resources.limits.memory
    contains(memory_limit, "Gi")
    memory_value := to_number(replace(memory_limit, "Gi", ""))
    memory_value > 8
    msg := sprintf("Container '%s' has memory limit > 8Gi (%s) - review if necessary", [container.name, memory_limit])
}

# Nextcloud-specific: Warn if S3 config appears to be missing
warn[msg] {
    input.kind == "ConfigMap"
    input.metadata.name == "nextcloud-config"
    data := input.data
    not contains_s3_config(data)
    msg := "Nextcloud ConfigMap may be missing S3 object storage configuration - user files should use S3"
}

contains_s3_config(data) {
    some key
    value := data[key]
    contains(value, "objectstore")
}

contains_s3_config(data) {
    some key
    value := data[key]
    contains(value, "S3")
}


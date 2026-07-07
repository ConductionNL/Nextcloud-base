# Values file guardrails
# Package: values  (run with: conftest test <file> --policy policy/ --namespace values)
#
# Purpose: Block canary-only or HA-specific experiment settings from being
# committed to shared values files (common.yaml, env/*.yaml). These files
# affect ALL tenants simultaneously.
#
# Canary experiments belong in values/canary-overrides.yaml, which is only
# loaded when tenant.canary: true via the ApplicationSet.
#
# These checks run in CI as a hard gate (no || true).
# Run locally: conftest test values/common.yaml values/env/*.yaml \
#              --policy policy/ --namespace values
#
# Syntax: Rego v1 (OPA >= 1.0 / conftest >= 0.56 vereist `if` en `contains`;
# gemoderniseerd 2026-07-07 — de oude syntax parste niet meer en liet de
# gate fail-closed afgaan met een misleidende melding).

package values

# ---------------------------------------------------------------------------
# Storage: RWX access mode must not be in shared files
# Risk: Forces ALL tenants onto ReadWriteMany — breaks tenants without
#       a cluster-aware CSI driver and causes concurrent-write corruption
#       on single-node filesystems (as we found on 2026-03-09).
# ---------------------------------------------------------------------------
deny contains msg if {
    input.persistence.accessMode == "ReadWriteMany"
    msg := "persistence.accessMode=ReadWriteMany found in a shared values file — move to values/canary-overrides.yaml or a per-tenant file (risk: concurrent ext4 corruption on all tenants)"
}

# ---------------------------------------------------------------------------
# Storage: Cinder RWX storage class must not be in shared files
# Risk: Silently migrates all tenant PVCs to cinder-rwx on next sync,
#       which would trigger PVC recreation and data loss for all tenants.
# ---------------------------------------------------------------------------
deny contains msg if {
    input.persistence.storageClass == "cinder-rwx"
    msg := "persistence.storageClass=cinder-rwx found in a shared values file — move to values/canary-overrides.yaml or a per-tenant file (risk: mass PVC migration for all tenants)"
}

# ---------------------------------------------------------------------------
# Replica count: RS>1 must not be set in common.yaml or env/prod.yaml
# until HA storage is validated and rolled out to all tenants.
# Risk: Starts RS=2 for tenants still on RWO PVCs, causing stuck rollouts.
# ---------------------------------------------------------------------------
deny contains msg if {
    input.replicaCount > 1
    msg := sprintf("replicaCount=%d found in a shared values file — gate behind tenant.canary first, then graduate to env/prod.yaml only after all tenant PVCs are migrated to RWX", [input.replicaCount])
}

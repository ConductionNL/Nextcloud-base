## Why

Nextcloud pods cannot run at RS>1 because the `/var/www/html` code volume uses a RWO Cinder PVC — only one node can mount it at a time. With pod anti-affinity across nodes this permanently blocks high availability, HPA, and zero-downtime rolling updates. The infrastructure and HPA wiring already exist; only the storage constraint remains.

## What Changes

- **BREAKING**: Replace the RWO Cinder StorageClass with a Cinder multi-attach (`tier-1m`) StorageClass that supports `ReadWriteMany` — all replica pods share the same `/var/www/html` volume
- New `StorageClass` `cinder-rwx` deployed to `cluster-infra` using `cinder.csi.openstack.org` with `type: tier-1m`
- `persistence.accessMode` in `common.yaml` changed from `ReadWriteOnce` to `ReadWriteMany`
- `persistence.storageClass` in `common.yaml` set to `cinder-rwx`
- `replicaCount` in `prod.yaml` raised to 2; `strategy: maxSurge:1 / maxUnavailable:0` re-enabled
- HPA (already wired in `charts/tenant-hpa`) becomes active once RS>1 is stable
- `canary: true` boolean added to canary-prod tenant to gate experimental settings before prod rollout

## Capabilities

### New Capabilities

- `ha-storage`: Cinder multi-attach RWX PVC enabling multi-node pod scheduling without filesystem infrastructure changes
- `canary-gating`: Tenant-level boolean to enable experimental settings on canary tenants before rolling to prod

### Removed from Scope

- `custom-image`: No longer needed — Cinder multi-attach shares the code volume across pods, removing the need for emptyDir + baked apps. Apps continue to be enabled via the existing hook.

## Impact

- `cluster-infra`: New `cinder-rwx` StorageClass manifest
- `nextcloud-platform/values/common.yaml`: `persistence.accessMode`, `persistence.storageClass`
- `nextcloud-platform/values/env/prod.yaml`: `replicaCount`, `strategy`
- `nextcloud-platform/values/tenants/tenant-canary-prod.yaml`: `tenant.canary: true`
- `nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml`: canary boolean templating
- Existing `charts/tenant-hpa`: no changes needed, becomes active automatically

## 1. Infra Prep — additive, no platform impact

- [ ] 1.1 Add `StorageClass` manifest `cinder-rwx` to `cluster-infra`:
  ```yaml
  provisioner: cinder.csi.openstack.org
  parameters:
    type: tier-1m
  allowVolumeExpansion: true
  reclaimPolicy: Retain
  volumeBindingMode: WaitForFirstConsumer
  ```
- [ ] 1.2 Apply StorageClass to cluster and verify: `kubectl get sc cinder-rwx`
- [ ] 1.3 Create a test PVC (`accessModes: [ReadWriteMany]`, `storageClassName: cinder-rwx`, 1Gi) in a scratch namespace and confirm it binds — **this proves `tier-1m` supports RWX before touching any tenant**
- [ ] 1.4 Delete the test PVC and scratch namespace

## 2. ApplicationSet: canary gating — no impact on prod

- [ ] 2.1 Add `tenant.canary` boolean support to ApplicationSet inline `values:` block: when `{{ .tenant.canary }}` is true, inject `replicaCount: "2"`
- [ ] 2.2 Update `nextcloud-platform/values/tenants/tenant-canary-prod.yaml`: add `tenant.canary: true`

## 3. canary-prod: PVC migration — isolated to nc-canary-prod

- [ ] 3.1 Enable maintenance mode on canary-prod: `kubectl exec -n nc-canary-prod deploy/nc-canary-prod-nextcloud -- occ maintenance:mode --on`
- [ ] 3.2 Scale canary-prod to 0: `kubectl scale deploy -n nc-canary-prod --all --replicas=0`
- [ ] 3.3 Snapshot the existing PVC: `openstack volume snapshot create --name canary-prod-html-backup <volume-id>`
- [ ] 3.4 Record any data that must survive migration (config.php content)
- [ ] 3.5 Delete the old `/var/www/html` PVC: `kubectl delete pvc -n nc-canary-prod <pvc-name>`
- [ ] 3.6 Update `common.yaml` (or canary-prod override):
  - `persistence.accessMode: ReadWriteMany`
  - `persistence.storageClass: cinder-rwx`
- [ ] 3.7 Sync `nc-canary-prod` via Argo CD — new PVC is created with `cinder-rwx` StorageClass
- [ ] 3.8 Wait for both pods to reach Running state; verify on different nodes: `kubectl get pods -n nc-canary-prod -o wide`

## 4. canary-prod: Validation

- [ ] 4.1 Verify RS=2: `kubectl get deploy -n nc-canary-prod` shows `2/2`
- [ ] 4.2 Verify pods are on different nodes: `kubectl get pods -n nc-canary-prod -o wide` — NODE column must differ
- [ ] 4.3 Disable maintenance mode: `kubectl exec -n nc-canary-prod <any-pod> -- occ maintenance:mode --off`
- [ ] 4.4 Verify apps are enabled: `kubectl exec -n nc-canary-prod <any-pod> -- occ app:list | grep -E 'opencatalogi|openconnector|openregister'`
- [ ] 4.5 Trigger a rolling update (e.g., bump a label or annotation) and confirm zero downtime — second pod stays Running while first restarts
- [ ] 4.6 Verify HPA is active: `kubectl get hpa -n nc-canary-prod`
- [ ] 4.7 Write test to config from pod-1, read from pod-2 to verify shared volume: `kubectl exec pod-1 -- touch /var/www/html/config/test-rwx && kubectl exec pod-2 -- ls /var/www/html/config/test-rwx`
- [ ] 4.8 Clean up test file: `kubectl exec pod-1 -- rm /var/www/html/config/test-rwx`

## 5. Prod Rollout — only after canary passes

- [ ] 5.1 Update `nextcloud-platform/values/env/prod.yaml`: set `replicaCount: 2`, add `strategy: {type: RollingUpdate, rollingUpdate: {maxSurge: 1, maxUnavailable: 0}}`
- [ ] 5.2 Migrate each prod tenant PVC (repeat steps 3.1–3.8 per tenant namespace, in wave order)
  - Priority order: wave 0 first (canary already done), then wave 1 tenants alphabetically
- [ ] 5.3 Wait for 17:00 sync window — verify all prod tenants reach `2/2` healthy replicas
- [ ] 5.4 Confirm HPA active for all prod tenants: `kubectl get hpa -A | grep nc-`
- [ ] 5.5 Remove `tenant.canary: true` from `tenant-canary-prod.yaml` (it now gets replicaCount from prod.yaml like all others) — or keep for future canary overrides

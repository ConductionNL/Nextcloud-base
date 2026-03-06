## ADDED Requirements

### Requirement: Cinder multi-attach StorageClass is available in cluster
A `StorageClass` named `cinder-rwx` SHALL exist in the cluster, backed by `cinder.csi.openstack.org` with `parameters.type: tier-1m` and `reclaimPolicy: Retain`.

#### Scenario: StorageClass exists and is available
- **WHEN** `kubectl get sc cinder-rwx` is run
- **THEN** the StorageClass is listed and its provisioner is `cinder.csi.openstack.org`

#### Scenario: Test PVC binds with ReadWriteMany
- **WHEN** a PVC with `storageClassName: cinder-rwx` and `accessModes: [ReadWriteMany]` is created
- **THEN** the PVC reaches `Bound` status, confirming `tier-1m` supports multi-attach

### Requirement: `/var/www/html` PVC uses ReadWriteMany
The Nextcloud Helm values SHALL configure `persistence.accessMode: ReadWriteMany` and `persistence.storageClass: cinder-rwx` so that all replica pods can mount the code volume simultaneously.

#### Scenario: Two pods mount the volume on different nodes
- **WHEN** a Deployment with `replicaCount: 2` and pod anti-affinity is created
- **THEN** both pods reach `Running` status on separate nodes without any PVC mount contention

#### Scenario: File written by one pod is visible to another
- **WHEN** pod-1 creates a file at `/var/www/html/config/test-rwx`
- **THEN** pod-2 can immediately read that file (shared block device, same filesystem state)

### Requirement: PVC is retained on Helm uninstall
The `/var/www/html` PVC SHALL be annotated with `helm.sh/resource-policy: keep` so that it survives a Helm chart uninstall or ApplicationSet sync that removes resources.

#### Scenario: PVC survives pod restart
- **WHEN** all pods in a tenant namespace are terminated and restarted
- **THEN** the PVC is reattached and `/var/www/html` contents (including `config.php` and `custom_apps/`) are intact

### Requirement: Nginx sidecar mounts the same code volume
The nginx sidecar container SHALL mount the same PVC at `/var/www/html` via `nginx.extraVolumeMounts` in the Helm values, so it serves the code tree from the shared volume.

#### Scenario: Nginx serves files from the shared PVC
- **WHEN** PHP-FPM processes a request and nginx proxies the response
- **THEN** nginx reads PHP files from `/var/www/html` on the same Cinder volume — no file-not-found errors

### Requirement: PVC migration does not lose data
When migrating a tenant from RWO to RWX:
- The existing PVC SHALL be snapshotted before deletion
- Maintenance mode SHALL be enabled before scaling down
- The new PVC SHALL be populated by the Nextcloud entrypoint on first pod start

#### Scenario: Rollback from failed migration
- **WHEN** the new RWX PVC fails to bind or pods fail to start
- **THEN** the operator can restore from the volume snapshot and revert `common.yaml` to `ReadWriteOnce` + original StorageClass

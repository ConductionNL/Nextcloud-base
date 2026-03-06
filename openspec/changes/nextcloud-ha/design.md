## Context

Nextcloud tenants run as a Kubernetes Deployment with a single RWO Cinder PVC for `/var/www/html`. Pod anti-affinity spreads replicas across nodes, but only one node can mount a RWO Cinder volume — the second pod is permanently stuck in `Init:0/1`. This makes RS>1, HPA, and zero-downtime rolling updates impossible with the current storage layout.

S3 (Fuga Cloud Ceph RGW) already handles all user data. The Nextcloud code directory is predominantly read-only at runtime: PHP files do not change between upgrades; session state is in Redis; uploads go to S3. The only writes to `/var/www/html` at runtime are:
- `config/config.php` — written during admin changes, `occ` commands, maintenance mode toggle (infrequent, operator-triggered)
- `custom_apps/` — written during initial pod start (hook-based app enable) and app updates (admin-triggered)

Fuga Cloud provides Cinder volume types with multi-attach support: `tier-1m` (replicated SSD) and `tier-2m` (replicated HDD). These types allow a single Cinder volume to be attached to multiple nodes simultaneously, enabling `ReadWriteMany` access from multiple pods.

Manila CSI (CephFS RWX) was the first candidate but is **not available** on Fuga Cloud — `openstack catalog list` returns no `shared-file-system` endpoint despite topology labels being present on nodes (placed speculatively by Gardener).

## Goals / Non-Goals

**Goals:**
- Enable RS=2 for all prod tenants (two healthy pods on different nodes)
- Enable HPA (already wired, needs RS>1 to activate)
- Enable zero-downtime rolling updates (`maxUnavailable: 0`)

**Non-Goals:**
- RS>2 (not needed now; architecture supports it once RS=2 is proven)
- Replacing the S3 object store (already working)
- Custom Docker image (removed from scope — no longer needed)
- CephFS / Manila CSI (not available on Fuga Cloud)
- NFS (ruled out by ops policy: stale mounts during provider maintenance)

## Decisions

### Decision 1: Cinder multi-attach RWX for `/var/www/html`

**Choice**: Create a new StorageClass `cinder-rwx` using `cinder.csi.openstack.org` with `type: tier-1m`. Change the existing `/var/www/html` PVC `accessMode` from `ReadWriteOnce` to `ReadWriteMany`. All replica pods share the same block volume.

**Alternatives considered**:
- Manila CephFS RWX: not available on Fuga Cloud (no `shared-file-system` endpoint in the OpenStack catalog). Ruled out.
- emptyDir + custom image: each pod self-populates the code directory from the image; requires building and maintaining a custom Docker image with baked-in apps, plus a CI/CD pipeline. More complex, higher maintenance overhead. Viable but unnecessary given Cinder multi-attach is available.
- NFS: ruled out by ops policy (stale mounts on provider maintenance).
- RWO with single-node scheduling: gives up HA entirely.

**Why Cinder multi-attach wins**: minimal change surface — no new images, no new charts, no CI/CD pipeline. The storage type is already confirmed available (`openstack volume type list` shows `tier-1m` with `multiattach: True`).

**Risk: concurrent filesystem writes**
Cinder multi-attach attaches a single block device to multiple nodes. The device is formatted with ext4 by the CSI driver. ext4 does not coordinate writes across nodes at the filesystem level — simultaneous writes from two nodes can corrupt the volume.

Mitigation for Nextcloud's access pattern:
- PHP code files: read-only at runtime (changed only during Argo CD sync / `occ upgrade`). No concurrent write risk.
- `config/config.php`: written by admin operations and Nextcloud itself (maintenance mode). Mitigated by Redis file locking already enabled and the low probability of simultaneous admin ops on multiple pods.
- `custom_apps/`: written during hook execution at pod start. The hook checks for a state file before re-running; the state file lives on the shared PVC so only one pod runs the installation per cluster restart.
- **Maintenance mode**: before any platform upgrade or `occ` command, enable maintenance mode. This serialises Nextcloud's own writes.

**PVC migration**: existing RWO PVCs cannot be reclaimed as RWX. Migration procedure is documented in the Migration Plan below.

### Decision 2: Canary-first rollout via `tenant.canary` flag

**Choice**: Add `tenant.canary: true` to `tenant-canary-prod.yaml`. The ApplicationSet applies `replicaCount: 2` override for canary tenants. RS=2 is validated on canary before it becomes the `prod.yaml` default.

**Why**: canary-prod has a wave-0 always-allow sync window — it can be synced at any time, making it the ideal test target. Prod tenants are only affected after explicit `prod.yaml` update.

## Risks / Trade-offs

| Risk | Severity | Mitigation |
|------|----------|------------|
| ext4 concurrent writes corrupt volume | Medium | Nextcloud writes are infrequent and admin-serialised; Redis locking; maintenance mode before upgrades |
| PVC migration requires downtime per tenant | Low | Use Argo CD sync window; maintenance mode during migration; canary validates procedure first |
| `tier-1m` IOPS limits under RS>2 load | Low | Not planning RS>2; monitor with HPA metrics |
| Hook race: two pods both install apps simultaneously | Low | State file on shared PVC prevents double-run after first pod completes; worst case: idempotent re-install |

## Migration Plan

Existing PVCs are RWO and cannot be changed to RWX in-place. Each tenant PVC must be recreated.

Per-tenant procedure (start with canary-prod):
1. Enable Nextcloud maintenance mode: `occ maintenance:mode --on`
2. Scale deployment to 0: `kubectl scale deploy -n <ns> --replicas=0`
3. Create a temporary Pod to copy data off the existing PVC (or snapshot it)
4. Delete the old PVC
5. Update `common.yaml` (or tenant override) to `storageClass: cinder-rwx` and `accessMode: ReadWriteMany`
6. Let Argo CD recreate the PVC and Deployment
7. Scale to 2, verify both pods reach Running on different nodes
8. Disable maintenance mode

**Rollback**: revert `common.yaml` storageClass + accessMode; restore old PVC from snapshot or backup. Existing pod data survives if PVC is snapshotted before deletion.

## Open Questions

1. Does Fuga Cloud's `tier-1m` support the Kubernetes `ReadWriteMany` access mode via the Cinder CSI driver? (Verify by creating a test PVC with `accessModes: [ReadWriteMany]` before migrating canary-prod)
2. Is `helm.sh/resource-policy: keep` already on the existing PVCs? (If yes, Helm won't delete them automatically on value change — manual deletion required)
3. Should we snapshot PVCs before migration using `openstack volume snapshot create`?

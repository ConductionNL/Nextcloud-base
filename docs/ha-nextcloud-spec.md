# Spec: Nextcloud HA on Kubernetes (RS>1 + HPA)

**Status:** Draft
**Goal:** Enable true multi-replica Nextcloud pods per tenant, unblocking HPA and zero-downtime rolling updates.
**Prerequisite resolved:** S3 already eliminates the user-data PVC constraint. Only the code/config volume remains.

---

## Problem

The current RWO Cinder PVC for `/var/www/html` can only be mounted from one node at a time. With `replicaCount: 2` and pod anti-affinity across nodes, the second pod is stuck in `Init:0/1` forever. This prevents:

- RS>1 (HA)
- HPA (already wired, but dormant)
- Zero-downtime rolling updates (`maxUnavailable: 0` requires a healthy second pod to exist before old pod is killed)

---

## Storage Options Evaluated

### Option A: OpenStack Manila CephFS (RWX)

- **Provisioner**: `manila.csi.openstack.org`
- **Assessment**: The Manila topology labels (`topology.manila.csi.openstack.org/zone=ams2-a/b/c`) are present on all nodes — placed by the Manila CSI node plugin during registration. This strongly suggests Manila CSI is (or was) running. The `cephfs` StorageClass is already anticipated in the repo (`cephfs.storageclass.storage.k8s.io/requests.storage` quotas defined in resource-quotas.yaml).
- **Action needed**: Check `kubectl get csidriver manila.csi.openstack.org` and `kubectl get secret manila-cloud-config -n kube-system`. If present, create the StorageClass and it's ready to use.
- **Pro**: Provider-managed CephFS, true POSIX RWX, resilient across AZs, no stale mount risk (kernel CephFS client maintains mount through provider maintenance).
- **Con**: Requires Manila CSI driver deployed + OpenStack credentials with Manila access.

### Option B: Cinder Multi-Attach

- **Assessment**: Not suitable. Cinder provides block storage — simultaneous writes from multiple nodes without a clustered filesystem (OCFS2/GFS2) will corrupt data. Ruled out for shared POSIX directories.

### Option C: Ephemeral Code + Custom Image (Recommended)

See architecture section below.

---

## Recommended Architecture: Custom Image + emptyDir + Small Config PVC

### How the Nextcloud Docker Image Already Supports This

The official Nextcloud image stores pristine code in `/usr/src/nextcloud/`. On every pod start, the entrypoint rsyncs it to `/var/www/html/` if `version.php` is absent:

```bash
# From nextcloud/docker entrypoint.sh
if [ ! -e /var/www/html/version.php ]; then
    rsync -rlD --delete --exclude-from=/upgrade.exclude /usr/src/nextcloud/ /var/www/html/
fi
```

This means: mount `/var/www/html` as an `emptyDir` and each pod self-populates on startup from the image. No explicit init container needed. Startup takes 30–90s (rsync of ~500MB PHP files) — covered by the existing `startupProbe` (`failureThreshold: 60 × 10s = 600s`).

### Volume Layout

| Path | Volume type | Access | Notes |
|---|---|---|---|
| `/var/www/html` | emptyDir | per-pod | self-populated from image on start |
| `/var/www/html/custom_apps` | baked into image | per-pod | no PVC needed |
| `/var/www/html/config` | small PVC, 1Gi RWX | shared | config.php, must be writable |
| `/var/www/html/data` | not mounted | — | S3 as primary object store |

### Custom Image (Bakes Apps In)

Apps live in `/usr/src/nextcloud/custom_apps/` in the image. On first start they rsync into `/var/www/html/custom_apps/`. No hook download, no network dependency on GitHub at startup, deterministic versions.

```dockerfile
FROM nextcloud:32.x-fpm

ARG OPENCATALOGI_VERSION
ARG OPENCONNECTOR_VERSION
ARG OPENREGISTER_VERSION

RUN mkdir -p /usr/src/nextcloud/custom_apps && \
    curl -fsSL "https://github.com/ConductionNL/opencatalogi/releases/download/v${OPENCATALOGI_VERSION}/opencatalogi-${OPENCATALOGI_VERSION}.tar.gz" \
      | tar -xz -C /usr/src/nextcloud/custom_apps/ && \
    curl -fsSL "https://github.com/ConductionNL/openconnector/releases/download/v${OPENCONNECTOR_VERSION}/openconnector-${OPENCONNECTOR_VERSION}.tar.gz" \
      | tar -xz -C /usr/src/nextcloud/custom_apps/ && \
    curl -fsSL "https://github.com/ConductionNL/openregister/releases/download/v${OPENREGISTER_VERSION}/openregister-${OPENREGISTER_VERSION}.tar.gz" \
      | tar -xz -C /usr/src/nextcloud/custom_apps/ && \
    chown -R www-data:www-data /usr/src/nextcloud/custom_apps/

# Image tag = nextcloud version + app versions, e.g.:
# ghcr.io/conductionnl/nextcloud:32.0.5-oc0.7.7-con0.2.8-reg0.2.10
```

CI builds a new image on each Nextcloud or Conduction app release. Pin `image.tag` per tenant in tenant YAML or globally in `common.yaml`.

### Config PVC: Why It Must Remain Writable

`config.php` is written by Nextcloud during:
- Maintenance mode toggle (appstore, updates)
- `occ` commands
- Admin UI settings changes

A read-only Secret mount breaks the appstore and all admin operations. The config directory must be a writable shared volume. A 1Gi CephFS RWX PVC is the right solution. Until Manila is available, a small in-cluster share could work as a temporary bridge.

**Concurrent writes to config.php**: safe in practice. Normal request handling never writes to `config.php`. Only admin operations do, and those are serialised by the operator (one at a time). Redis file locking already covers Nextcloud-level locking.

### Hook Changes Needed

The `before-starting` hook state file lives at `/var/www/html/data/.conduction-apps-state`. With emptyDir for `/var/www/html`, `data/` is ephemeral — the hook re-runs on every pod start. Two changes needed:

1. Move state file to config PVC: change `STATE_FILE="/var/www/html/config/.conduction-apps-state"`
2. Simplify hook to only run `occ app:enable` (apps are in image, no install/download needed)

### Helm Values Changes

```yaml
# common.yaml
image:
  repository: ghcr.io/conductionnl/nextcloud
  tag: "32.0.5-oc0.7.7-con0.2.8-reg0.2.10"  # custom image

persistence:
  enabled: false  # disable main RWO PVC

extraVolumes:
  - name: nextcloud-html
    emptyDir: {}
  - name: nextcloud-config
    persistentVolumeClaim:
      claimName: nextcloud-config  # created by tenant-hpa chart or separate chart

extraVolumeMounts:
  - name: nextcloud-html
    mountPath: /var/www/html
  - name: nextcloud-config
    mountPath: /var/www/html/config

# nginx sidecar also needs the html volume
nginx:
  extraVolumeMounts:
    - name: nextcloud-html
      mountPath: /var/www/html

# prod.yaml
replicaCount: 2
strategy:
  maxSurge: 1
  maxUnavailable: 0
```

The config PVC (RWX, 1Gi CephFS) needs to be provisioned per tenant before the first deploy. This can be handled by the `tenant-hpa` chart or a new `tenant-volumes` chart alongside the ApplicationSet.

---

## HPA (Already Implemented, Waiting on RS>1)

The `charts/tenant-hpa` chart is already deployed for prod tenants using `AverageValue` metrics. Once RS>1 works, HPA auto-scales immediately. Current thresholds:

| Metric | Target (AverageValue) | Trigger at |
|---|---|---|
| CPU | 2000m | 50% of 4-core limit |
| Memory | 2Gi | 50% of 4Gi limit |

**Refinements to consider:**
- Reduce memory target to `1.5Gi` (37%) for earlier scale-out signal
- Add `scaleUp.stabilizationWindowSeconds: 30` + max 1 pod/minute policy to avoid thrashing
- Long-term: add PHP-FPM queue depth metric (requires `php-fpm_exporter` sidecar — `/fpm-status` endpoint is already enabled)

---

## Zero-Downtime Rolling Updates

With RWX config PVC and emptyDir code, the new pod can start independently on any node (no PVC contention). Re-enable in `prod.yaml`:

```yaml
strategy:
  maxSurge: 1
  maxUnavailable: 0
```

New pod starts → rsyncs code from image (~90s) → mounts shared config PVC → serves traffic → old pod removed. Zero downtime.

---

## Canary Boolean (Tenant Template)

To gate experimental settings on canary before rolling to prod, add an opt-in flag in the tenant YAML:

```yaml
# tenant-canary-prod.yaml
tenant:
  name: canary-prod
  environment: prod
  canary: true  # enables experimental overrides
```

The ApplicationSet inline values block can apply overrides when `{{ .tenant.canary }}` is true (e.g., RS=2 before it's the prod default, new HPA thresholds, etc.). Implement via a conditional block in the ApplicationSet `values:` or a `tenant-canary-overrides.yaml` values file.

---

## Implementation Plan

### Step 1: Verify Manila availability (15 min)
```bash
kubectl get csidriver manila.csi.openstack.org
kubectl get secret manila-cloud-config -n kube-system
```
If present → create `cephfs` StorageClass and test a 1Gi RWX PVC.
If absent → deploy Manila CSI from `cloud-provider-openstack` Helm chart using shoot cloud credentials.

### Step 2: Build CI pipeline for custom image (1–2 days)
- Create `Dockerfile` in new `docker/nextcloud/` directory
- GitHub Actions workflow: build + push to `ghcr.io/conductionnl/nextcloud` on tag
- Matrix build for Nextcloud versions × app version combinations

### Step 3: Implement volume changes in Helm values (2–3 hours)
- Switch `persistence.enabled: false`, add emptyDir + config PVC in `common.yaml`
- Update hook state file path
- Simplify hook to `occ app:enable` only
- Deploy to `canary-prod` first

### Step 4: Validate on canary-prod (1 day soak)
- Verify RS=2 both pods healthy
- Verify HPA scales on load
- Verify rolling update completes without downtime
- Verify appstore works (config.php writable)

### Step 5: Roll to prod tenants
- Set `replicaCount: 2` in `prod.yaml`
- Re-enable `strategy: maxSurge: 1, maxUnavailable: 0`
- Merge → Argo CD syncs at 17:00

---

## Open Questions

1. Is `manila.csi.openstack.org` available? (Check before building anything)
2. What's the Fuga Cloud procedure for requesting a Manila share type? (If driver is present but no share type configured)
3. Per-tenant app version pinning with custom image: use image tags per tenant, or a single "latest stable" image for all?
4. Should the config PVC be provisioned by the ApplicationSet (new `tenant-volumes` chart source) or pre-created by the `/add-tenant` skill?

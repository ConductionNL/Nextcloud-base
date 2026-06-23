# Nextcloud Platform Upgrade Guide

This document describes the upgrade process for the Nextcloud platform.

## Table of Contents

- [Pre-Upgrade Checklist](#pre-upgrade-checklist)
- [Version Upgrade Process](#version-upgrade-process)
- [Canary Rollout](#canary-rollout)
- [Wave Rollout](#wave-rollout)
- [Validation Checks](#validation-checks)
- [Rollback Procedures](#rollback-procedures)
- [Troubleshooting](#troubleshooting)

## Pre-Upgrade Checklist

Before upgrading, verify:

- [ ] Read Nextcloud release notes for the target version
- [ ] Check for breaking changes in the Helm chart changelog
- [ ] Verify S3 storage is healthy
- [ ] Verify Redis is healthy
- [ ] Verify PostgreSQL/PgBouncer is healthy
- [ ] Take database backups for all tenants
- [ ] Notify users of planned maintenance window
- [ ] Ensure monitoring/alerting is active

## Version Upgrade Process

### Step 1: Update Chart Version

The chart version is **not** set in `values/common.yaml`. It lives in two places:

- Platform-wide default: the `nextcloud-tenants` ApplicationSet `targetRevision`
  (default `8.9.0`).
- Per-tenant override: `tenant.chartVersion` in the tenant's values file.

For a single tenant or canary-first rollout, set `tenant.chartVersion` in that
tenant's file (leave the ApplicationSet default untouched):

```yaml
tenant:
  chartVersion: "8.10.0"  # Update to new chart version for this tenant only
```

For a platform-wide bump, edit the ApplicationSet `targetRevision`:

```yaml
spec:
  template:
    spec:
      source:
        targetRevision: "8.10.0"  # Update to new chart version for all tenants
```

### Step 2: Update Image Tag (if needed)

```yaml
image:
  repository: nextcloud
  tag: "<version>-apache"  # Update to new Nextcloud version (chart 8.9.x ships a recent release)
```

### Step 3: Review New Configuration Options

Check if new Nextcloud version requires config changes:

```bash
# Compare current config with new version defaults
helm show values nextcloud/nextcloud --version 8.10.0 > /tmp/new-defaults.yaml
diff values/common.yaml /tmp/new-defaults.yaml
```

### Step 4: Commit and Push

```bash
# For a single tenant: stage that tenant's values file.
# For a platform-wide bump: stage the ApplicationSet manifest.
git add <changed-file>
git commit -m "chore: upgrade Nextcloud chart to 8.10.0"
# Argo CD reads from Codeberg, not GitHub.
git push codeberg main
```

## Canary Rollout (Canary ring)

We use a **canary ring**: a small set of tenants that always receives upgrades first.

Recommended convention:

- `canary-accept`
- `canary-prod`

See `docs/ROLLOUTS.md` for the full promotion workflow (canary → batches).

### Monitor Canary Sync

```bash
# Watch Argo CD sync
argocd app get nc-canary-prod --refresh

# Or via kubectl
kubectl get application nc-canary-prod -n argocd -w
```

### Verify Canary Health

```bash
# Check pod status
kubectl get pods -n canary-prod

# Check Nextcloud status
kubectl exec -it -n canary-prod deploy/nextcloud -c nextcloud -- php occ status

# Check for errors
kubectl logs -n canary-prod deploy/nextcloud -c nextcloud -f
```

### Run Validation Checks on Canary

See [Validation Checks](#validation-checks) below.

## Batch Rollout (promotion)

For a safe rollout to many tenants, we **promote** changes in batches:

- first: canary ring
- then: stable ring in batches (e.g. 10 tenants per PR)

This is documented in `docs/ROLLOUTS.md`.

## Validation Checks

Run these checks on each wave before proceeding.

### 1. Nextcloud Status Check

```bash
TENANT_NS=canary-prod  # Change per tenant namespace
kubectl exec -it -n $TENANT_NS deploy/nextcloud -c nextcloud -- php occ status
```

Expected output (version reflects whatever the deployed chart ships):
```
- installed: true
- version: <major>.<minor>.<patch>.<build>
- versionstring: <major>.<minor>.<patch>
- edition: 
- maintenance: false
```

### 2. Database Integrity

```bash
# Check for missing indices
kubectl exec -it -n $TENANT_NS deploy/nextcloud -c nextcloud -- php occ db:add-missing-indices --dry-run

# Check for missing columns
kubectl exec -it -n $TENANT_NS deploy/nextcloud -c nextcloud -- php occ db:add-missing-columns --dry-run

# Run maintenance repair (dry-run first)
kubectl exec -it -n $TENANT_NS deploy/nextcloud -c nextcloud -- php occ maintenance:repair --dry-run
```

### 3. S3 Storage Check

```bash
# Check S3 connectivity
kubectl exec -it -n $TENANT_NS deploy/nextcloud -c nextcloud -- php occ files:scan --dry-run admin
```

### 4. WebDAV Upload/Download Test

```bash
# Set variables
TENANT_NS=canary-prod
HOST=canary.commonground.nu
PASSWORD=$(kubectl get secret -n $TENANT_NS nextcloud-secrets -o jsonpath='{.data.nextcloud-password}' | base64 -d)

# Upload test file
echo "test content $(date)" > /tmp/testfile.txt
curl -u admin:$PASSWORD -X PUT \
  -T /tmp/testfile.txt \
  "https://$HOST/remote.php/dav/files/admin/upgrade-test.txt"

# Download and verify
curl -u admin:$PASSWORD \
  "https://$HOST/remote.php/dav/files/admin/upgrade-test.txt"

# Cleanup
curl -u admin:$PASSWORD -X DELETE \
  "https://$HOST/remote.php/dav/files/admin/upgrade-test.txt"
```

### 5. Cron Job Status

```bash
# Check last cron execution
kubectl exec -it -n $TENANT_NS deploy/nextcloud -c nextcloud -- php occ background:job:list

# Check cron job status
kubectl get cronjob -n $TENANT_NS
```

### 6. Log Analysis

```bash
# Check for errors in last 10 minutes
kubectl logs -n $TENANT_NS deploy/nextcloud -c nextcloud --since=10m | grep -i error
```

## Rollback Procedures

### Quick Rollback (Argo CD)

Rollback to previous revision:

```bash
TENANT=canary-prod  # bare tenant name; the Argo Application is nc-<tenant>

# Get history
argocd app history nc-$TENANT

# Rollback to previous revision
argocd app rollback nc-$TENANT 1  # 1 = previous revision number
```

### Chart Version Rollback

If the upgrade needs to be reverted for all tenants:

```bash
# Revert the commit
git revert HEAD
git push codeberg main

# Or manually edit and push
git checkout HEAD~1 -- <changed-file>
git commit -m "revert: rollback Nextcloud to previous version"
git push codeberg main
```

### Emergency Rollback (All Tenants)

```bash
# Disable auto-sync for all applications
kubectl patch applicationset nextcloud-tenants -n argocd \
  --type=merge \
  -p '{"spec":{"template":{"spec":{"syncPolicy":{"automated":null}}}}}'

# Rollback each application
for app in $(argocd app list -l app.kubernetes.io/part-of=nextcloud-platform -o name); do
  argocd app rollback "$app" 1
done

# Re-enable auto-sync after issue is resolved
kubectl patch applicationset nextcloud-tenants -n argocd \
  --type=merge \
  -p '{"spec":{"template":{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}}}'
```

### Database Rollback

If database schema changes need to be reverted:

1. Put Nextcloud in maintenance mode (namespace is the bare tenant name):
   ```bash
   kubectl exec -it -n $TENANT deploy/nextcloud -- php occ maintenance:mode --on
   ```

2. Restore database from backup:
   ```bash
   # Example with pg_restore
   pg_restore -h $DB_HOST -U $DB_USER -d nextcloud_$TENANT backup.dump
   ```

3. Disable maintenance mode:
   ```bash
   kubectl exec -it -n $TENANT deploy/nextcloud -- php occ maintenance:mode --off
   ```

## Troubleshooting

### Common Issues

#### Issue: Pods stuck in ContainerCreating

Check for PVC issues:
```bash
kubectl describe pod -n $TENANT
kubectl describe pvc -n $TENANT
```

For S3-based architecture, this is usually limited to config PVC only.

#### Issue: S3 Connection Errors

```bash
# Check S3 credentials
kubectl get secret -n $TENANT nextcloud-secrets -o yaml

# Test S3 connectivity from pod
kubectl exec -it -n $TENANT deploy/nextcloud -- curl -I https://s3.example.com
```

#### Issue: Redis Connection Errors

```bash
# Check Redis service
kubectl get svc -n nextcloud-platform redis

# Test Redis connectivity
kubectl exec -it -n $TENANT deploy/nextcloud -- \
  redis-cli -h redis.nextcloud-platform.svc.cluster.local ping
```

#### Issue: Database Connection Errors

```bash
# Check PgBouncer
kubectl get pods -n nextcloud-platform -l app.kubernetes.io/name=pgbouncer

# Check database credentials
kubectl exec -it -n $TENANT deploy/nextcloud -- env | grep DB
```

### Health Check Commands

```bash
# Full system check
kubectl exec -it -n $TENANT deploy/nextcloud -- php occ check

# File integrity
kubectl exec -it -n $TENANT deploy/nextcloud -- php occ integrity:check-core

# App status
kubectl exec -it -n $TENANT deploy/nextcloud -- php occ app:list
```

### Getting Help

1. Check Nextcloud documentation: https://docs.nextcloud.com/
2. Check Helm chart issues: https://github.com/nextcloud/helm/issues
3. Review Argo CD logs: `kubectl logs -n argocd deploy/argocd-application-controller`


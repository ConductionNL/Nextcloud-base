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

Edit `values/common.yaml`:

```yaml
chart:
  version: "5.3.0"  # Update to new version
```

### Step 2: Update Image Tag (if needed)

```yaml
image:
  repository: nextcloud
  tag: "29.0.0-apache"  # Update to new Nextcloud version
```

### Step 3: Review New Configuration Options

Check if new Nextcloud version requires config changes:

```bash
# Compare current config with new version defaults
helm show values nextcloud/nextcloud --version 5.3.0 > /tmp/new-defaults.yaml
diff values/common.yaml /tmp/new-defaults.yaml
```

### Step 4: Commit and Push

```bash
git add values/common.yaml
git commit -m "chore: upgrade Nextcloud to 29.0.0 (chart 5.3.0)"
git push origin main
```

## Canary Rollout

The canary tenant (`nc-canary`) is configured with `wave: 0` and will be upgraded first.

### Monitor Canary Sync

```bash
# Watch Argo CD sync
argocd app get nc-canary --refresh

# Or via kubectl
kubectl get application nc-canary -n argocd -w
```

### Verify Canary Health

```bash
# Check pod status
kubectl get pods -n nc-canary

# Check Nextcloud status
kubectl exec -it -n nc-canary deploy/nextcloud -- php occ status

# Check for errors
kubectl logs -n nc-canary deploy/nextcloud -f
```

### Run Validation Checks on Canary

See [Validation Checks](#validation-checks) below.

## Wave Rollout

After canary validation, other tenants upgrade in waves:

| Wave | Description | Tenants |
|------|-------------|---------|
| 0 | Canary | nc-canary |
| 1 | Early adopters | First batch of prod tenants |
| 2 | Main batch | Most production tenants |
| 3 | Critical/Large | Large or business-critical tenants |

### Monitoring Wave Progress

```bash
# List all Nextcloud applications
argocd app list -l nextcloud.platform/tenant

# Check sync status per wave
for wave in 0 1 2 3; do
  echo "=== Wave $wave ==="
  argocd app list -l argocd.argoproj.io/sync-wave=$wave
done
```

### Manual Wave Control

If automatic sync is disabled, trigger waves manually:

```bash
# Sync wave 1
argocd app list -l argocd.argoproj.io/sync-wave=1 -o name | xargs -I {} argocd app sync {}

# Wait and verify before next wave
sleep 300  # 5 minutes

# Sync wave 2
argocd app list -l argocd.argoproj.io/sync-wave=2 -o name | xargs -I {} argocd app sync {}
```

## Validation Checks

Run these checks on each wave before proceeding.

### 1. Nextcloud Status Check

```bash
TENANT=canary  # Change per tenant
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ status
```

Expected output:
```
- installed: true
- version: 29.0.0.0
- versionstring: 29.0.0
- edition: 
- maintenance: false
```

### 2. Database Integrity

```bash
# Check for missing indices
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ db:add-missing-indices --dry-run

# Check for missing columns
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ db:add-missing-columns --dry-run

# Run maintenance repair (dry-run first)
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ maintenance:repair --dry-run
```

### 3. S3 Storage Check

```bash
# Check S3 connectivity
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ files:scan --dry-run admin
```

### 4. WebDAV Upload/Download Test

```bash
# Set variables
TENANT=canary
HOST=canary.nextcloud.example.com
PASSWORD=$(kubectl get secret -n nc-$TENANT nextcloud-secrets -o jsonpath='{.data.nextcloud-password}' | base64 -d)

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
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ background:job:list

# Check cron job status
kubectl get cronjob -n nc-$TENANT
```

### 6. Log Analysis

```bash
# Check for errors in last 10 minutes
kubectl logs -n nc-$TENANT deploy/nextcloud --since=10m | grep -i error
```

## Rollback Procedures

### Quick Rollback (Argo CD)

Rollback to previous revision:

```bash
TENANT=canary

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
git push origin main

# Or manually edit and push
git checkout HEAD~1 -- values/common.yaml
git commit -m "revert: rollback Nextcloud to previous version"
git push origin main
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

1. Put Nextcloud in maintenance mode:
   ```bash
   kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ maintenance:mode --on
   ```

2. Restore database from backup:
   ```bash
   # Example with pg_restore
   pg_restore -h $DB_HOST -U $DB_USER -d nextcloud_$TENANT backup.dump
   ```

3. Disable maintenance mode:
   ```bash
   kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ maintenance:mode --off
   ```

## Troubleshooting

### Common Issues

#### Issue: Pods stuck in ContainerCreating

Check for PVC issues:
```bash
kubectl describe pod -n nc-$TENANT
kubectl describe pvc -n nc-$TENANT
```

For S3-based architecture, this is usually limited to config PVC only.

#### Issue: S3 Connection Errors

```bash
# Check S3 credentials
kubectl get secret -n nc-$TENANT nextcloud-secrets -o yaml

# Test S3 connectivity from pod
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- curl -I https://s3.example.com
```

#### Issue: Redis Connection Errors

```bash
# Check Redis service
kubectl get svc -n nextcloud-platform redis

# Test Redis connectivity
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- \
  redis-cli -h redis.nextcloud-platform.svc.cluster.local ping
```

#### Issue: Database Connection Errors

```bash
# Check PgBouncer
kubectl get pods -n nextcloud-platform -l app.kubernetes.io/name=pgbouncer

# Check database credentials
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- env | grep DB
```

### Health Check Commands

```bash
# Full system check
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ check

# File integrity
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ integrity:check-core

# App status
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ app:list
```

### Getting Help

1. Check Nextcloud documentation: https://docs.nextcloud.com/
2. Check Helm chart issues: https://github.com/nextcloud/helm/issues
3. Review Argo CD logs: `kubectl logs -n argocd deploy/argocd-application-controller`


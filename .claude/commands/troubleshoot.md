Diagnose and resolve issues with a specific Nextcloud tenant. The argument is the tenant name: $ARGUMENTS

## Rules

This is a **read-only diagnostic** operation — allowed at any time, including office hours and weekends.

Do NOT apply fixes automatically. Diagnose first, present findings, and let the user decide on the remedy. If a fix involves platform changes, remind the user of the deployment window rules.

## Steps

### 1. Resolve tenant

If `$ARGUMENTS` is empty, ask the user which tenant to troubleshoot.

Verify the tenant exists:
```bash
ls nextcloud-platform/values/tenants/tenant-{name}.yaml
```

Read the tenant values file to understand its configuration (wave, env, dbType, hostname overrides, etc.).

### 2. Pod status

```bash
kubectl get pods -n {tenant-name} -o wide
```

Check for:
- Pods not in `Running` state
- Containers not ready (e.g., `2/3` instead of `3/3`)
- Restarts > 0 (and how many)
- Pods stuck in `Pending`, `CrashLoopBackOff`, `ImagePullBackOff`, or `Init:Error`

### 3. Recent events

```bash
kubectl get events -n {tenant-name} --sort-by='.lastTimestamp' | tail -20
```

Flag any `Warning` events. Common patterns:
- `FailedScheduling` → resource constraints or node issues
- `Unhealthy` → probe failures (check startup/liveness/readiness)
- `FailedMount` → PVC or secret issues
- `BackOff` → container crash loop

### 4. Pod details (if issues found)

For any unhealthy pod:
```bash
kubectl describe pod -n {tenant-name} -l app.kubernetes.io/name=nextcloud | tail -40
```

Focus on:
- Container state and reason
- Last termination reason and exit code
- Conditions (Ready, ContainersReady, PodScheduled)
- Events at the bottom

### 5. Logs

Get recent logs from the main Nextcloud container:
```bash
kubectl logs -n {tenant-name} -l app.kubernetes.io/name=nextcloud --tail=50 -c nextcloud
```

If there's an nginx sidecar:
```bash
kubectl logs -n {tenant-name} -l app.kubernetes.io/name=nextcloud --tail=30 -c nginx
```

Look for:
- PHP fatal errors or exceptions
- Database connection failures
- S3/object storage errors
- Permission denied errors
- OOM kills (check `kubectl describe` for `OOMKilled`)

### 6. Probe check

```bash
kubectl get pods -n {tenant-name} -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
```

If pods are not ready, check the probe endpoint:
```bash
kubectl exec -n {tenant-name} deploy/nextcloud -c nextcloud -- curl -sI http://localhost/status.php 2>/dev/null || echo "exec failed"
```

Common probe issues:
- HTTP 400 → trusted_domains mismatch (needs `/cutover-tenant`)
- HTTP 503 → maintenance mode or installation in progress
- Connection refused → PHP-FPM not started

### 7. Database connectivity

Based on `tenant.dbType`:

**MariaDB** (subchart):
```bash
kubectl get pods -n {tenant-name} -l app.kubernetes.io/name=mariadb
```

**External** (shared PgBouncer):
```bash
kubectl get pods -n nextcloud-platform -l app.kubernetes.io/name=pgbouncer
```

### 8. Storage check

```bash
kubectl get pvc -n {tenant-name}
```

Check for:
- PVCs in `Pending` state → storage provisioner issue
- PVCs at capacity → check if persistence size needs increase

### 9. Argo CD sync status

```bash
argocd app get nc-{tenant-name} --output json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = d.get('status', {})
print(f\"Sync: {s.get('sync', {}).get('status', 'unknown')}\")
print(f\"Health: {s.get('health', {}).get('status', 'unknown')}\")
for r in s.get('resources', [])[:10]:
    h = r.get('health', {}).get('status', '')
    if h and h != 'Healthy':
        print(f\"  {r.get('kind')}/{r.get('name')}: {h}\")
" 2>/dev/null || echo "argocd CLI not available — skip this check"
```

### 10. Diagnosis

Based on findings, present:

1. **Status**: one-line summary (healthy / degraded / down)
2. **Root cause** (or most likely cause if not definitive)
3. **Evidence**: the specific log lines, events, or states that point to this cause
4. **Recommended fix**: what to do, and whether it's a tenant-only or platform change (affects timing)

Common resolution paths — suggest the appropriate one:
- Probe failure from domain mismatch → `/cutover-tenant {name}`
- Out of sync → `/sync-tenant {name}`
- CrashLoopBackOff from config error → check tenant values file, fix, commit, sync
- Database down → check mariadb/pgbouncer pods, escalate if needed
- PVC issues → check storage class and provisioner
- Resource limits → check if tenant needs resource overrides in its values file

Do NOT apply fixes automatically. Present the diagnosis and let the user choose the action.

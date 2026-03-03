Trigger an immediate Argo CD sync for a tenant or set of tenants. The argument is the tenant name or pattern: $ARGUMENTS

## Rules

Syncing a tenant applies whatever is currently in Git to the cluster. Before syncing, verify that the current state of the repository is safe to apply given the time constraints.

- **Tenant config only changes**: May be synced at any time, including office hours and weekends.
- **Platform changes** (anything outside `nextcloud-platform/values/tenants/`): Only allowed Monday–Thursday 17:00–07:00 Amsterdam time. Never on Friday evenings, Saturdays, or Sundays — unless mwest2020 has explicitly given permission.

## Steps

### 1. Check timing and change scope
Run `TZ=Europe/Amsterdam date` to check the current Amsterdam time and day.

Then check what changed in the last commit:
```bash
git diff --name-only HEAD~1 HEAD
```

Classify the changes:
- If all changed files are in `nextcloud-platform/values/tenants/` → safe to sync at any time
- If any platform files changed, evaluate the deployment window:
  - Monday–Thursday 17:00–07:00 Amsterdam time → allowed
  - Office hours (Mon–Fri 07:00–17:00) → **STOP**: tell the user to wait
  - Friday 17:00+ / Saturday / Sunday → **STOP**: next window is Monday 17:00 Amsterdam time, unless mwest2020 approved

### 2. Resolve the sync target

If `$ARGUMENTS` is empty, ask the user which tenant to sync.

Determine whether to sync a single tenant or multiple:
- Single name (e.g., `zuiddrecht-accept`) → sync `nc-zuiddrecht-accept`
- Pattern (e.g., `*-accept`) → sync all matching apps using `--pattern "nc-*-accept"`
- New tenant (just added, not yet in Argo CD) → use `--refresh-appset` to trigger ApplicationSet regeneration first

### 3. Execute the sync

For a single existing tenant:
```bash
./nextcloud-platform/scripts/argocd-sync.sh {tenant-name} --wait
```

For a new tenant not yet in Argo CD:
```bash
./nextcloud-platform/scripts/argocd-sync.sh {tenant-name} --refresh-appset --wait-for-app 180 --wait
```

For a pattern:
```bash
./nextcloud-platform/scripts/argocd-sync.sh --pattern "nc-{pattern}" --wait
```

Run the command and report the output. If the script fails because `kubectl` is not configured or the application is not found, explain the error clearly.

### 4. Verify health

After sync completes (or if `--wait` times out), check pod status:
```bash
kubectl get pods -n {tenant-namespace}
```

Report whether all pods are running and ready. If any pod is not ready, show the recent events:
```bash
kubectl describe pod -n {tenant-namespace} -l app.kubernetes.io/name=nextcloud | tail -20
```

### 5. Summary
Report the sync result: success or failure, and what to do next if something went wrong.

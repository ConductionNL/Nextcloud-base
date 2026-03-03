Guide the user through a Nextcloud Helm chart upgrade using the wave-based rollout strategy. The argument is the target chart version: $ARGUMENTS

## Rules

A chart version upgrade modifies `nextcloud-platform/values/common.yaml` — this is a **platform change**.

**Platform changes are only allowed Monday–Thursday between 17:00 and 07:00 Amsterdam time. They are never allowed on Friday evenings, Saturdays, or Sundays — unless mwest2020 has explicitly given permission.**

First, check the current Amsterdam time with `TZ=Europe/Amsterdam date`. Evaluate:
- Monday–Thursday, 17:00–07:00 Amsterdam time → allowed, proceed
- Monday–Friday, 07:00–17:00 Amsterdam time → **STOP**: office hours, tell the user to wait until 17:00 Amsterdam time
- Friday 17:00+ / Saturday / Sunday → **STOP**: tell the user the next allowed window is Monday 17:00 Amsterdam time, unless mwest2020 has approved

## Steps

### 1. Check current version
Read `nextcloud-platform/values/common.yaml` and show the current `chart.version` value. If a target version was not provided in `$ARGUMENTS`, ask the user which version to upgrade to.

### 2. Pre-upgrade checklist
Ask the user to confirm the following before making any changes:
- [ ] The target chart version has been reviewed in the nextcloud/helm upstream changelog
- [ ] Canary tenant is healthy (check with: `kubectl get pods -n {canary-namespace}`)
- [ ] No active incidents on the platform

### 3. Identify the canary tenant
The canary is the tenant with `wave: "0"` in its values file. Run:
```bash
grep -r 'wave: "0"' nextcloud-platform/values/tenants/
```
Show the user which tenant(s) are wave 0.

### 4. Update the chart version
Edit `nextcloud-platform/values/common.yaml`: change `chart.version` to the target version.

Show the diff before saving.

### 5. Validate
Run:
```bash
./nextcloud-platform/scripts/validate-values.sh
./nextcloud-platform/scripts/smoke-checks.sh
```
Fix any issues before proceeding.

### 6. Commit the change
Suggest commit message: `chore: upgrade Nextcloud Helm chart to {version}`

Remind the user:
- After push, Argo CD will sync wave 0 (canary) first
- All other waves require the canary to be healthy before proceeding
- Remaining waves deploy automatically only within allowed deployment windows (Mon–Thu evenings)

### 7. Wave rollout sequence
After pushing, walk the user through this verification sequence:

**Wave 0 — Canary validation** (wait for rollout):
```bash
kubectl rollout status deployment -n {canary-namespace}
kubectl exec -n {canary-namespace} deploy/nextcloud -- php occ status
```
Expected: `installed: true`. If it fails, roll back immediately (see below).

**Wave 1+ — Progressive rollout**:
Once canary is healthy, remaining waves deploy automatically during allowed windows.
Monitor with:
```bash
kubectl get pods -n {namespace} -w
```

### 8. Rollback procedure (if needed)
If the canary fails:
1. Revert `common.yaml` to the previous version and push
2. Or use Argo CD: `argocd app rollback nc-{canary-tenant} {previous-revision}`
3. Investigate logs before retrying: `kubectl logs -n {canary-namespace} -l app.kubernetes.io/name=nextcloud`

### 9. Summary
After completing all waves, confirm:
- All tenant pods are running
- No error spikes in logs
- Report the upgrade as complete

Give a concise platform status overview for the Nextcloud multi-tenant GitOps platform.

## Steps

### 1. Tenant inventory

Scan all tenant files:
```bash
ls nextcloud-platform/values/tenants/tenant-*.yaml
```

For each tenant file, extract `tenant.name`, `tenant.environment`, `tenant.wave`, and `tenant.dbType` using `yq`. Present as a sorted table grouped by wave:

| Wave | Tenant | Env | DB | Notes |
|------|--------|-----|----|-------|

Add a "Notes" column for anything non-standard:
- `hostname:` override present → note "migrate domain"
- `tenant.namespace` override → note "custom ns"
- Missing `tenant.apps.enabled` → note "no apps" (known exception for vng tenants)

Show a summary line: total tenant count, count per environment, count per wave.

### 2. Recent changes

Show the last 10 commits with affected areas:
```bash
git log --oneline -10
```

Classify each commit as TENANT, PLATFORM, or MIXED based on the files changed:
```bash
git diff --name-only HEAD~1 HEAD
```
(Check the most recent 3-5 commits for classification.)

### 3. Current branch and remote status

```bash
git branch --show-current
git status -sb
```

Report: current branch, whether ahead/behind remote, any uncommitted changes.

### 4. Deployment window check

```bash
TZ=Europe/Amsterdam date
```

State whether the current time falls in an allowed platform deployment window (Mon–Thu 17:00–07:00 Amsterdam time) or not. If not, state when the next window opens.

### 5. Cluster health (optional)

If `kubectl` is available and configured, run:
```bash
kubectl get pods -n nextcloud-platform --no-headers 2>/dev/null
```

If it works, report platform service health (Redis, PgBouncer). If it fails (no cluster access), skip this section silently — do not show errors.

### 6. Validation status

Run a quick check:
```bash
./scripts/validate-values.sh 2>&1 | tail -5
```

Report pass/fail. Do not run the full smoke-checks (that's what `/validate` is for).

## Output

Keep the output concise — this is a dashboard, not a deep dive. Use tables and short lines. If something needs attention, flag it clearly at the top.

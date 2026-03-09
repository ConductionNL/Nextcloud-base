# Adding a New Tenant

This guide describes the steps required to add a new Nextcloud tenant to the platform.

## Prerequisites

- Access to the Git repository
- kubectl access to the cluster
- Knowledge of the tenant's hostname and environment (prod/accept)

## Choose Your Database

| Template | Database | Redis | Use Case |
|----------|----------|-------|----------|
| `tenant-template.yaml` | MariaDB | Platform (shared) | Simple deployments |
| `tenant-template-postgres.yaml` | PostgreSQL | Per-tenant | Custom PostgreSQL image with extensions |

## Steps

### 1. Create Tenant Values File

**Option A: MariaDB (default, simplest)**

```bash
cp nextcloud-platform/values/templates/tenant-template.yaml \
   nextcloud-platform/values/tenants/tenant-<name>.yaml
```

**Option B: PostgreSQL (with custom image + per-tenant Redis)**

```bash
cp nextcloud-platform/values/templates/tenant-template-postgres.yaml \
   nextcloud-platform/values/tenants/tenant-<name>.yaml
```

Edit the file and replace:
- `{{TENANT_NAME}}` → tenant name (e.g., `myorg`)
- `{{HOSTNAME}}` → full hostname (e.g., `nextcloud-myorg.commonground.nu`)
- `{{DATABASE_NAME}}` → database name (PostgreSQL only, e.g., `nextcloud_myorg`)
- `{{ENVIRONMENT}}` → `prod` or `accept`

### 2. Update NetworkPolicies ⚠️ IMPORTANT

> **Note:** Only required for tenants using **platform (shared) Redis/PgBouncer**.
> PostgreSQL tenants with per-tenant Redis do NOT need this step.

The platform uses NetworkPolicies to restrict access to shared services (Redis, PgBouncer).
**New tenant namespaces must be explicitly allowed.**

Edit these files and add the new namespace:

#### `platform/redis/networkpolicy.yaml`
```yaml
matchExpressions:
  - key: kubernetes.io/metadata.name
    operator: In
    values:
      - nc-canary
      - nc-example
      - nc-<your-new-tenant>  # ← Add this line
```

#### `platform/pgbouncer/networkpolicy.yaml`
```yaml
matchExpressions:
  - key: kubernetes.io/metadata.name
    operator: In
    values:
      - nc-canary
      - nc-example
      - nc-<your-new-tenant>  # ← Add this line
```

### 3. Create Secrets

Before Argo CD can deploy the tenant, secrets must exist in the namespace.

**Recommended: Use the secret creation script**

```bash
cd nextcloud-platform/scripts

# Copy and edit the env template
cp env.example .env
nano .env  # Fill in your credentials

# For MariaDB tenant:
./create-tenant-secret.sh <tenant-name> --mariadb

# For PostgreSQL tenant:
./create-tenant-secret.sh <tenant-name> --postgres

# Or auto-generate all passwords:
./create-tenant-secret.sh <tenant-name> --postgres --generate-passwords
```

**Alternative: Manual secret creation**

```bash
# Create namespace first (Argo CD will also create it, but secrets need to exist)
kubectl create namespace nc-<tenant-name>

# MariaDB secrets
kubectl create secret generic nextcloud-secrets \
  --namespace=nc-<tenant-name> \
  --from-literal=nextcloud-username='admin@example.com' \
  --from-literal=nextcloud-password='<secure-password>' \
  --from-literal=s3-access-key='<s3-access-key>' \
  --from-literal=s3-secret-key='<s3-secret-key>' \
  --from-literal=mariadb-password='<db-password>' \
  --from-literal=mariadb-root-password='<root-password>' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"

# PostgreSQL secrets (includes redis-password)
kubectl create secret generic nextcloud-secrets \
  --namespace=nc-<tenant-name> \
  --from-literal=nextcloud-username='admin@example.com' \
  --from-literal=nextcloud-password='<secure-password>' \
  --from-literal=s3-access-key='<s3-access-key>' \
  --from-literal=s3-secret-key='<s3-secret-key>' \
  --from-literal=postgres-password='<postgres-admin-password>' \
  --from-literal=db-username='nextcloud' \
  --from-literal=db-password='<db-password>' \
  --from-literal=redis-password='<redis-password>' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"
```

### 4. Commit and Push

```bash
git add nextcloud-platform/values/tenants/tenant-<name>.yaml
git add nextcloud-platform/platform/redis/networkpolicy.yaml
git add nextcloud-platform/platform/pgbouncer/networkpolicy.yaml
git commit -m "feat: add tenant <name>"
git push origin main
```

### 5. Sync Argo CD

After push, Argo CD should detect the new tenant file and create a new `Application`.

In practice, if you want immediate reconcile (recommended), run:

```bash
# 1) Re-apply ApplicationSet definition from Git
kubectl -n argocd apply -f nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml

# 2) Force ApplicationSet refresh
kubectl -n argocd annotate applicationset nextcloud-tenants \
  argocd.argoproj.io/application-set-refresh="true" --overwrite

# 3) Check if the tenant Application appears
kubectl -n argocd get applications | grep nc-<tenant-name>
```

Expected timing:

- Usually visible within **seconds to 1 minute**
- If not visible after **2-3 minutes**, go to Troubleshooting below

### 6. Verify Deployment

```bash
# Check application status
kubectl -n argocd get applications | grep nc-<tenant-name>

# Check pods
kubectl get pods -n <tenant-namespace>

# Verify Nextcloud is running
kubectl exec -n <tenant-namespace> deploy/nextcloud -c nextcloud -- php occ status
```

## Cutting Over from a Migration Hostname

When a tenant was onboarded with a temporary `{org}.migrate.commonground.nu` hostname, the final
step is cutting over to the canonical domain.

### Why this is needed

Nextcloud writes `trusted_domains` and `overwrite.cli.url` to `config/config.php` in the persistent
volume during initial installation. The Helm chart does not patch this file post-install. When you
remove the `tenant.hostname` migrate override, the startup probe starts sending
`Host: {org}.commonground.nu` — but `config.php` only trusts the old migrate domain, causing HTTP 400.

### Cutover procedure

1. **Remove the migrate hostname** from the tenant values file:
   ```yaml
   # Remove this line:
   hostname: {org}.migrate.commonground.nu
   ```
   Commit and push. Argo CD will sync and roll the pod with the new probe hostname.

2. **Run the cutover script** to patch the live pod:
   ```bash
   ./scripts/cutover-tenant.sh {tenant-name}
   ```
   This adds the canonical hostname to `trusted_domains` and updates `overwrite.cli.url`.

3. **Verify** the pod becomes healthy:
   ```bash
   kubectl get pods -n {tenant-name} -w
   curl -sI https://{org}.commonground.nu/status.php
   ```

Or use the skill: `/cutover-tenant {tenant-name}`

### What the script does

- Derives the canonical hostname from the tenant name (mirrors ApplicationSet logic)
- Adds `{org}.commonground.nu` to `trusted_domains` at index 1 (preserves `localhost` at index 0)
- Sets `overwrite.cli.url` to `https://{org}.commonground.nu`
- Prints the verified final config

## Troubleshooting

### "Redis server went away" or connection errors

The tenant namespace is not in the NetworkPolicy allowlist. 
See Step 2 above.

### Pods stuck in "CreateContainerConfigError"

Secrets are missing. See Step 3 above.

### Application not appearing in Argo CD

Use this order (most common causes first):

1. **Confirm file was pushed to `main`**
   - Argo only watches Git (not your local files).

2. **Confirm tenant file is valid**
   - Filename must match `tenant-*.yaml`
   - Location must be `nextcloud-platform/values/tenants/`
   - Validate:
     ```bash
     ./nextcloud-platform/scripts/validate-values.sh \
       nextcloud-platform/values/tenants/tenant-<name>.yaml
     ```

3. **Force ApplicationSet reconcile**
   ```bash
   kubectl -n argocd apply -f nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml
   kubectl -n argocd annotate applicationset nextcloud-tenants \
     argocd.argoproj.io/application-set-refresh="true" --overwrite
   ```

4. **Check ApplicationSet status message**
   ```bash
   kubectl -n argocd get applicationset nextcloud-tenants \
     -o jsonpath='{.status.conditions[*].message}{"\n"}'
   ```

5. **Check controller logs (if still missing)**
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller
   ```

6. **Check sync window**
   - Outside allowed sync window, app may exist but not progress/sync yet.

## Checklist

### All Tenants
- [ ] Tenant values file created (`tenant-<name>.yaml`)
- [ ] Template placeholders replaced (`{{TENANT_NAME}}`, `{{HOSTNAME}}`, etc.)
- [ ] Namespace created
- [ ] Secrets created in namespace (use `create-tenant-secret.sh`)
- [ ] Changes committed and pushed
- [ ] Argo CD Application synced
- [ ] Pods running (3/3 for MariaDB, 4/4+ for PostgreSQL with Redis)
- [ ] Nextcloud accessible via browser

### MariaDB Tenants Only (using platform Redis)
- [ ] NetworkPolicy updated for Redis (`platform/redis/networkpolicy.yaml`)
- [ ] NetworkPolicy updated for PgBouncer (`platform/pgbouncer/networkpolicy.yaml`)

### PostgreSQL Tenants Only
- [ ] `{{DATABASE_NAME}}` placeholder replaced
- [ ] Per-tenant Redis pod running

# Adding a New Tenant

This guide describes the steps required to add a new Nextcloud tenant to the platform.

## Prerequisites

- Access to the Git repository
- kubectl access to the cluster
- Knowledge of the tenant's hostname and environment (prod/accept)

## Steps

### 1. Create Tenant Values File

Copy the template and customize it:

```bash
cp nextcloud-platform/values/templates/tenant-template.yaml \
   nextcloud-platform/values/tenants/tenant-<name>.yaml
```

Edit the file and replace:
- `{{TENANT_NAME}}` → tenant name (e.g., `myorg`)
- `{{HOSTNAME}}` → full hostname (e.g., `nextcloud-myorg.commonground.nu`)
- `{{ENVIRONMENT}}` → `prod` or `accept`

### 2. Update NetworkPolicies ⚠️ IMPORTANT

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
      - nc-canary-accept
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
      - nc-canary-accept
      - nc-example
      - nc-<your-new-tenant>  # ← Add this line
```

### 3. Create Secrets

Before Argo CD can deploy the tenant, secrets must exist in the namespace.

```bash
# Create namespace first (Argo CD will also create it, but secrets need to exist)
kubectl create namespace nc-<tenant-name>

# Create the secrets
kubectl create secret generic nextcloud-secrets \
  --namespace=nc-<tenant-name> \
  --from-literal=nextcloud-username='admin@example.com' \
  --from-literal=nextcloud-password='<secure-password>' \
  --from-literal=s3-access-key='<s3-access-key>' \
  --from-literal=s3-secret-key='<s3-secret-key>' \
  --from-literal=db-username='nextcloud' \
  --from-literal=db-password='<db-password>' \
  --from-literal=mariadb-password='<db-password>' \
  --from-literal=mariadb-root-password='<root-password>' \
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

The ApplicationSet will automatically detect the new tenant file and create the Application.
You can trigger a manual sync:

```bash
# Refresh ApplicationSet
argocd appset get nextcloud-tenants --refresh

# Or wait for automatic sync (default: 3 minutes)
```

### 6. Verify Deployment

```bash
# Check application status
kubectl get applications -n argocd | grep nc-<tenant-name>

# Check pods
kubectl get pods -n nc-<tenant-name>

# Verify Nextcloud is running
kubectl exec -n nc-<tenant-name> deploy/nextcloud -c nextcloud -- php occ status
```

## Troubleshooting

### "Redis server went away" or connection errors

The tenant namespace is not in the NetworkPolicy allowlist. 
See Step 2 above.

### Pods stuck in "CreateContainerConfigError"

Secrets are missing. See Step 3 above.

### Application not appearing in Argo CD

- Check the tenant YAML filename matches pattern `tenant-*.yaml`
- Verify the file is in `nextcloud-platform/values/tenants/`
- Check ApplicationSet logs: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller`

## Checklist

- [ ] Tenant values file created (`tenant-<name>.yaml`)
- [ ] NetworkPolicy updated for Redis
- [ ] NetworkPolicy updated for PgBouncer  
- [ ] Namespace created
- [ ] Secrets created in namespace
- [ ] Changes committed and pushed
- [ ] Argo CD Application synced
- [ ] Pods running (3/3)
- [ ] Nextcloud accessible via browser

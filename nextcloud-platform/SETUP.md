# Nextcloud Platform - Initial Setup Guide

This guide walks through deploying the first tenant (canary) on nextcloud-canary.commonground.nu.

## Prerequisites

- Kubernetes 1.28+ cluster with kubectl access
- Argo CD installed
- cert-manager installed with `letsencrypt-prod` ClusterIssuer
- Fuga Cloud S3 credentials
- DNS configured for nextcloud-canary.commonground.nu

## Database Options

This platform supports 3 database options (see `docs/DATABASE.md`):

| Option | Description | Recommended For |
|--------|-------------|-----------------|
| **MariaDB** (default) | In-cluster, per-tenant | Getting started, dev |
| **PostgreSQL** | In-cluster, per-tenant | PostgreSQL features |
| **External PostgreSQL** | Shared + PgBouncer | Production |

**For now, we use MariaDB** - the simplest option.

---

## Step 1: Verify S3 Bucket

The S3 bucket `nextcloud` should already exist in Fuga Cloud:

```bash
# Verify bucket exists
aws --endpoint-url https://core.fuga.cloud:8080 s3 ls s3://nextcloud
```

## Step 2: Create Tenant Secret

```bash
# Create namespace
kubectl create namespace nc-canary

# Create secret
kubectl create secret generic nextcloud-secrets \
  --namespace=nc-canary \
  --from-literal=nextcloud-username=admin \
  --from-literal=nextcloud-password='YOUR_ADMIN_PASSWORD' \
  --from-literal=s3-access-key='YOUR_FUGA_ACCESS_KEY' \
  --from-literal=s3-secret-key='YOUR_FUGA_SECRET_KEY' \
  --from-literal=db-password='MARIADB_PASSWORD' \
  --from-literal=redis-password='' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"
```

**Save the admin password!** You'll need it to log in.

## Step 3: Commit and Push

```bash
git add .
git commit -m "feat: initial nextcloud platform setup"
git push origin main
```

## Step 4: Deploy with Argo CD

```bash
# Apply the Argo CD project
kubectl apply -f nextcloud-platform/argo/projects/nextcloud-platform.yaml

# Apply the ApplicationSets
kubectl apply -f nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml
```

## Step 5: Watch Deployment

```bash
# Watch applications
kubectl get applications -n argocd -w

# Watch canary pods
kubectl get pods -n nc-canary -w

# Check logs if issues
kubectl logs -n nc-canary -l app.kubernetes.io/name=nextcloud -f
```

## Step 6: Access Nextcloud

Once pods are running (takes 2-5 minutes):

1. Open https://nextcloud-canary.commonground.nu
2. Login with:
   - **Username:** `admin`
   - **Password:** (from step 2)

## Step 7: Verify

```bash
# Check Nextcloud status
kubectl exec -it -n nc-canary deploy/nextcloud-nextcloud -- php occ status

# Check S3 connectivity
kubectl exec -it -n nc-canary deploy/nextcloud-nextcloud -- php occ files:scan --dry-run admin
```

---

## What Gets Created

| Component | Where | Notes |
|-----------|-------|-------|
| Nextcloud | `nc-canary` namespace | Web app |
| MariaDB | `nc-canary` namespace | Database (per-tenant) |
| Redis | `nextcloud-platform` namespace | Shared cache/locking |
| Ingress | `nc-canary` namespace | TLS via cert-manager |

---

## Troubleshooting

### Pods Not Starting

```bash
kubectl describe pod -n nc-canary -l app.kubernetes.io/name=nextcloud
kubectl logs -n nc-canary -l app.kubernetes.io/name=nextcloud
```

### Secret Not Found

```bash
kubectl get secret nextcloud-secrets -n nc-canary
```

### S3 Errors

```bash
kubectl exec -it -n nc-canary deploy/nextcloud-nextcloud -- env | grep S3
```

### Certificate Issues

```bash
kubectl get certificate -n nc-canary
kubectl describe certificate -n nc-canary
```

---

## Adding More Tenants

1. Copy `values/tenants/tenant-canary.yaml` to `tenant-<name>.yaml`
2. Update hostname, bucket, etc.
3. Create namespace and secret:
   ```bash
   kubectl create namespace nc-<name>
   kubectl create secret generic nextcloud-secrets --namespace=nc-<name> ...
   ```
4. Commit and push

---

## Upgrading to External PostgreSQL (Later)

When ready for production, see `docs/DATABASE.md` for:
- Option B: External PostgreSQL with auto-provisioning
- Migration steps from MariaDB

---

## Configuration Reference

### Fuga Cloud S3
- **Endpoint:** `https://core.fuga.cloud:8080`
- **Path style:** `true`
- **SSL:** `true`

### Canary Tenant
- **Hostname:** `nextcloud-canary.commonground.nu`
- **Namespace:** `nc-canary`
- **S3 Bucket:** `nextcloud`
- **Database:** MariaDB (in-cluster)

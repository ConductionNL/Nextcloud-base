# Secrets Management Guide

This document describes how secrets are managed in the Nextcloud platform.

## Overview

The platform uses a **no secrets in Git** approach:

- Secrets are never committed to the repository
- Secrets are generated or fetched in-cluster
- Two methods are supported:
  1. External Secrets Operator (recommended)
  2. Fallback Job (generates secrets if ESO unavailable)

## Required Secrets

Each tenant requires the following secrets:

| Secret Key | Description | Example |
|------------|-------------|---------|
| `nextcloud-username` | Admin username | `admin` |
| `nextcloud-password` | Admin password | `(generated)` |
| `s3-access-key` | Ceph RGW access key | `AKIAIOSFODNN7EXAMPLE` |
| `s3-secret-key` | Ceph RGW secret key | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` |
| `db-password` | PostgreSQL password | `(from provider)` |
| `redis-password` | Redis password (optional) | `(if auth enabled)` |
| `nextcloud-secret` | Encryption secret | `(generated 64-char)` |

## Option A: External Secrets Operator (Recommended)

### Setup

1. Install External Secrets Operator in your cluster
2. Configure a ClusterSecretStore (e.g., Vault, AWS Secrets Manager)
3. Store secrets in your backend

### HashiCorp Vault Example

Store secrets in Vault:

```bash
# For each tenant
vault kv put secret/nextcloud/prod/canary \
  admin-password="$(openssl rand -base64 24)" \
  s3-access-key="AKIAIOSFODNN7EXAMPLE" \
  s3-secret-key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" \
  db-password="your-db-password" \
  redis-password="" \
  nextcloud-secret="$(openssl rand -base64 48)"
```

### AWS Secrets Manager Example

```bash
# Create secret
aws secretsmanager create-secret \
  --name nextcloud/prod/canary \
  --secret-string '{
    "admin-password": "generated-password",
    "s3-access-key": "AKIAIOSFODNN7EXAMPLE",
    "s3-secret-key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "db-password": "your-db-password",
    "redis-password": "",
    "nextcloud-secret": "64-char-random-string"
  }'
```

### Verify ExternalSecret Status

```bash
# Check if secret is synced
kubectl get externalsecret -n nc-canary nextcloud-secrets

# Check secret content (base64 encoded)
kubectl get secret -n nc-canary nextcloud-secrets -o yaml
```

## Option B: Fallback Secret Generator

If ESO is not available or not ready, a Kubernetes Job generates secrets.

### How It Works

1. Job runs as Argo CD PreSync hook
2. Checks if secret already exists
3. If not, generates secure random values
4. Creates Kubernetes Secret

### Important Notes

- **S3 and DB credentials are placeholders** - you MUST update them manually
- Generated admin password is printed in Job logs (save it!)
- Secrets labeled with `nextcloud.platform/generated=true`

### Update Placeholder Secrets

After Job runs, update the placeholders:

```bash
TENANT=canary

# Edit secret
kubectl edit secret nextcloud-secrets -n nc-$TENANT

# Or patch specific values
kubectl patch secret nextcloud-secrets -n nc-$TENANT \
  --type='json' \
  -p='[
    {"op": "replace", "path": "/data/s3-access-key", "value": "'$(echo -n "REAL_KEY" | base64)'"},
    {"op": "replace", "path": "/data/s3-secret-key", "value": "'$(echo -n "REAL_SECRET" | base64)'"},
    {"op": "replace", "path": "/data/db-password", "value": "'$(echo -n "REAL_PASSWORD" | base64)'"}
  ]'
```

### Retrieve Generated Admin Password

```bash
# From Job logs
kubectl logs -n nc-$TENANT job/nextcloud-secret-generator

# Or from secret
kubectl get secret nextcloud-secrets -n nc-$TENANT \
  -o jsonpath='{.data.nextcloud-password}' | base64 -d
```

## Disaster Recovery

### Backup Secrets

Regularly backup secrets (not to Git!):

```bash
# Export all tenant secrets
for ns in $(kubectl get ns -l app.kubernetes.io/part-of=nextcloud-platform -o name | cut -d/ -f2); do
  kubectl get secret -n $ns nextcloud-secrets -o yaml > "backup/secrets-${ns}.yaml"
done

# Encrypt backups
tar czf secrets-backup.tar.gz backup/
gpg --symmetric --cipher-algo AES256 secrets-backup.tar.gz
rm -rf backup/ secrets-backup.tar.gz

# Store encrypted backup securely (NOT in Git!)
```

### Restore Secrets

```bash
# Decrypt
gpg --decrypt secrets-backup.tar.gz.gpg > secrets-backup.tar.gz
tar xzf secrets-backup.tar.gz

# Restore
kubectl apply -f backup/secrets-nc-canary.yaml
```

### Rotate Secrets

#### Rotate Admin Password

```bash
TENANT=canary
NEW_PASSWORD=$(openssl rand -base64 24)

# Update in Vault (if using ESO)
vault kv patch secret/nextcloud/prod/$TENANT admin-password="$NEW_PASSWORD"

# Or update Kubernetes secret directly
kubectl patch secret nextcloud-secrets -n nc-$TENANT \
  --type='json' \
  -p='[{"op": "replace", "path": "/data/nextcloud-password", "value": "'$(echo -n "$NEW_PASSWORD" | base64)'"}]'

# Restart Nextcloud to pick up new password
kubectl rollout restart deployment -n nc-$TENANT nextcloud
```

#### Rotate S3 Keys

1. Create new S3 credentials in Ceph RGW
2. Update secret in Vault/K8s
3. Restart Nextcloud
4. Verify S3 access works
5. Revoke old credentials

```bash
# Update and restart
kubectl patch secret nextcloud-secrets -n nc-$TENANT ...
kubectl rollout restart deployment -n nc-$TENANT nextcloud

# Verify
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- php occ files:scan --dry-run admin
```

## Security Best Practices

1. **Never commit secrets to Git**
   - Use `.gitignore` to exclude secret files
   - Run `gitleaks` in CI

2. **Use short-lived credentials when possible**
   - Enable automatic rotation in Vault
   - Use IAM roles for S3 if on AWS

3. **Principle of least privilege**
   - S3 keys should only access their bucket
   - DB users should only access their database

4. **Audit secret access**
   - Enable audit logging in Vault
   - Monitor secret access patterns

5. **Encrypt backups**
   - Always encrypt secret backups
   - Use strong encryption (AES-256)
   - Store encryption keys separately

## Troubleshooting

### ExternalSecret Not Syncing

```bash
# Check ESO status
kubectl get externalsecret -n nc-$TENANT nextcloud-secrets -o yaml

# Check ESO logs
kubectl logs -n external-secrets deploy/external-secrets

# Check ClusterSecretStore
kubectl get clustersecretstore -o yaml
```

### Secret Generator Job Failed

```bash
# Check job status
kubectl get job -n nc-$TENANT nextcloud-secret-generator

# Check logs
kubectl logs -n nc-$TENANT job/nextcloud-secret-generator

# Common issues:
# - ServiceAccount missing permissions
# - Secret already exists with different owner
```

### Can't Access Nextcloud After Secret Rotation

```bash
# Check if pods picked up new secret
kubectl rollout status deployment -n nc-$TENANT nextcloud

# Force restart if needed
kubectl rollout restart deployment -n nc-$TENANT nextcloud

# Check environment variables in pod
kubectl exec -it -n nc-$TENANT deploy/nextcloud -- env | grep -i password
```

